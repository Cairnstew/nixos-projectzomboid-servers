#!/usr/bin/env python3
# scripts/pz_pack_web.py
#
# Generate a READY-TO-UPLOAD Steam Workshop item for a pack's "connector" mod.
#
# The connector is deliberately small and non-destructive:
#   * `loadModAfter=` every Mod ID in the pack, so it loads last and a future
#     pack-wide patch file can override the mods it targets;
#   * a generated manifest of the pack's Mod IDs;
#   * a server-start audit that logs which pack mods are missing / extra.
#
# It does NOT copy, modify or redistribute any other mod's files. That is what
# makes it publishable: the Workshop item is our own code and data only. A
# future patch that overwrites another mod's relative path is a licensing
# decision (see docs/plans/pack-web.md), not something this generator does.
#
# The output follows the in-game uploader's layout (verified against
# ~/Zomboid/Workshop/ModTemplate and an installed B42 item):
#
#   <out-dir>/
#     workshop.txt
#     preview.png
#     Contents/mods/<mod-id>/42/mod.info
#     Contents/mods/<mod-id>/42/media/lua/shared/PZPackWeb/manifest.lua
#     Contents/mods/<mod-id>/42/media/lua/server/PZPackWeb/audit.lua
#
# Then: Main Menu -> Workshop -> Create/Update, select the folder, set the
# visibility, Upload. `--workshop-id` updates an existing item.
import argparse
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pz_client_mods as pcm  # noqa: E402

CATALOGUE_ENV = pcm.CATALOGUE_ENV
DEFAULT_WORKSHOP_DIR = os.path.join(os.path.expanduser("~"), "Zomboid", "Workshop")

# The uploader validates the preview: 512x512 max, 8-bit.
PREVIEW_SIZE = 512
VALID_VISIBILITY = ("public", "friendsOnly", "private", "unlisted")

# Only the generated mod id is validated this strictly. Pack Mod IDs may contain
# spaces (real ones do), so they are only checked for characters that would
# break the Lua string literal or the .info line.
_SAFE_GENERATED_ID = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_UNSAFE_VALUE = re.compile(r"[\r\n\"\\]")


def generated_id(pack):
    """`viewpoint` -> `PZPackWebViewpoint`; stable and a Lua identifier."""
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", pack) if p]
    if not parts:
        raise SystemExit(f"pz-pack-web: cannot derive a mod id from pack name {pack!r}")
    return "PZPackWeb" + "".join(p[:1].upper() + p[1:] for p in parts)


def check_value(kind, value):
    """A value that goes into mod.info or a Lua string must be one line."""
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"pz-pack-web: empty {kind}")
    if _UNSAFE_VALUE.search(value):
        raise SystemExit(f"pz-pack-web: {kind} contains a quote, backslash or newline: {value!r}")
    return value


def png_chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def write_preview(path):
    """A valid 512x512 8-bit RGB PNG placeholder.

    The uploader refuses a missing preview and Steam shows this until it is
    replaced. A plain gradient is deliberate: it is obviously a placeholder, and
    it is generated with the stdlib so the app has no image dependency.
    """
    rows = []
    for y in range(PREVIEW_SIZE):
        row = bytearray()
        for x in range(PREVIEW_SIZE):
            # Dark slate with a lighter diagonal band.
            shade = 24 + ((x + y) % 128) // 4
            row += bytes((shade, shade + 8, shade + 16))
        rows.append(b"\x00" + bytes(row))
    raw = zlib.compress(b"".join(rows), 9)
    ihdr = struct.pack(">IIBBBBB", PREVIEW_SIZE, PREVIEW_SIZE, 8, 2, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) + png_chunk(b"IDAT", raw)
    data += png_chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(data)


def copy_preview(source, path):
    """Copy a user preview, rejecting anything the uploader will refuse."""
    with open(source, "rb") as fh:
        head = fh.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise SystemExit(f"pz-pack-web: {source} is not a PNG")
    width, height = struct.unpack(">II", head[16:24])
    if width > PREVIEW_SIZE or height > PREVIEW_SIZE:
        raise SystemExit(
            f"pz-pack-web: {source} is {width}x{height}; the uploader accepts at most "
            f"{PREVIEW_SIZE}x{PREVIEW_SIZE}"
        )
    shutil.copyfile(source, path)


def lua_string(value):
    """A Lua short-string literal. Values were already checked for quotes."""
    return '"' + value + '"'


# === PART 2 ===

def render_mod_info(pack, mod_id, mods):
    """`42/mod.info` — load last, never require.

    `require=` is a hard dependency: one missing/mature-gated item would make
    PZ skip the connector, which is exactly when the audit is needed. The
    ordering is `loadModAfter`, which is soft and ignored for absent mods.
    """
    order = ",".join(mods)
    return (
        f"name=PZ Pack Web - {pack}\n"
        f"id={mod_id}\n"
        "author=nixos-projectzomboid-servers\n"
        "description=Pack-wide ordering and a start-up audit for this modpack. "
        "Adds no content and overrides no files.\n"
        "versionMin=42.0.0\n"
        f"loadModAfter={order}\n"
    )


