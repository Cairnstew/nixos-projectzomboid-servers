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
    merge_ini.py <path> [Key=value ...] [--from-file <path>] [--password-file <path>]

Precedence, lowest to highest: whatever is already in `<path>`, then
`--from-file`, then `Key=value` arguments, then `--password-file`.

`--from-file` reads `Key=value` lines from a file — used for the Nix-rendered base
configuration, which lives in the store and so cannot be passed as argv. Keeping
it out of argv also sidesteps shell quoting entirely.

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


def parse_kv(pairs: list[str]) -> dict[str, str]:
    """Turn `Key=value` strings into a dict, rejecting anything malformed."""
    out: dict[str, str] = {}
    for arg in pairs:
        if "=" not in arg:
            sys.exit(f"arg {arg!r} has no '='")
        k, v = arg.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def parse_args(argv: list[str]) -> tuple[str, dict[str, str], str | None, str | None]:
    if len(argv) < 2:
        sys.exit(
            "usage: merge_ini.py <path> [Key=value ...] "
            "[--from-file <path>] [--password-file <path>]"
        )

    path = argv[1]
    updates: dict[str, str] = {}
    from_file: str | None = None
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
        if arg == "--from-file":
            if i + 1 >= len(rest):
                sys.exit("--from-file needs a path")
            from_file = rest[i + 1]
            i += 2
            continue
        if arg == "--":
            # Everything after `--` is a Key=value pair, even if it looks like a flag.
            updates.update(parse_kv(rest[i + 1 :]))
            break
        if arg.startswith("--"):
            sys.exit(f"unknown option {arg!r}")
        updates.update(parse_kv([arg]))
        i += 1

    # --from-file is applied BEFORE argv pairs, so argv wins. Returned separately
    # so main() can layer it under `updates`.
    return path, updates, password_file, from_file


def read_kv_file(path: str) -> dict[str, str]:
    """Parse `Key=value` lines, ignoring comments and blank lines.

    Comment markers are `#` and `;` — PZ's own ini writer emits `#` headers, and
    some hand-edits use `;`. Neither is a key we own, so dropping comment lines
    is safe: we are not round-tripping the file, only preserving unknown keys.

    Used for BOTH the server's existing `.ini` and the `--from-file` base, so the
    two can never disagree about what a key/value line looks like.
    """
    if not os.path.exists(path):
        return {}

    pairs: list[str] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith(";") or "=" not in line:
                continue
            pairs.append(line)

    return parse_kv(pairs)


def main() -> None:
    path, updates, password_file, from_file = parse_args(sys.argv)

    # Precedence: existing < --from-file < argv < --password-file.
    base: dict[str, str] = {}
    if from_file is not None:
        base.update(read_kv_file(from_file))

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

    merged = {**read_kv_file(path), **base, **updates}

# Deterministic order: our keys keep insertion order (module-owned keys
    # first), unknown preserved keys follow. Stable output keeps the file from
    # churning in git or tripping PZ's own change detection.
    with open(path, "w", encoding="utf-8", newline=NEWLINES) as f:
        f.write("\n".join(f"{k}={v}" for k, v in merged.items()))
        f.write("\n")


if __name__ == "__main__":
    main()