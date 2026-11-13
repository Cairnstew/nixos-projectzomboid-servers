#!/usr/bin/env python3
# scripts/pz_pack_doctor.py
#
# Verify that a modpack's DECLARATION matches what is actually installed.
#
# `WorkshopItems=` downloads and `Mods=` loads, and neither is derivable from
# the other: a Workshop item can contain several mods, and a mod's internal id
# only exists inside its own `mod.info` after the download. The catalogue check
# in `checks/default.nix` can only see the declaration, so drift has to be
# caught after steamcmd has run. That is this script.
#
# It caught a real one: `vanilla-plus` listed six Workshop items and zero Mod
# IDs, so the servers downloaded six items and loaded none.
#
# Run it against an installed Workshop root:
#
#   nix run .#pz-pack-doctor -- --pack viewpoint --workshop-root <dir>
#
# Exit codes: 0 clean, 1 errors (or warnings under --strict), 2 usage/IO.
#
# `mod.info` is untrusted input, as in `pz_client_mods.py`: nothing here writes
# or executes anything from it. Only ids and dependency strings are read.
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Reuse the one implementation of "what is a mod root" and "what is the id".
# Importing is safe: pz_client_mods.py only defines functions/constants at top
# level and guards its CLI behind main().
import pz_client_mods as pcm  # noqa: E402

CATALOGUE_ENV = pcm.CATALOGUE_ENV
WORKSHOP_ENV = "PZ_WORKSHOP_DIR"

# `key=value`, `key = value`, or a `//`/`#` comment line. PZ trims both sides.
_INFO_LINE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")

LIST_KEYS = {
    "require": "require",
    "incompatible": "incompatible",
    "loadmodafter": "load_after",
    "loadmodbefore": "load_before",
}


class ModInfo:
    __slots__ = (
        "mod_id",
        "name",
        "item",
        "path",
        "require",
        "incompatible",
        "load_after",
        "load_before",
        "lua",
    )

    def __init__(self, mod_id, path, item):
        self.mod_id = mod_id
        self.name = mod_id
        self.item = item
        self.path = path
        self.require = []
        self.incompatible = []
        self.load_after = []
        self.load_before = []
        self.lua = set()

    def as_dict(self):
        return {
            "id": self.mod_id,
            "name": self.name,
            "item": self.item,
            "path": self.path,
            "require": self.require,
            "incompatible": self.incompatible,
            "loadModAfter": self.load_after,
            "loadModBefore": self.load_before,
            "lua": sorted(self.lua),
        }


def _split(value):
    """A comma-separated mod.info list, tolerant of whitespace and empties."""
    return [part.strip().strip('"') for part in value.split(",") if part.strip()]


def parse_mod_info(root, item):
    """Read one mod.info. Returns ModInfo, or None when it has no usable id."""
    path = os.path.join(root, "mod.info")
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None

    fields = {}
    for line in lines:
        if not line.strip() or line.lstrip().startswith(("#", "//")):
            continue
        match = _INFO_LINE.match(line)
        if not match:
            continue
        key = match.group(1).lower()
        fields.setdefault(key, []).append(match.group(2).strip().strip('"'))

    mod_id = (fields.get("id") or [""])[0].strip()
    if not mod_id:
        return None

    info = ModInfo(mod_id, root, item)
    name = (fields.get("name") or [""])[0].strip()
    if name:
        info.name = name
    for key, attr in LIST_KEYS.items():
        values = []
        for raw in fields.get(key, []):
            values.extend(_split(raw))
        # de-duplicate while preserving order
        seen = set()
        setattr(info, attr, [v for v in values if not (v in seen or seen.add(v))])
    return info


def lua_sides(root):
    """{'client','server','shared'} for the folders a mod actually ships.

    Build 42 mods keep these under `common/media/lua/...` or a version folder
    (`42/media/lua/...`, `42.20/media/lua/...`); walking the whole mod root
    covers both without guessing which version folder the server will pick.
    """
    sides = set()
    for current, dirs, _files in os.walk(root):
        # `media/lua/<side>` is the only shape PZ loads.
        if os.path.basename(current) == "lua":
            for side in ("client", "server", "shared"):
                if side in dirs:
                    sides.add(side)
    return sides


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, message):
        self.errors.append(message)

    def warn(self, message):
        self.warnings.append(message)


def mod_folder(root):
    """The folder a Build 42 mod actually is.

    A B42 mod keeps `mod.info` inside `common/` and/or a version folder
    (`42/`, `42.20/`), so two mod.info files with the same id are ONE mod. The
    parent of `common`/a version folder is the mod folder; for a Build 41 layout
    (`mod.info` at the mod root) the root is already it.
    """
    base = os.path.basename(root)
    if base == "common" or re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", base):
        return os.path.dirname(root)
    return root


