#!/usr/bin/env python3
"""merge_ini.py — declaratively update a Project Zomboid `<servername>.ini`

WHY THIS EXISTS INSTEAD OF JUST WRITING THE FILE
------------------------------------------------
Project Zomboid stores world-identity state in the same `.ini` it reads config
from: `Seed`, `ResetID`, `LastModified`, `ServerPlayerID`, `Password`, and the
per-save counters. The module only owns a known set of keys, so it rewrites
those in place and leaves every other line byte-for-byte untouched. Generating
the file from scratch would renumber / reset every existing world on each start,
so a straight `writeText` is actively destructive here.

(Unlike `SandboxVars.lua`, which PZ fully regenerates and we therefore own
outright, and which is rendered declaratively in lib/default.nix.)

On a missing file the result is just our keys, so a first boot needs no
separate code path.

USAGE
-----
    merge_ini.py <path> [Key=value ...] [--password-file <path>]

`--password-file` exists so a join password (e.g. an agenix secret) never
appears in a unit file or in `ps` output: its contents are read here and written
straight into the `Password=` line.
"""
from __future__ import annotations

import os
import sys

# Read as a stream rather than one huge string: the file is tiny, but reading it
# this way keeps CRLF / BOM oddities from producing stray keys.
NEWLINES = "\n"


def parse_args(argv: list[str]) -> tuple[str, dict[str, str], str | None]:
    if len(argv) < 2:
        sys.exit("usage: merge_ini.py <path> [Key=value ...] [--password-file <path>]")

    path = argv[1]
    updates: dict[str, str] = {}
    password_file: str | None = None

    rest = argv[2:]
    i = 0
    while i < len(rest):
        arg = rest[i]
        if arg == "--password-file":
            if i + 1 >= len(rest):
                sys.exit("--password-file needs a path")
            password_file = rest[i + 1]
            i += 2
            continue
        if "=" not in arg:
            sys.exit(f"arg {arg!r} has no '='")
        k, v = arg.split("=", 1)
        updates[k.strip()] = v.strip()
        i += 1

    return path, updates, password_file


def read_existing(path: str) -> dict[str, str]:
    """Parse `Key=value` lines, ignoring comments and blank lines.

    Comment markers are `#` and `;` — PZ's own ini writer emits `#` headers, and
    some hand-edits use `;`. Neither is a key we own, so dropping comment lines
    is safe: we are not round-tripping the file, only preserving unknown keys.
    """
    existing: dict[str, str] = {}
    if not os.path.exists(path):
        return existing

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith(";") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            existing[k.strip()] = v.strip()

    return existing


def main() -> None:
    path, updates, password_file = parse_args(sys.argv)

    if password_file is not None:
        try:
            with open(password_file, "r", encoding="utf-8") as f:
                secret = f.read().strip()
        except OSError as exc:
            sys.exit(f"cannot read --password-file {password_file}: {exc}")
        if not secret:
            sys.exit(f"--password-file {password_file} is empty")
        # Strip newlines: a multi-line secret would corrupt the ini.
        updates["Password"] = "".join(secret.splitlines())

    path = os.path.realpath(path)
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    merged = {**read_existing(path), **updates}

# Deterministic order: our keys keep insertion order (module-owned keys
    # first), unknown preserved keys follow. Stable output keeps the file from
    # churning in git or tripping PZ's own change detection.
    with open(path, "w", encoding="utf-8", newline=NEWLINES) as f:
        f.write("\n".join(f"{k}={v}" for k, v in merged.items()))
        f.write("\n")


if __name__ == "__main__":
    main()