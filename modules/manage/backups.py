#!/usr/bin/env python3
"""Backup and restore for Project Zomboid dedicated servers.

The module renders one JSON description of every enabled server (the same file
the dashboard reads) and this script is the only writer of the backup tree.

What is backed up, per server, relative to that server's home
(``<dataDir>/<name>``):

    Zomboid/Saves   the world
    Zomboid/db      <servername>.db — Build 42 whitelist/admins/players
    Zomboid/Server  the merged .ini, SandboxVars, spawn files
    Zomboid/Lua     server-side Lua (including PanelBridge queues)

``Zomboid/Server`` contains the merged .ini, and that file contains the RCON and
join passwords (they are written there from ``secretFiles`` at start). Archives
are therefore SECRET MATERIAL even though the Steam token is excluded. They are
created mode 0640 in a 0770 directory so the dashboard's group can read them;
treat a copy moved off the host as a credential and encrypt it in transit.

Deliberately NOT backed up: ``.local/share/Steam`` (the cached Steam token is a
credential), the shared install, and the Workshop symlinks (they are derivable
from the modpack and re-created on the next start).

Archives are plain ``tar --zstd`` files, so a restore is possible with no tool
from this repository:

    systemctl stop project-zomboid-viewpoint
    tar --zstd -xf viewpoint-20261112-030000.tar.zst -C /mnt/data/project-zomboid/viewpoint
    systemctl start project-zomboid-viewpoint

The ``restore`` subcommand automates exactly that sequence, refuses to run
while the unit is active, and takes a safety archive first.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from rcon import RconClient, RconError

# The paths inside a server's home that make up its state. Kept in one place so
# the archive layout and the restore layout cannot drift.
BACKUP_PATHS = [
    "Zomboid/Saves",
    "Zomboid/db",
    "Zomboid/Server",
    "Zomboid/Lua",
]

# Only archives this script created, and only inside the configured directory.
# The optional `-N` suffix keeps two backups in the same second from
# overwriting each other (a manual backup racing the timer).
ARCHIVE_RE = re.compile(r"^[A-Za-z0-9._-]+-\d{8}-\d{6}(-\d+)?\.tar\.zst$")


def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def server_by_name(config: dict, name: str) -> dict:
    for server in config.get("servers", []):
        if server.get("name") == name:
            return server
    raise SystemExit(f"unknown server: {name}")


def unit_active(unit: str) -> bool:
    try:
        return (
            subprocess.run(
                ["systemctl", "is-active", "--quiet", unit],
                capture_output=True,
                timeout=10,
            ).returncode
            == 0
        )
    except (OSError, subprocess.TimeoutExpired):
        return False


def rcon_save(server: dict) -> str | None:
    """Ask a running server to flush its world before tar reads it.

    Best-effort: a server without RCON, or one that is not running, is backed
    up anyway. The tar then reads whatever is on disk, which is why the docs
    say a stopped server produces the cleanest archive.
    """
    password_file = server.get("rconPasswordFile")
    port = server.get("rconPort") or 0
    if not password_file or port == 0:
        return None
    try:
        password = Path(password_file).read_text(encoding="utf-8").strip()
    except OSError as exc:
        return f"cannot read RCON password file: {exc}"
    try:
        with RconClient(
            server.get("rconHost", "127.0.0.1"), port, password, timeout=5
        ) as client:
            client.command("save")
        return None
    except RconError as exc:
        return str(exc)


def archive_dir(server: dict) -> Path:
    return Path(server["backupDirectory"])


def archive_name(server: dict, stamp: str | None = None) -> str:
    base = f"{server['name']}-{stamp or time.strftime('%Y%m%d-%H%M%S')}"
    directory = archive_dir(server)
    candidate = f"{base}.tar.zst"
    suffix = 1
    while (directory / candidate).exists():
        candidate = f"{base}-{suffix}.tar.zst"
        suffix += 1
    return candidate


def prune(directory: Path, server_name: str, keep: int, protect: Path | None = None) -> list[str]:
    """Delete the oldest archives beyond ``keep``; return the deleted names.

    ``protect`` (the archive just written) is always kept, even if two archives
    share a timestamp and the name sort would otherwise place it first.
    """
    if keep is None or keep <= 0:
        return []
    archives = [
        p
        for p in directory.iterdir()
        if p.is_file() and p.name.startswith(f"{server_name}-") and ARCHIVE_RE.match(p.name)
    ]
    archives.sort(key=lambda p: (p.stat().st_mtime, p.name))
    if protect is not None and protect in archives:
        archives.remove(protect)
        archives.append(protect)
    removed = []
    for old in archives[:-keep]:
        try:
            old.unlink()
            removed.append(old.name)
        except OSError:
            pass
    return removed


def create_backup(server: dict, reason: str = "manual") -> dict:
    """Create one archive. Returns a small JSON-able result."""
    home = Path(server["home"])
    directory = archive_dir(server)
    keep = int(server.get("backupKeep") or 0)
    directory.mkdir(parents=True, exist_ok=True)

    paths = [p for p in BACKUP_PATHS if (home / p).exists()]
    if not paths:
        raise RuntimeError(f"{server['name']}: nothing to back up under {home}")

    save_error = None
    if unit_active(server["unit"]):
        save_error = rcon_save(server)
        if save_error is None:
            # PZ writes the save asynchronously; give it a moment before tar
            # starts reading the same files.
            time.sleep(2)

    final = directory / archive_name(server)
    temporary = directory / f".{final.name}.{os.getpid()}.tmp"
    command = [
        "tar",
        "--zstd",
        "-cf",
        str(temporary),
        "-C",
        str(home),
        *paths,
    ]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=60 * 60,
        )
        # GNU tar exits 1 when a file changed while it was being read. That is
        # exactly what a live world does, and the archive is still usable; a
        # real failure exits 2.
        if result.returncode not in (0, 1):
            raise RuntimeError(
                f"tar failed ({result.returncode}): {result.stderr.strip()[:500]}"
            )
        os.replace(temporary, final)
        # The unit sets UMask=0027, but a manual run may have a permissive
        # umask. The archive contains Zomboid/Server, which holds the merged
        # .ini and therefore the RCON/join passwords; keep it group-readable
        # for the dashboard and never world-readable.
        os.chmod(final, 0o640)
    finally:
        try:
            temporary.unlink()
        except OSError:
            pass

    removed = prune(directory, server["name"], keep, protect=final)
    return {
        "server": server["name"],
        "archive": str(final),
        "name": final.name,
        "size": final.stat().st_size,
        "reason": reason,
        "saveError": save_error,
        "pruned": removed,
    }


def list_backups(server: dict) -> list[dict]:
    directory = archive_dir(server)
    if not directory.is_dir():
        return []
    entries = []
    paths = [p for p in directory.iterdir() if p.is_file() and ARCHIVE_RE.match(p.name)]
    paths.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    for path in paths:
        stat = path.stat()
        entries.append(
            {
                "name": path.name,
                "size": stat.st_size,
                "mtime": int(stat.st_mtime),
            }
        )
    return entries


def validate_archive_members(archive: Path) -> None:
    """Refuse an archive whose members could escape the server home.

    ``restore`` extracts into ``<dataDir>/<name>`` as the service user, so an
    absolute member or one containing ``..`` would write outside the world.
    ``tar`` has its own protections, but this check is explicit and produces a
    message that names the offending member.
    """
    result = subprocess.run(
        ["tar", "--zstd", "-tf", str(archive)],
        capture_output=True,
        text=True,
        timeout=60 * 60,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"cannot list archive ({result.returncode}): {result.stderr.strip()[:500]}"
        )
    for name in result.stdout.splitlines():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise RuntimeError(f"archive contains an unsafe member: {name}")


def restore(server: dict, archive: str) -> dict:
    """Restore an archive into the server's home.

    Refuses while the unit is active, takes a safety archive first, and never
    accepts an archive outside the server's backup directory.
    """
    directory = archive_dir(server).resolve()
    candidate = Path(archive)
    if not candidate.is_absolute():
        candidate = directory / candidate
    candidate = candidate.resolve()
    if directory not in candidate.parents and candidate.parent != directory:
        raise RuntimeError(f"archive is outside {directory}: {candidate}")
    if not candidate.is_file() or not ARCHIVE_RE.match(candidate.name):
        raise RuntimeError(f"not a backup archive: {candidate}")
    if unit_active(server["unit"]):
        raise RuntimeError(
            f"{server['unit']} is active; stop it before restoring "
            f"(systemctl stop {server['unit']})"
        )

    # Validate before taking the safety archive: a bad archive must not have
    # side effects, and the listing pass is cheap.
    validate_archive_members(candidate)
    safety = create_backup(server, reason="pre-restore")
    home = Path(server["home"])
    result = subprocess.run(
        [
            "tar",
            "--zstd",
            "--no-same-owner",
            "--no-same-permissions",
            "-xf",
            str(candidate),
            "-C",
            str(home),
        ],
        capture_output=True,
        text=True,
        timeout=60 * 60,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"restore failed ({result.returncode}): {result.stderr.strip()[:500]}"
        )
    return {
        "server": server["name"],
        "restored": candidate.name,
        "safety": safety["name"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="manage.json rendered by Nix")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="back up every server (or one)")
    run.add_argument("--server")

    listing = sub.add_parser("list", help="list archives for one server")
    listing.add_argument("--server", required=True)

    restore_cmd = sub.add_parser("restore", help="restore one archive")
    restore_cmd.add_argument("--server", required=True)
    restore_cmd.add_argument("--archive", required=True)

    args = parser.parse_args(argv)
    config = load_config(args.config)

    if args.command == "list":
        server = server_by_name(config, args.server)
        print(json.dumps(list_backups(server), indent=2))
        return 0

    if args.command == "restore":
        server = server_by_name(config, args.server)
        try:
            result = restore(server, args.archive)
        except (RuntimeError, OSError) as exc:
            print(f"restore failed: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(result, indent=2))
        return 0

    servers = (
        [server_by_name(config, args.server)]
        if args.server
        else config.get("servers", [])
    )
    failures = 0
    for server in servers:
        try:
            result = create_backup(server)
            print(
                f"backup: {result['server']} -> {result['name']} "
                f"({result['size']} bytes)"
                + (f" [save: {result['saveError']}]" if result.get("saveError") else "")
            )
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
            failures += 1
            print(f"backup: {server.get('name')} FAILED: {exc}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
