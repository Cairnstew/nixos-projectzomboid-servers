"""Stop a Project Zomboid server that has been empty for a configured time.

This is run from a systemd timer once a minute. It is deliberately
conservative:

* If the unit is not active, it clears the idle marker and exits.
* If RCON is unreachable (the server is still loading 400 Workshop items, or
  RCON crashed), it does nothing. Treating an unreachable RCON as "empty"
  would stop a server that is merely slow to boot.
* It re-queries the player count immediately before stopping, so a player who
  joins between the timer firing and the stop is not kicked.

State is one file per server under the module's run directory; it records when
the server was first seen with zero players. The file is removed as soon as a
player is seen, so the next empty period starts from zero.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

from rcon import RconClient, RconError, parse_players

DURATION_RE = re.compile(r"^([0-9]+)([smhd])$")
UNIT_SECONDS = {
    "s": 1,
    "m": 60,
    "h": 60 * 60,
    "d": 24 * 60 * 60,
}


def parse_duration(value: str) -> int:
    """Parse the small duration syntax the Nix option accepts."""
    match = DURATION_RE.fullmatch(value.strip())
    if match is None:
        raise ValueError(
            f"invalid duration {value!r}: use one number and one unit, e.g. 90s, 30m, 2h, 1d"
        )
    number, unit = match.groups()
    return int(number) * UNIT_SECONDS[unit]


def read_ini(path: Path) -> dict[str, str]:
    """Read the ``Key=value`` lines PZ writes, last value winning.

    PZ rewrites this file itself and the prep script merges into it, so it is a
    plain ini without sections or escapes. Splitting on the FIRST ``=`` keeps a
    password that itself contains ``=`` intact.
    """
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def unit_active(unit: str) -> bool:
    return (
        subprocess.run(
            ["systemctl", "is-active", "--quiet", unit],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        == 0
    )


def player_count(port: int, password: str) -> int:
    with RconClient("127.0.0.1", port, password, timeout=4.0) as client:
        return parse_players(client.command("players"))["count"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Stop a Project Zomboid server after it has been empty for a while."
    )
    parser.add_argument("--unit", required=True, help="systemd unit to stop")
    parser.add_argument(
        "--ini", required=True, type=Path, help="rendered <server>.ini with RCONPort/RCONPassword"
    )
    parser.add_argument(
        "--state", required=True, type=Path, help="file recording when the server became empty"
    )
    parser.add_argument(
        "--timeout", required=True, help="empty duration before stopping, e.g. 30m"
    )
    args = parser.parse_args(argv)

    try:
        timeout = parse_duration(args.timeout)
    except ValueError as exc:
        print(f"project-zomboid-idle-stop: {exc}", file=sys.stderr)
        return 2

    if not unit_active(args.unit):
        args.state.unlink(missing_ok=True)
        return 0

    try:
        ini = read_ini(args.ini)
    except OSError as exc:
        print(f"{args.unit}: cannot read {args.ini}: {exc}; not stopping", file=sys.stderr)
        return 0

    try:
        port = int(ini.get("RCONPort") or 0)
    except ValueError:
        port = 0
    password = ini.get("RCONPassword") or ""
    if port == 0 or not password:
        print(
            f"{args.unit}: RCON is not configured in {args.ini}; not stopping",
            file=sys.stderr,
        )
        return 0

    try:
        count = player_count(port, password)
    except (RconError, ValueError) as exc:
        # During boot RCON is not listening yet; a crash can also take it down.
        # Either way, "unknown" must not mean "empty".
        print(f"{args.unit}: RCON unavailable ({exc}); not stopping")
        return 0

    now = time.time()
    if count > 0:
        had_marker = args.state.exists()
        args.state.unlink(missing_ok=True)
        if had_marker:
            print(f"{args.unit}: {count} player(s) online; idle timer reset")
        return 0

    had_marker = args.state.exists()
    try:
        since = float(args.state.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        since = now
        args.state.parent.mkdir(parents=True, exist_ok=True)
        args.state.write_text(f"{now:.0f}\n", encoding="ascii")

    idle = max(0.0, now - since)
    if idle < timeout:
        if not had_marker:
            print(f"{args.unit}: empty; will stop after {timeout}s")
        return 0

    # Re-check immediately before acting: a player may have joined while this
    # timer was running. Kicking a just-joined player is the one outcome this
    # check must not produce.
    try:
        count = player_count(port, password)
    except (RconError, ValueError) as exc:
        print(f"{args.unit}: RCON unavailable before stop ({exc}); not stopping")
        return 0
    if count > 0:
        args.state.unlink(missing_ok=True)
        print(f"{args.unit}: {count} player(s) joined; not stopping")
        return 0

    print(f"{args.unit}: empty for {idle:.0f}s (>= {timeout}s); stopping")
    code = subprocess.run(["systemctl", "stop", args.unit], check=False).returncode
    if code == 0:
        args.state.unlink(missing_ok=True)
    else:
        # Keep the marker so the next minute retries the stop.
        print(
            f"{args.unit}: systemctl stop exited {code}; will retry",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
