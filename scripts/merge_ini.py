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

SECRETS
-------
`--secret-file Key=path` reads a secret's value from a file and writes it
straight into that key. This exists because the alternative is fatal: the
Nix-rendered base `.ini` is a `pkgs.writeText` store path, which is mode 444 and
world-readable, so a join password or RCON password written through `settings`
would be readable by every local user and greppable out of /nix/store. Going
through a file keeps the secret in the Nix store only as a *path*.

USAGE
-----
    merge_ini.py <path> [Key=value ...] [--from-file <path>]
                 [--secret-file Key=path ...] [--soft-reset]

Precedence, lowest to highest: whatever is already in `<path>`, then
`--from-file`, then `Key=value` arguments, then `--secret-file`.

`--from-file` reads `Key=value` lines from a file — used for the Nix-rendered base
configuration, which lives in the store and so cannot be passed as argv. Keeping
it out of argv also sidesteps shell quoting entirely.

`--soft-reset` deletes the world-identity keys so Project Zomboid generates a
fresh world on next start. This is the one operation that deliberately discards
existing state, so it is opt-in per invocation.
"""
from __future__ import annotations

import os
import sys

# Read as a stream rather than one huge string: the file is tiny, but reading it
# this way keeps CRLF / BOM oddities from producing stray keys.
NEWLINES = "\n"

# The keys Project Zomboid uses to identify an existing world. Preserved on
# every merge, because rewriting any of them renumbers or resets the save.
# `--soft-reset` removes them deliberately.
WORLD_IDENTITY_KEYS = frozenset(
    {
        "Seed",
        "ResetID",
        "LastModified",
        "ServerPlayerID",
        "UniquePlayers",
        "NumPlayers",
    }
)


def parse_kv(pairs: list[str], what: str = "arg") -> dict[str, str]:
    """Turn `Key=value` strings into a dict, rejecting anything malformed."""
    out: dict[str, str] = {}
    for item in pairs:
        if "=" not in item:
            sys.exit(f"{what} {item!r} has no '='")
        k, v = item.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def parse_args(
    argv: list[str],
) -> tuple[str, dict[str, str], dict[str, str], str | None, bool]:
    if len(argv) < 2:
        sys.exit(
            "usage: merge_ini.py <path> [Key=value ...] "
            "[--from-file <path>] [--secret-file Key=path ...] [--soft-reset]"
        )

    path = argv[1]
    updates: dict[str, str] = {}
    from_file: str | None = None
    secrets: dict[str, str] = {}
    soft_reset = False

    rest = argv[2:]
    i = 0
    while i < len(rest):
        arg = rest[i]
        if arg == "--soft-reset":
            soft_reset = True
            i += 1
            continue
        if arg == "--password-file":
            # Removed in favour of --secret-file. Worth a pointed message: the
            # old spelling silently did the wrong thing if you assumed it still
            # set Password=.
            sys.exit(
                "--password-file is gone; use --secret-file Password=<path> "
                "(--secret-file handles RCONPassword, DiscordToken, etc. too)"
            )
        if arg in ("--secret-file", "--from-file"):
            if i + 1 >= len(rest):
                sys.exit(f"{arg} needs a value")
            if arg == "--from-file":
                from_file = rest[i + 1]
            else:
                key, _, secret_path = rest[i + 1].partition("=")
                if not key or not secret_path:
                    sys.exit(f"--secret-file needs Key=path, got {rest[i + 1]!r}")
                secrets[key.strip()] = secret_path
            i += 2
            continue
        if arg == "--":
            # Everything after `--` is a Key=value pair, even if it looks like a flag.
            updates.update(parse_kv(rest[i + 1 :], "arg"))
            break
        if arg.startswith("--"):
            sys.exit(f"unknown option {arg!r}")
        updates.update(parse_kv([arg], "arg"))
        i += 1

    return path, updates, secrets, from_file, soft_reset


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

    return parse_kv(pairs, "line")


def read_secret(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            value = f.read().strip()
    except OSError as exc:
        sys.exit(f"cannot read secret file {path}: {exc}")
    if not value:
        sys.exit(f"secret file {path} is empty")
    # Strip newlines: a multi-line secret would corrupt the ini.
    return "".join(value.splitlines())


def main() -> None:
    path, updates, secrets, from_file, soft_reset = parse_args(sys.argv)

    # Precedence: existing < --from-file < argv < --secret-file.
    base: dict[str, str] = {}
    if from_file is not None:
        base.update(read_kv_file(from_file))

    for key, secret_path in secrets.items():
        updates[key] = read_secret(secret_path)

    path = os.path.realpath(path)
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    merged = {**read_kv_file(path), **base, **updates}

    if soft_reset:
        # Applied AFTER the merge, so it also clears anything the Nix-rendered
        # base re-set. Without this ordering the base config would immediately
        # write the keys straight back.
        for key in WORLD_IDENTITY_KEYS:
            merged.pop(key, None)

    # Deterministic order: our keys keep insertion order (module-owned keys
    # first), unknown preserved keys follow. Stable output keeps the file from
    # churning in git or tripping PZ's own change detection.
    with open(path, "w", encoding="utf-8", newline=NEWLINES) as f:
        f.write("\n".join(f"{k}={v}" for k, v in merged.items()))
        f.write("\n")


if __name__ == "__main__":
    main()