def scan(workshop_root, declared_item_ids, report):
    """Return {mod_id: ModInfo} for the items this pack declares.

    Only declared items are scanned. A shared workshop root serves every pack on
    the host, so an undeclared directory is not an error — it may belong to
    another pack.
    """
    mods = {}
    item_mods = {}
    for item_id in declared_item_ids:
        item_dir = os.path.join(workshop_root, item_id)
        if not os.path.isdir(item_dir):
            report.error(f"Workshop item {item_id} is declared but is not installed under {workshop_root}")
            continue
        roots = pcm.mod_roots(item_dir)
        if not roots:
            report.error(f"Workshop item {item_id} is installed but contains no mod.info")
            continue
        found = []
        for root in roots:
            info = parse_mod_info(root, item_id)
            if info is None:
                report.error(f"{item_id}: {os.path.relpath(root, workshop_root)} has a mod.info without a usable id=")
                continue
            info.lua = lua_sides(root)
            existing = mods.get(info.mod_id)
            if existing is not None:
                # `common/mod.info` + `42/mod.info` in the same mod folder are
                # one mod, not a collision. Merge what each declares.
                if mod_folder(existing.path) == mod_folder(info.path):
                    existing.lua |= info.lua
                    for attr in ("require", "incompatible", "load_after", "load_before"):
                        values = getattr(existing, attr)
                        for value in getattr(info, attr):
                            if value not in values:
                                values.append(value)
                    continue
                report.error(
                    f"Mod ID {info.mod_id!r} is provided by two installed mods: "
                    f"{existing.path} and {info.path}. PZ cannot load both."
                )
                continue
            mods[info.mod_id] = info
            found.append(info.mod_id)
        item_mods[item_id] = found
    return mods, item_mods


def check(pack_name, pack, workshop_root, strict=False):
    report = Report()

    declared_items = []
    for entry in pack.get("workshopMods", []) or []:
        if not isinstance(entry, dict) or not str(entry.get("id", "")).isdigit():
            report.error(f"workshopMods entry is not {{ id = \"<digits>\"; title = ...; }}: {entry!r}")
            continue
        declared_items.append(str(entry["id"]))

    declared_mods = [str(m) for m in (pack.get("mods", []) or [])]

    duplicates = sorted({m for m in declared_mods if declared_mods.count(m) > 1})
    if duplicates:
        report.error(f"mods= lists the same Mod ID twice: {', '.join(duplicates)}")

    if declared_items and not declared_mods:
        report.error(
            f"pack declares {len(declared_items)} Workshop item(s) but no Mod IDs: "
            "WorkshopItems= only downloads, so nothing would load"
        )

    installed, item_mods = scan(workshop_root, declared_items, report)

    # Every declared Mod ID must have a provider. An item that ships several
    # mods is normal; a declared id that nothing provides is a boot-time miss.
    for mod_id in declared_mods:
        if mod_id not in installed:
            report.error(
                f"Mod ID {mod_id!r} is declared in mods= but no installed item provides it "
                "(a Workshop id and a Mod ID are different namespaces)"
            )

    # A declared item that provides NO loaded mod is worth reporting: it is
    # downloaded but inert. An item shipping several mods where only some are
    # enabled is normal (optional variants), so that stays quiet.
    for item_id, provided in item_mods.items():
        if provided and not any(mod_id in declared_mods for mod_id in provided):
            report.warn(
                f"item {item_id} provides {', '.join(provided)} but none is in mods= — "
                "the item is downloaded and nothing from it loads"
            )

    # Dependencies of the mods the pack actually loads.
    for mod_id in declared_mods:
        info = installed.get(mod_id)
        if info is None:
            continue
        for target in info.require:
            if target == mod_id:
                continue
            if target in declared_mods:
                continue
            if target in installed:
                report.warn(
                    f"{mod_id!r} requires {target!r}, which is installed but not in mods= — "
                    "PZ will skip it (and may skip the dependent mod)"
                )
            elif target.lower() in {"base", "vanilla"}:
                continue
            else:
                report.warn(
                    f"{mod_id!r} declares require={target!r}, which this pack does not provide "
                    "(it may be a base-game id or a mod outside the pack)"
                )
        for target in info.incompatible:
            if target in declared_mods:
                report.error(f"{mod_id!r} is incompatible with {target!r}, but both are in mods=")

    # Load order: `require`/`loadModAfter` enforce order at run time, but a
    # Mods= list that contradicts them is misleading and is usually a mistake
    # that only shows up as a patch applied in the wrong order.
    index = {mod_id: i for i, mod_id in enumerate(declared_mods)}
    for mod_id in declared_mods:
        info = installed.get(mod_id)
        if info is None:
            continue
        for target, relation in [(t, "loadModAfter") for t in info.load_after] + [
            (t, "require") for t in info.require
        ]:
            if target in index and index[target] > index[mod_id]:
                report.warn(
                    f"{mod_id!r} declares {relation}={target!r} but mods= lists {target!r} "
                    "after it; reorder mods= to match"
                )
        for target in info.load_before:
            if target in index and index[target] < index[mod_id]:
                report.warn(
                    f"{mod_id!r} declares loadModBefore={target!r} but mods= lists "
                    f"{target!r} before it; reorder mods= to match"
                )

    # Client/server classification. There is no client-only/server-only flag in
    # mod.info: the split IS the lua folder. Report it so an operator can see
    # what each side actually needs; it is never an error.
    counts = {"client-only": 0, "server-only": 0, "both": 0, "shared-only": 0, "no-lua": 0}
    for mod_id in declared_mods:
        info = installed.get(mod_id)
        if info is None:
            continue
        sides = info.lua
        if "client" in sides and "server" in sides:
            counts["both"] += 1
        elif "client" in sides:
            counts["client-only"] += 1
        elif "server" in sides:
            counts["server-only"] += 1
        elif "shared" in sides:
            counts["shared-only"] += 1
        else:
            counts["no-lua"] += 1

    ok = not report.errors and (not strict or not report.warnings)
    return {
        "pack": pack_name,
        "workshop_root": os.path.abspath(workshop_root),
        "declared_workshop_items": len(declared_items),
        "installed_workshop_items": sum(1 for i in declared_items if i in item_mods),
        "declared_mod_ids": len(declared_mods),
        "installed_mod_ids": sum(1 for m in declared_mods if m in installed),
        "errors": report.errors,
        "warnings": report.warnings,
        "lua_classes": counts,
        "ok": ok,
    }


