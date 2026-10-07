#!/usr/bin/env python3
"""pz_prune.py — make an installed mod set match what is declared

WHY THIS EXISTS
---------------
The install and prep steps are ADDITIVE by design: steamcmd downloads an item
that is not on disk and skips one that is, and the prep script links each
declared Workshop item into the server's home. Nothing ever subtracts. So when a
server is switched from one pack to another:

  * the shared steamcmd cache keeps every item every pack ever asked for, and
  * each server's `Zomboid/Workshop/content/108600/` keeps a symlink for every
    item it ever declared.

Neither is merely untidy. `scripts/pz_maps.py` derives `Map=` by scanning the
shared workshop root, so a map shipped by a mod that is no longer in the pack
still lands in the server config — a removed mod quietly keeps contributing
terrain. Dropping the stale entries is what makes "the config is the truth" hold.

TWO ROOTS, TWO SUBCOMMANDS
--------------------------
Both answer the same question — "keep exactly these ids, remove everything
else" — but the two roots need different safety rules:

  workshop --root DIR --keep ID...
      The SHARED steamcmd content directory
      (`<serverDir>/steamapps/workshop/content/108600`). Every child whose name
      is a numeric item id and is not in --keep is deleted. Non-numeric entries
      are left alone: steamcmd keeps bookkeeping of its own there, and a stray
      file is not this tool's to remove.

  links --root DIR --keep ID...
      A server's LINK FARM, either its Workshop content directory
      (`<dataDir>/<server>/Zomboid/Workshop/content/108600`) or its local mods
      directory (`<dataDir>/<server>/Zomboid/mods`). A non-kept child is removed
      only when it is a SYMLINK. A real directory is never touched — a user may
      have placed one by hand, and `workshop` mode is the only one allowed to
      delete real directories.

`--dry-run` prints what would be removed and changes nothing.

EXIT STATUS
-----------
0 on success; 1 when a root cannot be read or a removal fails; 2 for usage.

USAGE
-----
    pz_prune.py workshop --root DIR --keep ID [--keep ID ...] [--dry-run]
    pz_prune.py links    --root DIR --keep ID [--keep ID ...] [--dry-run]
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys


def prune_workshop(root: str, keep: set[str], dry_run: bool = False) -> list[str]:
    """Delete every numeric-named child of the shared content root not in `keep`.

    Returns the names removed (or that would be, under --dry-run). A missing
    root is not an error: nothing has been installed yet, so there is nothing
    to prune.
    """
    removed: list[str] = []
    if not os.path.isdir(root):
        return removed
    with os.scandir(root) as it:
        for item in it:
            if not item.name.isdigit():
                # steamcmd's own files (appworkshop_<appid>.acf and friends).
                continue
            if item.name in keep:
                continue
            if dry_run:
                removed.append(item.name)
                continue
            if item.is_dir(follow_symlinks=False):
                shutil.rmtree(item.path)
            else:
                os.unlink(item.path)
            removed.append(item.name)
    return removed


def prune_links(root: str, keep: set[str], dry_run: bool = False) -> list[str]:
    """Remove every SYMLINK child of `root` not in `keep`.

    Real directories and files are left untouched, so a hand-placed mod and the
    shared download are both safe. A missing root is not an error.
    """
    removed: list[str] = []
    if not os.path.isdir(root):
        return removed
    with os.scandir(root) as it:
        for item in it:
            if not item.is_symlink():
                continue
            if item.name in keep:
                continue
            if dry_run:
                removed.append(item.name)
                continue
            os.unlink(item.path)
            removed.append(item.name)
    return removed


def _keep_set(values: list[str] | None) -> set[str]:
    return {v for v in (values or []) if v}


def _run(mode: str, args: argparse.Namespace) -> int:
    keep = _keep_set(args.keep)
    if mode == "workshop":
        removed = prune_workshop(args.root, keep, args.dry_run)
        verb = "would remove" if args.dry_run else "removed"
        label = "Workshop item"
    else:
        removed = prune_links(args.root, keep, args.dry_run)
        verb = "would unlink" if args.dry_run else "unlinked"
        label = "stale link"

    for name in sorted(removed):
        print(f"pz-prune: {verb} {label} {name}", file=sys.stderr)
    if not removed:
        print("pz-prune: nothing to prune", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="pz-prune",
        description="Remove installed mods that are no longer declared.",
    )
    sub = parser.add_subparsers(dest="mode", required=True)

    for mode, help_text in (
        ("workshop", "prune the shared steamcmd Workshop content directory"),
        ("links", "prune a server's symlink farm (Workshop content or local mods)"),
    ):
        p = sub.add_parser(mode, help=help_text)
        p.add_argument("--root", required=True, help="directory to prune")
        p.add_argument(
            "--keep",
            action="append",
            default=[],
            metavar="ID",
            help="an id to keep; repeatable",
        )
        p.add_argument("--dry-run", action="store_true", help="print, change nothing")

    args = parser.parse_args(argv)
    try:
        return _run(args.mode, args)
    except OSError as exc:
        print(f"pz-prune: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
