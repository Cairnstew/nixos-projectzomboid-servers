#!/usr/bin/env python3
"""pz_client_mods.py — fetch a modpack's Workshop mods onto a CLIENT machine

WHAT "DOWNLOAD TO MY STEAM" CAN AND CANNOT MEAN
-----------------------------------------------
Project Zomboid's CLIENT loads Workshop mods through Steam's SUBSCRIPTION list
and never scans the library, so dropping content into
`steamapps/workshop/content/108600/` does NOT make the game load it — the
repository documents this and the client-host link exists only to spare a
second download's bytes. Subscribing is a Steam-client action with no public
write API, so it cannot be scripted.

What the client DOES load with no subscription at all is a LOCAL mod: the
official PZ wiki's "Manual local installation" is a folder in the game's `mods`
cache folder, and it names SteamCMD as the way to obtain the files. So this
tool's default is to download each Workshop item with SteamCMD and install the
mod(s) it contains into `~/Zomboid/mods` — which the game then loads.

Two modes:

    (default)          local mods -> <zomboid>/mods     LOADED by the client
    --steam-library    the Steam library workshop dir   NOT loaded until the
                                                         user SUBSCRIBES; a
                                                         pre-seed for someone
                                                         who will

ANONYMOUS STEAMCMD IS NOT ENOUGH FOR EVERY ITEM
-----------------------------------------------
`+login anonymous` downloads many Project Zomboid Workshop items, but not all:
items that need an account owning the game (mature-content gating, or the
author's own restrictions) answer `Access Denied` / `File Not Found`. Verified
against real ids: ZombieBuddy and Project Viewpoint download anonymously,
Brita's Armor Pack does not. Pass `--login <your-steam-name>` to authenticate as
an account that owns the game (SteamCMD prompts for the password / Steam Guard).
The prompt is confirmed reachable, but the authenticated download itself needs
real credentials and is the one path the repository's checks cannot cover.
SteamCMD caches that login under `$HOME`, which is why this tool does NOT
override HOME the way the server installer does.

WHY A RECURSIVE INSTALL
-----------------------
A Workshop item may hold one mod at its root or several under `mods/`. Rather
than guess, every directory containing a `mod.info` is treated as a mod root and
installed under the id that file declares — which is the same id the server's
`Mods=` list uses, so the two line up whatever the item's layout.

NON-WORKSHOP MODS ARE NOT DOWNLOADABLE. A pack's `mods` list names local mod
folders distributed outside Steam; those are reported and must be supplied by
hand.

STAGING MUST NOT BE UNDER /tmp
------------------------------
On NixOS `steamcmd` is wrapped with `steam-run`, which gives it a PRIVATE /tmp.
A `+force_install_dir` under /tmp therefore reports `Success` and then the files
are gone. Staging defaults to `~/.cache/pz-client-mods`, where the sandbox is
transparent, and `--staging` under /tmp produces a warning.

EXIT STATUS
-----------
0 on success (including a pack with nothing to do); 1 when a pack/input is
missing or an item failed to download; 2 for usage.

USAGE
-----
    pz_client_mods.py <pack> [--catalogue FILE] [--zomboid DIR]
                       [--steam-library] [--dest DIR] [--login NAME]
                       [--dry-run] [--json]
    pz_client_mods.py --ids 2625441155,2625840413 [--dry-run]
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

CATALOGUE_ENV = "PZ_MODPACKS_JSON"

# `id=` in a mod.info — PZ's local mod id, and what `Mods=` in a server config
# uses. Not the Workshop id.
_MOD_INFO_ID = re.compile(r"^\s*id\s*=\s*(.+?)\s*$", re.MULTILINE)


def load_catalogue(path):
    path = path or os.environ.get(CATALOGUE_ENV)
    if not path or not os.path.isfile(path):
        print(
            f"pz-client-mods: {CATALOGUE_ENV} is not set to a readable file; "
            "run this through `nix run .#pz-client-mods`",
            file=sys.stderr,
        )
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def discover_library(helper, appid, home=None, steam_root=None):
    """Return the Steam library root holding Project Zomboid, or None."""
    if not helper or not os.path.isfile(helper):
        return None
    cmd = [sys.executable, helper, "--appid", appid, "--library-root"]
    if home:
        cmd += ["--home", home]
    if steam_root:
        cmd += ["--steam-root", steam_root]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    lib = out.stdout.strip()
    return lib or None


def mod_roots(item_dir):
    """Every directory at or under item_dir that contains a mod.info."""
    found = []
    for root, dirs, files in os.walk(item_dir):
        if "mod.info" in files:
            found.append(root)
            # A mod.info marks the mod root; do not descend into a mod's own
            # media tree looking for more.
            dirs[:] = []
    return found


def mod_id(mod_root):
    try:
        with open(os.path.join(mod_root, "mod.info"), encoding="utf-8", errors="replace") as fh:
            match = _MOD_INFO_ID.search(fh.read())
    except OSError:
        return None
    return match.group(1).strip().strip('"') if match else None


def install_local(item_dir, target, item_id, force, report):
    """Copy each mod under item_dir into target. Returns the installed names."""
    roots = mod_roots(item_dir)
    if not roots:
        report.append((item_id, None, "no mod.info found — nothing installed"))
        return []
    installed = []
    for root in roots:
        mid = mod_id(root) or f"{item_id}-{os.path.basename(root)}"
        dest = os.path.join(target, mid)
        if os.path.exists(dest) and not force:
            report.append((item_id, mid, "already installed (use --force to refresh)"))
            installed.append(mid)
            continue
        if os.path.exists(dest) and force:
            shutil.rmtree(dest)
        shutil.copytree(root, dest)
        report.append((item_id, mid, "installed"))
        installed.append(mid)
    return installed


def default_staging():
    """A staging dir SteamCMD can actually write to.

    `steamcmd` on NixOS runs under `steam-run`, whose bwrap sandbox mounts a
    private /tmp — a download into /tmp reports success and leaves nothing
    behind. $HOME is transparent inside the sandbox, so stage there.
    """
    base = os.path.join(os.path.expanduser("~"), ".cache", "pz-client-mods")
    os.makedirs(base, exist_ok=True)
    return tempfile.mkdtemp(prefix="staging-", dir=base)


def steamcmd_download(steamcmd, install_dir, appid, item_ids, login):
    """Download every item in ONE steamcmd invocation, streaming its output.

    One invocation, not one per item: with `--login` that means the password /
    Steam Guard prompt appears exactly once. Output is deliberately inherited
    rather than captured — a captured prompt is an invisible one — and success
    is judged by the content directory afterwards, because steamcmd's exit code
    says nothing useful about an individual `workshop_download_item`.
    """
    cmd = [steamcmd, "+force_install_dir", install_dir, "+login", login or "anonymous"]
    for item_id in item_ids:
        cmd += ["+workshop_download_item", appid, item_id]
    cmd.append("+quit")
    try:
        subprocess.run(cmd)
    except OSError as exc:
        print(f"pz-client-mods: cannot run steamcmd ({steamcmd}): {exc}", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="pz-client-mods",
        description="Download a modpack's Workshop mods for a Project Zomboid client.",
    )
    parser.add_argument("pack", nargs="?", help="modpack name from the catalogue")
    parser.add_argument("--ids", default=None, help="comma-separated Workshop ids instead of a pack")
    parser.add_argument("--catalogue", default=None, help=f"catalogue JSON (default: ${CATALOGUE_ENV})")
    parser.add_argument("--zomboid", default=os.path.expanduser("~/Zomboid"), help="client Zomboid home (default: ~/Zomboid)")
    parser.add_argument(
        "--steam-library",
        action="store_true",
        help="write into the Steam library's workshop content instead of local mods "
        "(NOT loaded by the client until subscribed)",
    )
    parser.add_argument("--dest", default=None, help="explicit target (local mods dir, or library root with --steam-library)")
    parser.add_argument("--appid", default="108600", help="Project Zomboid app id (default: 108600)")
    parser.add_argument("--home", default=None, help="HOME to probe for Steam (default: the real one)")
    parser.add_argument("--steam-root", default=None, help="Steam root to probe")
    parser.add_argument("--steamcmd", default=os.environ.get("PZ_STEAMCMD", "steamcmd"), help="steamcmd executable")
    parser.add_argument(
        "--login",
        default=None,
        help="Steam account to log in as instead of anonymous. Needed for items "
        "that answer 'Access Denied' anonymously; SteamCMD prompts for the password.",
    )
    parser.add_argument(
        "--workshop-helper",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "pz_steam_workshop.py"),
        help="path to pz_steam_workshop.py, used to discover the Steam library",
    )
    parser.add_argument("--staging", default=None, help="download staging dir (default: a temp dir)")
    parser.add_argument("--force", action="store_true", help="reinstall mods that are already present")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and exit")
    parser.add_argument("--json", action="store_true", help="emit the plan as JSON (implies no download)")
    args = parser.parse_args(argv)

    # ── What to fetch ───────────────────────────────────────────────────────
    titles = {}
    local_mods = []
    label = ""
    if args.ids:
        items = [i.strip() for i in args.ids.split(",") if i.strip()]
        label = "--ids"
    else:
        if not args.pack:
            parser.error("a pack name or --ids is required")
        catalogue = load_catalogue(args.catalogue)
        if catalogue is None:
            return 1
        if args.pack not in catalogue:
            print(
                f"pz-client-mods: no such modpack: {args.pack}. "
                f"Available: {', '.join(sorted(catalogue))}",
                file=sys.stderr,
            )
            return 1
        pack = catalogue[args.pack]
        items = [m["id"] for m in pack.get("workshopMods", [])]
        titles = {m["id"]: (m.get("title") or "(untitled)") for m in pack.get("workshopMods", [])}
        local_mods = list(pack.get("mods", []))
        label = args.pack

    if not items:
        # A pack may legitimately have no Workshop items (a local-mods-only
        # pack), and a client that is already in sync should not look like a
        # failure to a calling script.
        print(f"pz-client-mods: {label} has no Workshop items to fetch; nothing to do", file=sys.stderr)
        return 0

    # ── Where they land ─────────────────────────────────────────────────────
    if args.dest:
        target = args.dest
    elif args.steam_library:
        lib = discover_library(args.workshop_helper, args.appid, args.home, args.steam_root)
        if lib is None:
            print(
                "pz-client-mods: Project Zomboid is not installed via Steam "
                "(no appmanifest in any library), so there is no library to write into",
                file=sys.stderr,
            )
            return 1
        target = lib
    else:
        target = os.path.join(args.zomboid, "mods")

    mode = "steam-library" if args.steam_library else "local-mods"
    login_label = args.login or "anonymous"

    plan = {
        "pack": label,
        "mode": mode,
        "target": target,
        "login": login_label,
        "items": [{"id": i, "title": titles.get(i)} for i in items],
        "localMods": local_mods,
    }

    if args.dry_run or args.json:
        if args.json:
            print(json.dumps(plan, indent=2))
        else:
            print(f"pz-client-mods: {label} — {len(items)} Workshop item(s)")
            print(f"  mode:    {mode} -> {target}")
            print(f"  login:   {login_label}")
            print(f"  steamcmd: {args.steamcmd}")
            print("  would download:")
            for i in items:
                print(f"    {i}  {titles.get(i, '')}".rstrip())
            if local_mods:
                print(f"  NOTE: {len(local_mods)} non-Workshop mod(s) must be supplied by hand:")
                for m in local_mods:
                    print(f"    {m}")
        if mode == "steam-library":
            print(
                "  NOTE: the client will NOT load these until the items are SUBSCRIBED in Steam.",
                file=sys.stderr,
            )
        return 0

    # ── Download ────────────────────────────────────────────────────────────
    staging = args.staging or default_staging()
    if staging.startswith(("/tmp/", "/var/tmp/")):
        print(
            "pz-client-mods: WARNING: staging under /tmp is invisible to steamcmd "
            "(it runs in a steam-run sandbox with a private /tmp); downloads may vanish",
            file=sys.stderr,
        )
    install_dir = target if mode == "steam-library" else staging

    print(
        f"pz-client-mods: downloading {len(items)} item(s) via steamcmd ({login_label})",
        file=sys.stderr,
    )
    steamcmd_download(args.steamcmd, install_dir, args.appid, items, args.login)

    content_root = os.path.join(install_dir, "steamapps", "workshop", "content", args.appid)
    report = []
    installed = []
    failed = 0
    for item_id in items:
        item_dir = os.path.join(content_root, item_id)
        if not os.path.isdir(item_dir):
            failed += 1
            report.append((item_id, None, "DOWNLOAD FAILED"))
            continue
        if mode == "steam-library":
            report.append((item_id, None, "placed in the Steam library (subscribe to load)"))
            continue
        os.makedirs(target, exist_ok=True)
        installed += install_local(item_dir, target, item_id, args.force, report)

    # ── Summary ─────────────────────────────────────────────────────────────
    if mode == "local-mods":
        print(f"pz-client-mods: {label}: {len(installed)} mod(s) installed to {target}")
    for item_id, mid, what in report:
        if what not in ("installed",):
            print(f"  {item_id}  {mid or ''}  {what}".rstrip())
    if failed and not args.login:
        print(
            f"  NOTE: {failed} item(s) need an account that owns Project Zomboid. "
            "Re-run with --login <your-steam-name> (SteamCMD will prompt).",
            file=sys.stderr,
        )
    if local_mods:
        print(
            f"  NOTE: {len(local_mods)} non-Workshop mod(s) still need manual placement in "
            f"{os.path.join(args.zomboid, 'mods')}: {', '.join(local_mods)}",
            file=sys.stderr,
        )
    if mode == "steam-library":
        print(
            "  NOTE: subscribe to the items in Steam, or the client will not load them.",
            file=sys.stderr,
        )

    if args.staging is None:
        shutil.rmtree(staging, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
