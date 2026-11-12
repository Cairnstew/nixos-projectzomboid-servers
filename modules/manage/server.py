#!/usr/bin/env python3
"""pz-manage: a small, read-mostly dashboard for Project Zomboid servers.

This is the control-panel feature set that survives the declarative contract of
this module:

* **Read** — status, players, logs, the effective Nix-rendered config.
* **Transient** — save, broadcast, kick/ban, whitelist changes, systemd
  start/stop/restart. None of these writes a file the Nix render owns.
* **Backups** — create, list, download and delete archives (restore is a CLI,
  see ``backups.py``).

It deliberately does NOT expose the things a NixOS module must own: editing the
``.ini``, ``_SandboxVars.lua``, ``Mods=``/``WorkshopItems=``, installing a
server, or spawning the game process. The prep script overwrites those on every
start, so a UI that wrote them would be lying.

Endpoints (all JSON):

    GET  /api/status                      every server, with player counts
    GET  /api/servers                     metadata + read-only config
    GET  /api/players?server=<name>       parsed RCON `players`
    GET  /api/logs?server=<name>&lines=N  tail of the newest server log
    GET  /api/config?server=<name>        effective settings/sandbox/mods
    POST /api/action                      {server, verb, arg?}
    GET  /api/backups?server=<name>       archive list
    POST /api/backups                     {server} — create one
    DELETE /api/backups?server=&name=     delete one
    GET  /api/backups/download?server=&name=
    GET  /api/health

Legacy shapes are kept so the existing proxy dashboard card keeps working:

    GET  /status                          same as /api/status
    POST /<server>/(start|stop|restart)   same as an action

The server binds loopback by default and is meant to sit behind the host's
reverse proxy, which supplies authentication. It has no user database, no JWT
and no RBAC — those are a property of the network, not of this service.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import shutil
import subprocess
import time
import traceback
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import backups
from idle_stop import parse_duration
from rcon import RconClient, RconError, parse_players

CONFIG_PATH = os.environ.get("PZ_MANAGE_CONFIG", "")
STATIC_DIR = Path(
    os.environ.get("PZ_MANAGE_STATIC", str(Path(__file__).parent / "static"))
).resolve()

MAX_BODY_BYTES = 64 * 1024
MAX_LOG_LINES = 2000
# Usernames are passed to RCON inside double quotes. Refuse anything that could
# break out of that quoting or inject a second command.
USERNAME_RE = re.compile(r'^[^\x00-\x1f"\\]{1,64}$')
BROADCAST_RE = re.compile(r'^[^\x00-\x1f"\\]{1,200}$')
ARCHIVE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+-\d{8}-\d{6}(-\d+)?\.tar\.zst$")

SYSTEM_ACTIONS = {"start", "stop", "restart"}
RCON_ACTIONS = {
    "save",
    "broadcast",
    "kick",
    "ban",
    "unban",
    "whitelist-add",
    "whitelist-remove",
    "reload-options",
}
ALL_ACTIONS = SYSTEM_ACTIONS | RCON_ACTIONS

CONFIG: dict = {}
SERVERS: dict[str, dict] = {}


# ── configuration ───────────────────────────────────────────────────────────


def load_config() -> None:
    global CONFIG, SERVERS
    if not CONFIG_PATH:
        raise SystemExit("PZ_MANAGE_CONFIG is not set")
    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
        CONFIG = json.load(fh)
    SERVERS = {server["name"]: server for server in CONFIG.get("servers", [])}


def server_or_400(name: str | None) -> dict:
    if not name:
        raise ValueError("missing ?server=<name>")
    server = SERVERS.get(name)
    if server is None:
        raise ValueError(f"unknown server: {name}")
    return server


# ── systemd ─────────────────────────────────────────────────────────────────


def systemctl(*args: str, timeout: float = 15) -> tuple[int, str]:
    try:
        result = subprocess.run(
            ["systemctl", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode, (result.stdout or result.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, str(exc)


def show(unit: str, prop: str) -> str:
    code, out = systemctl("show", unit, "-p", prop, "--value")
    return out if code == 0 else ""


def uptime_seconds(unit: str) -> int | None:
    raw = show(unit, "ActiveEnterTimestampMonotonic")
    if not raw or raw == "0":
        return None
    try:
        entered = int(raw) / 1_000_000
    except ValueError:
        return None
    try:
        with open("/proc/uptime", "r", encoding="ascii") as fh:
            boot = time.time() - float(fh.read().split()[0])
    except (OSError, ValueError):
        return None
    return max(0, int(time.time() - (boot + entered)))


def timer_next_elapse(unit: str) -> int | None:
    """Epoch seconds of a timer's next elapse, or None.

    ``systemctl show -p NextElapseUSecRealtime`` returns a *formatted local
    date* in systemd 262 despite the property name, which is both locale- and
    timezone-dependent. ``systemctl list-timers --output=json`` gives the same
    value as microseconds since the epoch, so use that and avoid parsing a
    human date.
    """
    if not unit:
        return None
    code, out = systemctl("list-timers", "--output=json", "--no-pager", unit, timeout=5)
    if code != 0 or not out:
        return None
    try:
        entries = json.loads(out)
    except json.JSONDecodeError:
        return None
    for entry in entries:
        if entry.get("unit") != unit:
            continue
        raw = entry.get("next")
        if not raw:
            return None
        try:
            return int(int(raw) // 1_000_000)
        except (TypeError, ValueError):
            return None
    return None


def idle_status(server: dict) -> dict:
    """Describe the idle-stop countdown for the dashboard.

    The state file is written by the root idle timer. It is deliberately
    world-readable (only a timestamp), because the dashboard runs as the web
    user and cannot read a root-only file. A missing or unreadable file simply
    means "not currently counting down".
    """
    idle = server.get("idleStop") or {}
    result = {
        "enabled": bool(idle.get("enable")),
        "timeout": idle.get("timeout"),
        "timeoutSeconds": None,
        "emptySince": None,
        "stopAt": None,
    }
    if not result["enabled"]:
        return result
    try:
        timeout = parse_duration(str(idle.get("timeout") or "30m"))
    except ValueError:
        timeout = 0
    result["timeoutSeconds"] = timeout

    state_file = server.get("idleStateFile")
    if not state_file:
        return result
    try:
        since = int(float(Path(state_file).read_text(encoding="ascii").strip()))
    except (OSError, ValueError):
        return result
    result["emptySince"] = since
    if timeout:
        result["stopAt"] = since + timeout
    return result


# ── RCON ────────────────────────────────────────────────────────────────────


def rcon_client(server: dict, timeout: float = 4) -> RconClient:
    port = int(server.get("rconPort") or 0)
    if port == 0:
        raise RconError("RCON is disabled for this server (rconPort = 0)")
    password_file = server.get("rconPasswordFile")
    if not password_file:
        raise RconError(
            "RCON has no password: set secretFiles.RCONPassword for this server"
        )
    try:
        password = Path(password_file).read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise RconError(f"cannot read the RCON password file: {exc}") from exc
    if not password:
        raise RconError("the RCON password file is empty")
    client = RconClient(
        server.get("rconHost", "127.0.0.1"), port, password, timeout=timeout
    )
    client.connect()
    return client


def server_players(server: dict) -> dict:
    active = unit_active(server["unit"])
    result = {
        "server": server["name"],
        "online": active,
        "rcon": False,
        "players": [],
        "count": 0,
        "ambiguous": False,
    }
    if not active:
        return result
    try:
        with rcon_client(server) as client:
            reply = client.command("players")
        parsed = parse_players(reply)
        result.update(
            {
                "rcon": True,
                "players": parsed["players"],
                "count": parsed["count"],
                "ambiguous": parsed["ambiguous"],
            }
        )
    except RconError as exc:
        result["error"] = str(exc)
    return result


def unit_active(unit: str) -> bool:
    code, _ = systemctl("is-active", "--quiet", unit)
    return code == 0


# ── read endpoints ──────────────────────────────────────────────────────────


def server_status(server: dict, with_players: bool = True) -> dict:
    unit = server["unit"]
    code, state = systemctl("is-active", unit)
    state = state or "unknown"
    active = code == 0 and state == "active"

    memory = None
    raw_memory = show(unit, "MemoryCurrent")
    if raw_memory and raw_memory not in ("[not set]", "0"):
        try:
            memory = int(raw_memory)
        except ValueError:
            memory = None

    status = {
        "name": server["name"],
        "serverName": server.get("serverName", server["name"]),
        "description": server.get("description", ""),
        "unit": unit,
        "active": active,
        "state": state,
        "uptime": uptime_seconds(unit) if active else None,
        "memory": memory,
        "defaultPort": server.get("defaultPort"),
        "udpPort": server.get("udpPort"),
        "rconPort": server.get("rconPort"),
        "console": server.get("consolePath", ""),
        "maxPlayers": server.get("maxPlayers"),
        # The server's IANA zone, so "next start" is rendered in the timezone
        # the schedule runs in rather than the browser's.
        "timeZone": CONFIG.get("timeZone"),
        # One server clock for every countdown on the page. The browser uses it
        # as an offset so a desktop whose clock is a minute off still counts
        # down correctly.
        "now": int(time.time()),
        "schedule": {
            "start": (server.get("schedule") or {}).get("start", []),
            "persistent": bool((server.get("schedule") or {}).get("persistent", False)),
            "nextStart": timer_next_elapse(server.get("startTimer", "")),
        },
        "idleStop": idle_status(server),
    }
    if with_players:
        players = server_players(server)
        status["players"] = players["count"] if players.get("rcon") else None
        status["playerNames"] = players.get("players", [])
        status["rcon"] = players.get("rcon", False)
        if players.get("error"):
            status["rconError"] = players["error"]
        if players.get("ambiguous"):
            status["playersAmbiguous"] = True
    return status


def tail_log(server: dict, lines: int) -> dict:
    directory = Path(server["logsDir"])
    result = {"server": server["name"], "file": None, "lines": []}
    if not directory.is_dir():
        return result
    preferred = directory / "server.txt"
    candidates = [preferred] if preferred.is_file() else []
    candidates += sorted(
        (p for p in directory.glob("*.txt") if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        return result
    path = candidates[0]
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            result["lines"] = [
                line.rstrip("\r\n") for line in deque(fh, maxlen=lines)
            ]
        result["file"] = path.name
    except OSError as exc:
        result["error"] = str(exc)
    return result


def config_view(server: dict) -> dict:
    return {
        "server": server["name"],
        "readOnly": True,
        "source": "Nix — services.project-zomboid-servers (lib/prepare.nix)",
        "note": (
            "These are the effective values rendered by Nix and re-applied on "
            "every start. Editing them in a web UI would be overwritten; change "
            "the module and rebuild instead."
        ),
        "description": server.get("description", ""),
        "modpack": server.get("modpack"),
        "map": server.get("map"),
        "defaultPort": server.get("defaultPort"),
        "udpPort": server.get("udpPort"),
        "rconPort": server.get("rconPort"),
        "maxPlayers": server.get("maxPlayers"),
        "public": server.get("public"),
        "settings": server.get("settings", {}),
        "sandbox": server.get("sandbox", {}),
        "mods": server.get("mods", []),
        "workshopItems": server.get("workshopItems", []),
    }


def server_metadata(server: dict) -> dict:
    return {
        "name": server["name"],
        "serverName": server.get("serverName", server["name"]),
        "description": server.get("description", ""),
        "unit": server["unit"],
        "console": server.get("consolePath", ""),
        "modpack": server.get("modpack"),
        "map": server.get("map"),
        "defaultPort": server.get("defaultPort"),
        "udpPort": server.get("udpPort"),
        "rconPort": server.get("rconPort"),
        "rcon": bool(server.get("rconPasswordFile")) and int(server.get("rconPort") or 0) > 0,
        "maxPlayers": server.get("maxPlayers"),
        "backupDirectory": server.get("backupDirectory"),
        "backupKeep": server.get("backupKeep"),
        "schedule": server.get("schedule"),
        "idleStop": server.get("idleStop"),
    }


# ── actions ─────────────────────────────────────────────────────────────────


def require_allowed(verb: str) -> None:
    allowed = CONFIG.get("allowActions", sorted(ALL_ACTIONS))
    if verb not in ALL_ACTIONS:
        raise ValueError(f"unknown action: {verb}")
    if verb not in allowed:
        raise PermissionError(f"action is disabled by configuration: {verb}")


def online_names(server: dict) -> list[str]:
    players = server_players(server)
    if not players.get("rcon"):
        raise RconError(players.get("error", "RCON is unavailable"))
    if players.get("ambiguous"):
        raise RconError(
            "the players reply is ambiguous (a username contains a newline); "
            "refusing per-player actions"
        )
    return players["players"]


def run_action(server: dict, verb: str, arg: str | None) -> dict:
    require_allowed(verb)
    unit = server["unit"]

    if verb in SYSTEM_ACTIONS:
        # --no-block: PZ's stop path waits for `save` + `quit` (up to 90s), and
        # a killed HTTP client should not cancel the job anyway. The UI polls
        # /api/status for the outcome.
        code, out = systemctl(verb, unit, "--no-block")
        return {"ok": code == 0, "verb": verb, "output": out}

    if verb == "save":
        with rcon_client(server) as client:
            return {"ok": True, "verb": verb, "output": client.command("save")}

    if verb == "broadcast":
        message = (arg or "").strip()
        if not message or not BROADCAST_RE.match(message):
            raise ValueError("broadcast needs 1-200 printable characters, no quotes")
        with rcon_client(server) as client:
            return {
                "ok": True,
                "verb": verb,
                "output": client.command(f'servermsg "{message}"'),
            }

    if verb in ("kick", "ban"):
        name = (arg or "").strip()
        if not name or not USERNAME_RE.match(name):
            raise ValueError("invalid username")
        names = online_names(server)
        if name not in names:
            raise ValueError(f"{name} is not online")
        command = "kickuser" if verb == "kick" else "banuser"
        with rcon_client(server) as client:
            return {
                "ok": True,
                "verb": verb,
                "output": client.command(f'{command} "{name}"'),
            }

    if verb == "reload-options":
        with rcon_client(server) as client:
            return {"ok": True, "verb": verb, "output": client.command("reloadoptions")}

    name = (arg or "").strip()
    if not name or not USERNAME_RE.match(name):
        raise ValueError("invalid username")
    commands = {
        "unban": "unbanuser",
        "whitelist-add": "addusertowhitelist",
        "whitelist-remove": "removeuserfromwhitelist",
    }
    with rcon_client(server) as client:
        return {
            "ok": True,
            "verb": verb,
            "output": client.command(f'{commands[verb]} "{name}"'),
        }


# ── HTTP ────────────────────────────────────────────────────────────────────


def same_origin_only(headers) -> bool:
    """False when a browser says this request came from another site.

    The dashboard is protected by a custom header on ``/api/*``, but the legacy
    ``POST /<server>/(start|stop|restart)`` route predates it. Proxy basic auth
    does NOT stop CSRF: the browser attaches those credentials to a cross-site
    form submission too. ``Sec-Fetch-Site`` is sent by modern browsers and cannot
    be set by page JavaScript, so it closes that route without requiring every
    legacy client to change. An absent header (curl, an old browser) is allowed;
    a present header must be same-origin or a direct navigation.
    """
    site = headers.get("Sec-Fetch-Site")
    return not site or site in ("same-origin", "none")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pz-manage/1"
    # BaseHTTPRequestHandler appends "Python/3.x" to the Server header. Keep the
    # version out of an unauthenticated response; it is no use to the operator.
    sys_version = ""

    # ── responses ───────────────────────────────────────────────────────────

    def _headers(self, code: int, content_type: str, length: int) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; "
            "base-uri 'none'; form-action 'self'",
        )
        self.end_headers()

    def _json(self, payload, code: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self._headers(code, "application/json; charset=utf-8", len(body))
        self.wfile.write(body)

    def _text(self, text: str, code: int = 200) -> None:
        body = text.encode("utf-8")
        self._headers(code, "text/plain; charset=utf-8", len(body))
        self.wfile.write(body)

    def _error(self, code: int, message: str) -> None:
        self._json({"error": message}, code)

    # ── helpers ─────────────────────────────────────────────────────────────

    def _query(self) -> dict[str, str]:
        parsed = urlparse(self.path)
        return {k: v[0] for k, v in parse_qs(parsed.query).items()}

    def _path(self) -> str:
        return urlparse(self.path).path

    def _body_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return {}
        if length > MAX_BODY_BYTES:
            raise ValueError("request body too large")
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"invalid JSON body: {exc}") from exc
        if not isinstance(data, dict):
            raise ValueError("JSON body must be an object")
        return data

    def _require_csrf_header(self) -> None:
        # A cross-origin HTML form cannot set this header without a CORS
        # preflight, and this service sends no CORS headers. The dashboard's
        # own JavaScript sets it.
        if self.headers.get("X-PZ-Manage") != "1":
            raise PermissionError("missing X-PZ-Manage: 1 header")

    def _require_same_origin(self) -> None:
        # Covers the legacy route, which cannot use the custom header. Modern
        # browsers send Sec-Fetch-Site; a client that does not is allowed
        # through (see `same_origin_only`).
        if not same_origin_only(self.headers):
            raise PermissionError("cross-site request refused")

    def _static(self, name: str) -> None:
        candidate = (STATIC_DIR / name).resolve()
        if STATIC_DIR not in candidate.parents and candidate != STATIC_DIR:
            self._error(404, "not found")
            return
        if not candidate.is_file():
            self._error(404, "not found")
            return
        content_type, _ = mimetypes.guess_type(candidate.name)
        body = candidate.read_bytes()
        self._headers(200, content_type or "application/octet-stream", len(body))
        self.wfile.write(body)

    # ── GET ─────────────────────────────────────────────────────────────────

    def do_GET(self) -> None:
        path = self._path()
        query = self._query()
        try:
            if path in ("/", "/index.html"):
                return self._static("index.html")
            if path.startswith("/assets/"):
                return self._static(path[len("/assets/") :])

            if path == "/api/health":
                return self._json({"ok": True, "servers": len(SERVERS)})

            if path in ("/api/status", "/status"):
                return self._json(
                    [server_status(server) for server in SERVERS.values()]
                )

            if path == "/api/servers":
                return self._json(
                    {
                        "title": CONFIG.get("title", "Project Zomboid"),
                        "refreshSeconds": CONFIG.get("refreshSeconds", 5),
                        "allowActions": CONFIG.get(
                            "allowActions", sorted(ALL_ACTIONS)
                        ),
                        "servers": [
                            server_metadata(server) for server in SERVERS.values()
                        ],
                    }
                )

            if path == "/api/players":
                return self._json(server_players(server_or_400(query.get("server"))))

            if path == "/api/logs":
                lines = int(query.get("lines", "200"))
                lines = max(1, min(lines, MAX_LOG_LINES))
                return self._json(tail_log(server_or_400(query.get("server")), lines))

            if path == "/api/config":
                return self._json(config_view(server_or_400(query.get("server"))))

            if path == "/api/backups":
                server = server_or_400(query.get("server"))
                return self._json(backups.list_backups(server))

            if path == "/api/backups/download":
                server = server_or_400(query.get("server"))
                name = query.get("name", "")
                if not ARCHIVE_NAME_RE.match(name):
                    return self._error(400, "invalid archive name")
                archive = Path(server["backupDirectory"]) / name
                if not archive.is_file():
                    return self._error(404, "archive not found")
                size = archive.stat().st_size
                self.send_response(200)
                self.send_header("Content-Type", "application/zstd")
                self.send_header("Content-Length", str(size))
                self.send_header(
                    "Content-Disposition", f'attachment; filename="{archive.name}"'
                )
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                # Stream rather than read into memory: a world archive can be
                # several GB, and the dashboard must not become the OOM victim.
                with archive.open("rb") as fh:
                    shutil.copyfileobj(fh, self.wfile, length=1024 * 1024)
                return None

            return self._error(404, "not found")
        except (ValueError, PermissionError) as exc:
            return self._error(400 if isinstance(exc, ValueError) else 403, str(exc))
        except Exception:  # noqa: BLE001 - a dashboard must not die on one request
            traceback.print_exc()
            return self._error(500, "internal error")

    # ── POST / DELETE ───────────────────────────────────────────────────────

    def do_POST(self) -> None:
        path = self._path()
        try:
            self._require_same_origin()
            # The legacy `POST /<server>/(start|stop|restart)` route is kept
            # for the existing proxy dashboard card, which is same-origin and
            # already behind the proxy's authentication. The JSON API requires
            # the CSRF header; the legacy route predates it and only exposes
            # three fixed systemd verbs.
            if path.startswith("/api/"):
                self._require_csrf_header()

            if path == "/api/action":
                body = self._body_json()
                server = server_or_400(body.get("server"))
                return self._json(
                    run_action(server, str(body.get("verb", "")), body.get("arg"))
                )

            if path == "/api/backups":
                body = self._body_json()
                server = server_or_400(body.get("server"))
                return self._json(backups.create_backup(server))

            # Legacy: POST /<server>/(start|stop|restart)
            parts = [unquote(p) for p in path.strip("/").split("/") if p]
            if len(parts) == 2 and parts[0] in SERVERS and parts[1] in SYSTEM_ACTIONS:
                return self._json(run_action(SERVERS[parts[0]], parts[1], None))

            return self._error(404, "not found")
        except (ValueError, PermissionError) as exc:
            return self._error(400 if isinstance(exc, ValueError) else 403, str(exc))
        except (RuntimeError, OSError) as exc:
            return self._error(500, str(exc))
        except Exception:  # noqa: BLE001
            traceback.print_exc()
            return self._error(500, "internal error")

    def do_DELETE(self) -> None:
        try:
            self._require_same_origin()
            self._require_csrf_header()
            if self._path() != "/api/backups":
                return self._error(404, "not found")
            query = self._query()
            server = server_or_400(query.get("server"))
            name = query.get("name", "")
            if not ARCHIVE_NAME_RE.match(name):
                return self._error(400, "invalid archive name")
            archive = Path(server["backupDirectory"]) / name
            if not archive.is_file():
                return self._error(404, "archive not found")
            archive.unlink()
            return self._json({"ok": True, "deleted": name})
        except (ValueError, PermissionError) as exc:
            return self._error(400 if isinstance(exc, ValueError) else 403, str(exc))
        except OSError as exc:
            return self._error(500, str(exc))

    def log_message(self, _format: str, *_args) -> None:
        # The UI polls every few seconds; journaling every request would drown
        # the useful lines. Errors are printed by the handlers above.
        pass


def main() -> None:
    load_config()
    bind = CONFIG.get("bind", "127.0.0.1")
    port = int(CONFIG.get("port", 27080))
    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    print(f"pz-manage listening on {bind}:{port} ({len(SERVERS)} server(s))", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
