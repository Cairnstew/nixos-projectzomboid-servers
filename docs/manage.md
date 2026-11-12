# Dashboard and backups (`manage` / `backup`)

This module ships the half of a control panel that a declarative configuration
can own honestly. It is not a replacement for the Nix module: the `.ini`,
`_SandboxVars.lua`, `Mods=`, `WorkshopItems=` and systemd lifecycle stay
declarative, and anything a web UI wrote to those files is reverted on the next
start.

The design and the feature-by-feature decision live in
[`plans/control-panel-parity.md`](plans/control-panel-parity.md).

## What it does

`pz-manage` is a stdlib-only Python service (no Node, no npm build, no runtime
network dependency) that exposes:

| Capability | Channel | Writes server state? |
| --- | --- | --- |
| Status, uptime, memory, player count | systemd + RCON | no |
| Scheduled start time and idle-shutdown countdown | systemd timers + the idle state file | no |
| Player list | RCON `players` | no |
| Log tail | `<dataDir>/<name>/Zomboid/Logs` | no |
| Effective config viewer | the Nix-rendered values | no |
| Save, broadcast | RCON | transient |
| Kick, ban, unban, whitelist add/remove | RCON, fixed verbs | transient |
| Start, stop, restart | systemd (polkit) | process only |
| Backups: create, list, download, delete | `tar --zstd` | archive tree only |
| Restore | CLI, refuses while active | yes, by design |

It deliberately does **not** edit `viewpoint.ini`, `_SandboxVars.lua`,
`Mods=`/`WorkshopItems=`, install a server, run a setup wizard, or expose a raw
RCON terminal. Those are either overwritten by the render or a much larger
attack surface than a dashboard is worth.

## Enable it

```nix
services.project-zomboid-servers = {
  enable = true;
  manage = {
    enable = true;
    # loopback only; proxy it
    port = 27080;
  };
  backup = {
    enable = true;
    directory = "/mnt/backup/project-zomboid";
    schedule = "*-*-* 04:30:00";
    keep = 7;
  };
};
```

`manage.enable` creates the web-console user if it does not exist and grants it
the same scoped polkit rule the ttyd consoles use
(`org.freedesktop.systemd1.manage-units` on `project-zomboid-*` only). It never
spawns the game process itself.

## RCON

Players, kicks, bans, broadcasts and `save` need RCON. Enable it per server and
give it a secret **path**, never a value in `settings`:

```nix
servers.viewpoint = {
  rconPort = 27017;
  secretFiles.RCONPassword = config.age.secrets.pz-rcon-password.path;
};
```

RCON is plaintext TCP. `openFirewall` only opens the two UDP game ports, and the
dashboard connects to `127.0.0.1:<rconPort>`. The module does **not** open the
RCON port: a plaintext listener reachable from the network is a much larger
exposure than the dashboard needs. If an external RCON client really must reach
it, set `openRconFirewall = true` and restrict the firewall rule to that
client's address — never open it to the whole internet.

If RCON is missing, the dashboard still shows status, logs, config and backups;
it reports the RCON error instead of pretending the player list is empty.

## Schedule and idle countdown

When a server uses `schedule.start` or `idleStop`, the dashboard shows both:

- the configured `OnCalendar` expressions and the **next** start, read from
  `systemctl list-timers --output=json` (microseconds since the epoch, so no
  locale- or timezone-dependent date parsing); and
- the idle-shutdown timeout, plus a live countdown when the server is currently
  empty.

The next-start time is rendered in the **server's** IANA timezone
(`config.time.timeZone`), not the browser's, because a schedule written for
22:00 on the server should not read as 04:00 on a laptop in another zone. The
raw `OnCalendar` expression is shown beside it, so the intended local time is
always visible.