def render_manifest(pack, mods, mod_id):
    """Shared Lua table: the authoritative list the audit compares against."""
    lines = [
        "-- Generated by pz-pack-web from the modpack catalogue. Do not edit.",
        "PZPackWeb = PZPackWeb or {}",
        f"PZPackWeb.pack = {lua_string(pack)}",
        f"PZPackWeb.id = {lua_string(mod_id)}",
        f"PZPackWeb.count = {len(mods)}",
        "PZPackWeb.mods = {",
    ]
    lines += [f"    [{lua_string(mod_id)}] = true," for mod_id in mods]
    lines += ["}", ""]
    return "\n".join(lines)


def render_audit():
    """Server-start audit. Read-only, no files, no network, no game state."""
    return r"""-- Generated by pz-pack-web. Read-only: it logs, it changes nothing.
--
-- On a dedicated server, `Mods=` can be missing an entry while the server boots
-- cleanly; PZ only logs a generic "required mod not found" for the entries it
-- tries to load. This compares the ACTIVE list to the generated manifest, so a
-- missing or extra pack mod is named at start.
PZPackWeb = PZPackWeb or {}

local function active_mods()
    local set = {}
    local active = getActivatedMods and getActivatedMods() or nil
    if not active then
        return set
    end
    -- A java.util.ArrayList, not a Lua table: 0-based :get/:size.
    for i = 0, active:size() - 1 do
        set[active:get(i)] = true
    end
    return set
end

local function summarize(list, limit)
    if #list <= limit then
        return table.concat(list, "; ")
    end
    local shown = {}
    for i = 1, limit do
        shown[i] = list[i]
    end
    return table.concat(shown, "; ") .. string.format("; ... and %d more", #list - limit)
end

local function audit()
    if not isServer or not isServer() then
        return
    end
    if not PZPackWeb.mods then
        return
    end
    local active = active_mods()
    local missing, extra = {}, {}
    for id in pairs(PZPackWeb.mods) do
        if not active[id] then
            table.insert(missing, id)
        end
    end
    for id in pairs(active) do
        -- The connector is active but deliberately not in its own manifest.
        if id ~= PZPackWeb.id and not PZPackWeb.mods[id] then
            table.insert(extra, id)
        end
    end
    table.sort(missing)
    table.sort(extra)

    if #missing == 0 and #extra == 0 then
        print(string.format("[PZPackWeb] %s: all %d pack mods active", PZPackWeb.pack, PZPackWeb.count))
        return
    end
    if #missing > 0 then
        print(string.format(
            "[PZPackWeb] %s: %d pack mod(s) missing: %s",
            PZPackWeb.pack, #missing, summarize(missing, 25)
        ))
    end
    if #extra > 0 then
        print(string.format(
            "[PZPackWeb] %s: %d mod(s) outside the pack: %s",
            PZPackWeb.pack, #extra, summarize(extra, 25)
        ))
    end
end

Events.OnGameStart.Add(audit)
"""


def render_workshop_txt(pack, pack_data, mods, visibility, workshop_id):
    """`workshop.txt`. Repeated `description=` lines, BBCode is allowed."""
    title = f"PZ Pack Web - {pack}"
    description = pack_data.get("description") or f"Pack-wide companion for {pack}."
    lines = [
        "version=1",
    ]
    if workshop_id:
        lines.append(f"id={workshop_id}")
    lines += [
        f"title={title}",
        f"description={description}",
        "description=",
        f"description=Companion mod for the {len(mods)}-mod pack. It declares the pack's "
        "load order and logs any pack mod that is missing (or any extra mod) when a "
        "server starts.",
        "description=",
        "description=It adds no content, overrides no files, and does not redistribute "
        "any other mod. Safe to add to an existing world.",
        "description=",
        "description=Generated from the nixos-projectzomboid-servers modpack catalogue.",
        "tags=Build 42;Multiplayer",
        f"visibility={visibility}",
        "",
    ]
    return "\n".join(lines)