def print_human(result):
    print(
        f"pz-pack-doctor: pack {result['pack']!r} — "
        f"{result['installed_workshop_items']}/{result['declared_workshop_items']} Workshop item(s), "
        f"{result['installed_mod_ids']}/{result['declared_mod_ids']} Mod ID(s)"
    )
    print(f"  workshop root: {result['workshop_root']}")
    classes = result["lua_classes"]
    print(
        "  lua: "
        f"{classes['both']} both sides, {classes['client-only']} client-only, "
        f"{classes['server-only']} server-only, {classes['shared-only']} shared-only, "
        f"{classes['no-lua']} no lua"
    )
    for message in result["warnings"]:
        print(f"  warning: {message}", file=sys.stderr)
    for message in result["errors"]:
        print(f"  error: {message}", file=sys.stderr)
    if result["ok"]:
        print(f"  ok: {len(result['warnings'])} warning(s), 0 errors")
    else:
        print(
            f"  FAILED: {len(result['errors'])} error(s), {len(result['warnings'])} warning(s)",
            file=sys.stderr,
        )


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="pz-pack-doctor",
        description=(
            "Check a modpack's WorkshopItems=/Mods= against what is actually installed. "
            "Run after steamcmd has downloaded the pack's items."
        ),
    )
    parser.add_argument("--pack", required=True, help="Modpack name from the catalogue")
    parser.add_argument(
        "--workshop-root",
        default=os.environ.get(WORKSHOP_ENV),
        help=f"steamapps/workshop/content/108600 root (default: ${WORKSHOP_ENV})",
    )
    parser.add_argument(
        "--catalogue",
        default=os.environ.get(CATALOGUE_ENV),
        help=f"JSON catalogue (default: ${CATALOGUE_ENV})",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as failures (use in CI once a pack is clean)",
    )
    parser.add_argument("--json", action="store_true", help="Machine-readable output")
    args = parser.parse_args(argv)

    if not args.workshop_root:
        parser.error(f"--workshop-root is required (or set ${WORKSHOP_ENV})")
    if not os.path.isdir(args.workshop_root):
        print(f"pz-pack-doctor: {args.workshop_root} is not a directory", file=sys.stderr)
        return 2
    if not args.catalogue or not os.path.isfile(args.catalogue):
        print(
            f"pz-pack-doctor: no readable catalogue at {args.catalogue!r}; "
            "run this through `nix run .#pz-pack-doctor`",
            file=sys.stderr,
        )
        return 2

    catalogue = pcm.load_catalogue(args.catalogue)
    if catalogue is None:
        return 2
    if args.pack not in catalogue:
        known = ", ".join(sorted(catalogue)) or "(none)"
        print(f"pz-pack-doctor: no such pack {args.pack!r}; known packs: {known}", file=sys.stderr)
        return 2

    result = check(args.pack, catalogue[args.pack], args.workshop_root, strict=args.strict)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print_human(result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
