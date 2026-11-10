#!/usr/bin/env python3
"""merge_modlist_preset.py — install ONE managed preset into PZ's preset file.

WHY THIS EXISTS INSTEAD OF A `writeText`
----------------------------------------
Project Zomboid's Build 42 mod selector stores *all* of a player's mod presets
and favourites in one small file:

    ~/Zomboid/Lua/pz_modlist_settings.cfg

Format (as written by `ModSelector.Model:saveModDataToFile`):

    !fav!:id;id;...;
    <preset-name>:id;id;...;

The user's own presets and favourites live in the same file, so a Nix-rendered
`writeText` installed over it would delete them on every activation. This script
rewrites only the one managed preset line and leaves every other byte alone.

USAGE
-----
    merge_modlist_preset.py <cfg> <preset-name> <fragment>

`<fragment>` is the Nix-rendered single line `<preset-name>:id;id;...;` (a store
file, so it cannot go through argv without quoting it). It is validated here as
well as at build time, because a `;` or `:` inside a mod id would silently split
into two entries rather than fail.

The merge is idempotent: re-running with the same fragment leaves the file
byte-for-byte unchanged (and does not touch its mtime).

The file is only written atomically (temp file + rename) so a concurrent game
read never sees a half-written preset list.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path
from typing import NoReturn

UNSAFE_IN_ID = (":", ";", "\\", "\n", "\r")


def die(message: str) -> NoReturn:
    print(f"merge_modlist_preset: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_fragment(path: Path, name: str) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"cannot read preset fragment {path}: {exc}")

    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        die(f"preset fragment {path} must contain exactly one non-empty line, got {len(lines)}")

    line = lines[0]
    sep = line.find(":")
    if sep < 0:
        die(f"preset fragment {path} has no ':' separator")
    if line[:sep] != name:
        die(f"preset fragment names {line[:sep]!r}, expected {name!r}")

    ids = [part for part in line[sep + 1 :].split(";") if part != ""]
    if not ids:
        die(f"preset fragment {path} contains no mod ids")
    for mod_id in ids:
        if any(bad in mod_id for bad in UNSAFE_IN_ID):
            die(f"mod id {mod_id!r} contains one of ':', ';', '\\' or a newline")
    if len(ids) != len(set(ids)):
        die(f"preset fragment {path} contains duplicate mod ids")

    return [name + ":" + ";".join(ids) + ";"]


def merge(existing: list[str], managed: str, name: str) -> list[str]:
    """Return `existing` with the one `<name>:` line replaced or appended.

    The first line is preserved exactly when it is the `!fav!` line: the game
    only recognises favourites at index 0, and it must stay there.
    """
    out: list[str] = []
    replaced = False

    for index, line in enumerate(existing):
        if index == 0 and line.startswith("!fav!"):
            out.append(line)
            continue
        sep = line.find(":")
        if sep >= 0 and line[:sep] == name:
            if not replaced:
                out.append(managed)
                replaced = True
            # A duplicate managed line is dropped; the game would keep whichever
            # one `pairs()` happens to visit last, which is not deterministic.
            continue
        out.append(line)

    if not replaced:
        out.append(managed)
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        die("usage: merge_modlist_preset.py <cfg> <preset-name> <fragment>")

    cfg = Path(argv[1])
    name = argv[2]
    fragment = Path(argv[3])

    if name == "" or any(bad in name for bad in UNSAFE_IN_ID):
        die(f"preset name {name!r} is empty or contains ':', ';', '\\' or a newline")

    managed = read_fragment(fragment, name)[0]

    if cfg.exists():
        try:
            existing = cfg.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            die(f"cannot read {cfg}: {exc}")
    else:
        existing = []

    if not existing:
        # Match the game's own writer: favourites first, even when empty.
        existing = ["!fav!:"]

    merged = merge(existing, managed, name)
    text = "\n".join(merged) + "\n"

    if cfg.exists():
        try:
            if cfg.read_text(encoding="utf-8") == text:
                return 0
            mode = cfg.stat().st_mode & 0o777
        except OSError:
            mode = 0o644
    else:
        mode = 0o644

    cfg.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(cfg.parent), prefix=cfg.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, cfg)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