The idle countdown comes from the same timestamp file the root idle timer writes
(`<runDir>/<name>.idle-since`). It is world-readable because it contains only an
epoch second; the dashboard never needs root to display it. If the file is
absent, the server is not counting down — either a player is online, the server
is stopped, or RCON is not ready yet.

Countdowns use the server's clock (`now` in `/api/status`) as an offset, so a
browser whose clock is a few seconds off still shows the correct remaining time.

## Proxy wiring

The module exposes plain data and does not depend on any particular
reverse-proxy module. In this repository's consumer, Caddy is wired like this:

```nix
my.services.proxy.upstreams = {
  pz-admin = {
    host = "127.0.0.1";
    port = 27080;
    path = "/pz-admin/";
    stripPrefix = true;
    displayName = "Project Zomboid dashboard";
  };
};
```

The service sees `/api/...` after the prefix is stripped, and the page's asset
URLs are relative, so it works under any prefix. Authentication belongs to the
proxy (basic auth, a tailnet, or a ZeroTier ACL) — the service has no user
database and no RBAC.

Loopback is **not** an authorization boundary: every local user can connect to
`127.0.0.1`, and the dashboard can start/stop units through the polkit rule.
Keep it behind a proxy on a multi-user host, or accept that local users share
control.

## API

All JSON. Mutating `/api/*` requests require `X-PZ-Manage: 1` (a CSRF guard a
cross-origin form cannot set without a preflight). Every mutating request —
including the legacy `/<server>/(start|stop|restart)` route used by the existing
dashboard card — is also rejected when the browser reports
`Sec-Fetch-Site: cross-site` or `same-site`. The legacy route still has no
custom-header requirement, so an old client that sends no `Sec-Fetch-Site`
continues to work; modern browsers cannot forge the header from page script.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/status` | every server: state, uptime, memory, players, schedule and idle countdown |
| `GET` | `/api/servers` | metadata, title, refresh interval, allowed actions |
| `GET` | `/api/players?server=` | parsed RCON `players` |
| `GET` | `/api/logs?server=&lines=` | tail of the newest log |
| `GET` | `/api/config?server=` | effective settings/sandbox/mods, read-only |
| `POST` | `/api/action` | `{server, verb, arg?}` |
| `GET` | `/api/backups?server=` | archive list |
| `POST` | `/api/backups` | `{server}` — create an archive |
| `DELETE` | `/api/backups?server=&name=` | delete an archive |
| `GET` | `/api/backups/download?server=&name=` | download an archive |
| `GET` | `/api/health` | liveness |

Legacy shapes used by the existing proxy dashboard card are kept:
`GET /status` and `POST /<server>/(start|stop|restart)`.

## Backups

The timer runs `backups.py run`, which archives, per server:

```
Zomboid/Saves   the world
Zomboid/db      <servername>.db (Build 42 whitelist/admins/players)
Zomboid/Server  merged .ini, SandboxVars, spawn files
Zomboid/Lua     server-side Lua
```

It excludes `.local/share/Steam` (the cached token is a credential), the shared
install, and Workshop symlinks. `Zomboid/Server` is included, and that directory
contains the merged `.ini` — including the RCON and join passwords. Archives are
created mode `0640` in a `0770` directory so the dashboard's group can read
them; treat any copy moved off the host as a credential and encrypt it.

If the server is running it asks RCON for a `save` first; a stopped server
produces the cleanest archive.

Restore is a CLI because it stops the server and replaces world files:

```bash
sudo systemctl stop project-zomboid-viewpoint
sudo project-zomboid-restore viewpoint viewpoint-20261112-043000.tar.zst
sudo systemctl start project-zomboid-viewpoint
```

The script refuses while the unit is active, validates archive members, takes a
safety archive first, and only accepts archives inside that server's backup
directory. It drops to the server user before extracting (the wrapper uses
`runuser`), so the restored files are owned correctly; `sudo` is still needed for
the stop/start around it. The archive is plain `tar --zstd`, so a manual restore
needs no tool from this repository.