def build_tree(pack, pack_data, target, args):
    """Write the upload tree into a fresh temp dir, then move it into place."""
    mods = [check_value("mod id", m) for m in (pack_data.get("mods") or [])]
    if not mods:
        raise SystemExit(f"pz-pack-web: pack {pack!r} has no mods to link")
    if len(set(mods)) != len(mods):
        raise SystemExit(f"pz-pack-web: pack {pack!r} lists a duplicate Mod ID")

    mod_id = args.mod_id or generated_id(pack)
    if not _SAFE_GENERATED_ID.match(mod_id):
        raise SystemExit(f"pz-pack-web: {mod_id!r} is not a safe generated mod id")

    # Once the connector is added to the pack, the catalogue contains it too.
    # Do not make it depend on or audit itself.
    linked = [m for m in mods if m != mod_id]
    if not linked:
        raise SystemExit(f"pz-pack-web: pack {pack!r} has no mods besides the connector")

    parent = os.path.dirname(os.path.abspath(target)) or "."
    os.makedirs(parent, exist_ok=True)
    staging = tempfile.mkdtemp(prefix=".pz-pack-web-", dir=parent)
    try:
        item = os.path.join(staging, "item")
        mod_dir = os.path.join(item, "Contents", "mods", mod_id, "42")
        lua_shared = os.path.join(mod_dir, "media", "lua", "shared", "PZPackWeb")
        lua_server = os.path.join(mod_dir, "media", "lua", "server", "PZPackWeb")
        os.makedirs(lua_shared)
        os.makedirs(lua_server)

        files = {
            os.path.join(mod_dir, "mod.info"): render_mod_info(pack, mod_id, linked),
            os.path.join(lua_shared, "manifest.lua"): render_manifest(pack, linked, mod_id),
            os.path.join(lua_server, "audit.lua"): render_audit(),
            os.path.join(item, "workshop.txt"): render_workshop_txt(
                pack, pack_data, linked, args.visibility, args.workshop_id
            ),
        }
        for path, text in files.items():
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)

        if args.preview:
            copy_preview(args.preview, os.path.join(item, "preview.png"))
        else:
            write_preview(os.path.join(item, "preview.png"))

        if os.path.lexists(target):
            if not args.force:
                raise SystemExit(
                    f"pz-pack-web: {target} already exists; pass --force to replace it "
                    "(a published item's preview/description edits live there)"
                )
            shutil.rmtree(target)
        os.replace(item, target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    return mod_id, len(linked)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="pz-pack-web",
        description=(
            "Generate a ready-to-upload Steam Workshop item for a pack's connector mod. "
            "The item declares the pack's load order and audits the active mod list; it "
            "adds no content and overrides no files."
        ),
    )
    parser.add_argument("--pack", required=True, help="Modpack name from the catalogue")
    parser.add_argument(
        "--out-dir",
        default=None,
        help=(
            "Exact Workshop item folder to create. Default: "
            "$HOME/Zomboid/Workshop/PZPackWeb-<pack>"
        ),
    )
    parser.add_argument(
        "--catalogue",
        default=os.environ.get(CATALOGUE_ENV),
        help=f"JSON catalogue (default: ${CATALOGUE_ENV})",
    )
    parser.add_argument("--mod-id", default=None, help="Override the generated Mod ID")
    parser.add_argument(
        "--workshop-id",
        default=None,
        help="Existing Workshop id to UPDATE; omit to create a new item",
    )
    parser.add_argument(
        "--visibility",
        choices=VALID_VISIBILITY,
        default="private",
        help="workshop.txt visibility (default: private; change before publishing)",
    )
    parser.add_argument("--preview", default=None, help="Replace the generated 512x512 PNG")
    parser.add_argument("--force", action="store_true", help="Replace an existing --out-dir")
    parser.add_argument("--json", action="store_true", help="Machine-readable summary")
    args = parser.parse_args(argv)

    if args.workshop_id and not args.workshop_id.isdigit():
        parser.error("--workshop-id must be numeric")
    if args.preview and not os.path.isfile(args.preview):
        parser.error(f"--preview {args.preview!r} does not exist")

    if not args.catalogue or not os.path.isfile(args.catalogue):
        print(
            f"pz-pack-web: no readable catalogue at {args.catalogue!r}; "
            "run this through `nix run .#pz-pack-web`",
            file=sys.stderr,
        )
        return 2
    catalogue = pcm.load_catalogue(args.catalogue)
    if catalogue is None:
        return 2
    if args.pack not in catalogue:
        known = ", ".join(sorted(catalogue)) or "(none)"
        print(f"pz-pack-web: no such pack {args.pack!r}; known packs: {known}", file=sys.stderr)
        return 2

    pack_data = catalogue[args.pack]
    target = args.out_dir or os.path.join(DEFAULT_WORKSHOP_DIR, f"PZPackWeb-{args.pack}")
    target = os.path.expanduser(target)

    mod_id, count = build_tree(args.pack, pack_data, target, args)

    summary = {
        "pack": args.pack,
        "mod_id": mod_id,
        "mods": count,
        "out_dir": os.path.abspath(target),
        "workshop_id": args.workshop_id,
        "visibility": args.visibility,
        "preview": "provided" if args.preview else "generated placeholder",
    }
    if args.json:
        print(json.dumps(summary, indent=2))
        return 0

    print(f"pz-pack-web: wrote {summary['out_dir']}")
    print(f"  mod id: {mod_id}   linked mods: {count}")
    print(
        f"  workshop.txt: visibility={args.visibility}, "
        + (f"updating id {args.workshop_id}" if args.workshop_id else "new item (no id)")
    )
    if not args.preview:
        print("  preview.png is a generated placeholder - replace it with a real 512x512 PNG")
    print()
    print("Next:")
    print("  1. Project Zomboid -> Main Menu -> Workshop -> Create/Update")
    print(f"  2. Select the item folder: {os.path.basename(summary['out_dir'])}")
    print("  3. Review the visibility/description and Upload")
    if not args.workshop_id:
        print(
            f"  4. After upload, add the new Workshop id to the pack's `workshopMods` and "
            f"`{mod_id}` to its `mods` (pz-pack-doctor will verify it)."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

