# Plan: port Zomboid Control Panel functionality into this module

> Status: **implemented in part** (2026-11-12). Phases 0, 1, 2 and 4 are in
> `modules/manage.nix` and `modules/manage/`; Phase 3 (PanelBridge), 5 (map),
> 6 (telemetry/Discord) and 7 (mod update detection) remain proposals.
>
> Source examined: `github.com/fpsacha/zomboid-control-panel` @ `main`
> (shallow clone; MIT). Its `ARCHITECTURE.md`, `server/routes/*`,
> `server/services/*`, `client/src/pages/*`, and
> `pz-mod/PanelBridge/media/lua/server/PanelBridge.lua` (v1.7.79).
>
> Target: this repo (`nixos-projectzomboid-servers`) plus the thin host wiring
> in `nixos-config`.

## 1. The invariant that shapes everything

Nix is the source of truth. The `.ini` base, `_SandboxVars.lua`, `Mods=`,
`WorkshopItems=`, `Map=`, spawn points and systemd lifecycle are rendered from
the module and re-applied on every start (`lib/prepare.nix` → `merge_ini.py`,
`renderIniLines`, `renderSandbox`). Anything a web UI writes to those files is
**overwritten by design** on the next rebuild or server start.

That is not a limitation to work around — it is the contract. The port therefore
splits panel features into three classes:

| Class | Meaning | Examples |
| --- | --- | --- |
| **Read** | Never writes server state | status, players, logs, telemetry, map, config viewer |
| **Transient** | Acts on the running process, writes nothing persistent | kick, ban, save, broadcast, weather, teleport, heal |
| **Authoritative** | Owns config/mod/lifecycle files | INI editor, mod manager, setup wizard, start/stop |

Only the first two get ported. The third stays in Nix, and any UI for it is
read-only or an "advisory diff" (see §6).

## 2. How the panel actually works

The clone confirms three independent channels; every panel feature uses one of
them.

| Channel | Mechanism | Panel files |
| --- | --- | --- |
| **RCON** | Source RCON over TCP; `players`, `kickuser`, `banuser`, `save`, `servermsg`, `quit`, weather/admin commands | `server/services/rcon.js`, `server/routes/rcon.js` |
| **PanelBridge** | MIT Lua mod; JSON file queue under `<cachedir>/Lua/panelbridge/<server>/` (`status.json.txt`, `inbox/cmd-*.json`, outbox results). Protocol `queue-v1`, additive-only | `pz-mod/PanelBridge/…`, `server/services/panelBridge*` |
| **Filesystem** | Install dir + Zomboid data dir, local or SFTP | `server/services/fileManager*`, `backup*`, `chunk*` |
| **Tiles** | Proxy + disk cache of `https://tiles.pzmap.org/<build>/…` | `server/routes/mapProxy.js` |

The panel's lifecycle ownership is optional: in "Add Existing Server → Remote"
mode it explicitly does not start/stop the server (`docs/install/hosted.md`).
That is the only mode that fits here.

## 3. Feature inventory and decision

`port` = build into this module; `adapt` = same capability, Nix-shaped;
`skip` = deliberately not ported.

| Panel feature | Channel | Fit | Decision | Phase |
| --- | --- | --- | --- | --- |
| Server status / uptime / memory | process + RCON | ✅ | port (extends the existing `api.py` shape) | 0 |
| Console / log tail | log files + RCON | ✅ | port | 0 |
| Player list, online count | RCON `players` | ✅ | port | 0 |
| Kick / ban / unban / whitelist | RCON | ✅ | port, allow-listed verbs | 1 |
| Save / broadcast / restart | RCON + systemd | ✅ | port (systemd restart stays polkit-gated) | 1 |
| RCON terminal | RCON | ⚠️ | port with an explicit allow-list, not raw input | 1 |
| Config viewer (effective values) | Nix render | ✅ | adapt: render resolved settings to JSON | 2 |
| INI / SandboxVars editor | files | ❌ | **skip** — overwritten by the render | — |
| Mod manager writes (`Mods=`/`WorkshopItems=`) | files | ❌ | **skip** — same reason | — |
| Mod update detection (Steam API) | network | ✅ | adapt: check the catalogue's Workshop ids against the Steam API | 7 |
| Start/stop/restart ownership | process | ❌ | **skip** — systemd owns it (`project-zomboid-<name>.service`) | — |
| Setup wizard / steamcmd install | files | ❌ | **skip** — the module already does this declaratively | — |
| Backups (manual/scheduled/restore) | files | ✅ | adapt: systemd timer + `zstd` + retention + restore script | 4 |
| Chunk cleaner | save files | ⚠️ | later; needs a stopped server and a map UI | 5+ |
| World map + player positions | tiles + RCON/bridge | ⚠️ | port map, proxy/cache `tiles.pzmap.org`; positions via bridge | 5 |
| Teleport / heal / god mode / inventory / character sheet | PanelBridge | ✅ | port via bridge handlers | 3 |
| Weather / time / zombie control | PanelBridge | ✅ | port via bridge handlers | 3 |
| Safehouses / factions / vehicles | PanelBridge | ✅ | port selectively | 3 |
| Leaderboard / character history | PanelBridge + store | ⚠️ | later; needs a state dir and sampling | 6 |
| Discord bot (chat relay, slash commands) | RCON + Discord API | ⚠️ | optional, separate service | 6 |
| Host/process telemetry | `/proc` + Prometheus | ✅ | adapt: the server host already runs node_exporter + Prometheus | 6 |
| Multi-user auth / RBAC / JWT | panel DB | ❌ | **skip** — use Caddy basic auth + tailnet/ZeroTier ACLs | — |
| File manager / SFTP / file editor | files | ❌ | **skip** — out of scope and a large attack surface | — |
| PanelBridge install/switch logic | files | ❌ | **skip** — the mod becomes a Nix `localMods` entry or a Workshop item | — |
| Panel self-update | files | ❌ | **skip** — no panel binary to update | — |

## 4. Target architecture

```
                    ┌────────────────────────────────────────────┐
  browser ──TLS──▶  │ Caddy (my.services.proxy)                  │
                    │  /pz/<name>/   → ttyd console (existing)   │
                    │  /pz-api/*     → pz-manage (new)           │
                    │  /pz-map/*     → tile proxy (new, optional)│
                    └───────────────┬────────────────────────────┘
                                    │
                    ┌───────────────▼────────────────────────────┐
                    │ pz-manage  (Python, no root)               │
                    │  • RCON client (Source RCON, TCP)          │
                    │  • bridge client (queue-v1 files)          │
                    │  • read-only Nix config view               │
                    │  • action allow-list                       │
                    │  • systemctl via polkit (already granted)  │
                    └───────┬──────────────────┬─────────────────┘
                            │ RCON             │ file queue
                    ┌───────▼──────┐   ┌───────▼──────────────────┐
                    │ PZ server    │   │ Zomboid/Lua/panelbridge/ │
                    │ (systemd)    │   │   <server>/{inbox,…}     │
                    └──────────────┘   └──────────────────────────┘
```

### 4.1 `pz-manage` service (new upstream option)

Add to `modules/` (this repo), not the host wrapper:

- A new module `modules/manage.nix` behind
  `services.project-zomboid-servers.manage.enable` (default false).
- A Python service (stdlib only, like `lib/prepare.nix`'s helpers) run as the
  existing `web.user` (the one already granted polkit `manage-units` on
  `project-zomboid-*`).
- Listens on `manage.bind` (default `127.0.0.1`) and `manage.port`
  (default `27080`).
- Exposes plain JSON; the reverse-proxy mapping is host-local, exactly like
  `webConsoleUpstreams` today (a standalone flake cannot reference
  `my.services.proxy`).

Endpoints (initial):

| Method | Path | Channel | Notes |
| --- | --- | --- | --- |
| GET | `/status` | systemd + RCON | per enabled server: active, uptime, memory, player count |
| GET | `/players?server=<name>` | RCON | parsed `players` reply |
| GET | `/config?server=<name>` | Nix render | resolved settings/sandbox/mods, read-only |
| POST | `/action/<server>/<verb>` | RCON/systemd | allow-listed verbs only |
| GET | `/logs/<server>?lines=N` | files | tail of the newest `Logs/*DebugLog-server.txt` |
| GET | `/bridge/<server>/status` | files | `status.json.txt` heartbeat |

`action` verbs, each mapped to one fixed command (never interpolated raw input):

```
save  broadcast:<msg>  kick:<user>  ban:<user>  unban:<user>
whitelist-add:<user>  whitelist-remove:<user>
restart  stop  start
```

Names are validated against the RCON `players`/whitelist reply before use; the
RCON client must implement the Source RCON framing (little-endian length,
request id, type, null-terminated body) and a per-command timeout.

### 4.2 PanelBridge

Two delivery options; pick one per server:

1. **Workshop (recommended for MP):** add item `3809901056` (mod id `ZCPB`) to
   the pack's `workshopMods` in `modpacks/<pack>.nix`. Nix renders both
   `Mods=` and `WorkshopItems=` together; clients auto-download it; the Lua
   integrity check can stay on. This is the panel's own recommended route.
2. **`localMods` (server-only):** vendor the MIT `PanelBridge` folder with a
   pinned `fetchFromGitHub`, expose it as a `localMods` key. Requires
   `DoLuaChecksum=false` because clients do not have the file. Fine for a
   private server; worse for public ones.

The bridge directory is `<cachedir>/Lua/panelbridge/<server>/` — **not** a path
Nix owns, so the queue is safe. `pz-manage` writes `inbox/cmd-<n>.json` and reads
outbox results; it must honour the protocol rules in the panel's
`ARCHITECTURE.md` (additive handlers, command ids, 4 MB cap, `.txt` suffix for
Lua-written files).

Handlers to expose first (from `PanelBridge.lua`'s `handlers.*`):
`getServerInfo`, `getAllPlayerDetails`, `getPlayerDetails`, `getWeather`,
`generateWeather`, `getGameTime`, `setGameTime`, `getTimeSpeed`,
`setTimeSpeed`, `healPlayer`, `godmode`, `teleport`, `giveItem`,
`getCharacterSheet`, `getVehiclesDetailed`, `getSafehouses`.

### 4.3 Backups

Independent of the panel and worth doing first:

- `systemd.services.pz-backup` (oneshot) + `systemd.timers.pz-backup`
  (`OnCalendar`), run as `project-zomboid`.
- Stop or `save`+quiesce via RCON, `tar --zstd` the per-server
  `Zomboid/{Saves/Multiplayer/<name>,db/<name>.db,Server}` into
  `${dataDir}/backups/<name>/<timestamp>.tar.zst`, retention count.
- A restore script that refuses while the unit is active, takes a safety
  snapshot first, and prints the exact `systemctl stop/start` sequence.
- The panel's restore semantics (stop → safety backup → replace → start) are the
  model; the implementation is systemd, not panel code.

### 4.4 Map and tiles

- Optional `manage.mapProxy`: fetch `https://tiles.pzmap.org/<build>/base/…`,
  cache under `${dataDir}/map-tiles-cache` with a 1 GiB LRU bound (the panel's
  constants), set a descriptive `User-Agent`.
- Player positions from the bridge's `getAllPlayerDetails`, not from RCON.
- Build detection: the panel uses the `pzmap.org` build-list API; either pin the
  build in Nix or fetch it on a timer.

### 4.5 Telemetry and Discord

- Telemetry: the `server` host already runs node_exporter and Prometheus.
  Add a small exporter for `project-zomboid-<name>.service` memory/CPU from
  systemd cgroup counters, and player count from `pz-manage`. No new stack.
- Discord: a separate optional service (webhook for events first; bot later).
  It should read the same `pz-manage` API rather than talking to RCON twice.

## 5. Phased roadmap

Each phase is independently useful and shippable.

| Phase | Deliverable | Effort | Acceptance |
| --- | --- | --- | --- |
| **0** | RCON enablement + `pz-manage` status/players/logs | S (1–2 d) | `GET /status` shows active/uptime/memory/player count; `players` matches the game; logs tail works |
| **1** | Action allow-list (save/broadcast/kick/ban/whitelist/restart) | S–M (2–3 d) | each verb returns the RCON reply; invalid names rejected before sending; restart uses polkit, not sudo |
| **2** | Read-only config view from the Nix render | S (1 d) | `GET /config` returns the resolved settings/sandbox/mod ids and marks them read-only |
| **3** | PanelBridge delivery + bridge client + first handlers | M–L (5–8 d) | heartbeat visible; teleport/heal/weather/game-time round-trip; bridge failures are non-fatal |
| **4** | Backups + restore | S–M (2–3 d) | timer produces a restorable archive; restore refuses while active; retention works |
| **5** | Map + tile cache | M (3–5 d) | map loads from cache; positions update from the bridge; no auth bypass |
| **6** | Telemetry exporter + optional Discord webhook | S–M (2–3 d) | Prometheus scrapes PZ metrics; join/death events reach Discord |
| **7** | Mod update detection | M (2–4 d) | catalogue ids compared to Steam's published file details; report only, no writes |

Ordering rationale: Phase 0 unblocks the most value (players/console) with no new
dependencies; Phase 3 is the largest and needs the bridge decision; backups are
orthogonal and can be done in parallel.

## 6. Advisory writes (the one concession to editing)

If a UI for config/mods is wanted, make it **advisory**, never authoritative:

- `GET /config` returns the effective values and the Nix option path for each.
- A "propose change" action renders a unified diff against the module source
  (or a `git diff` of a worktree) and prints it for the operator to apply.
- No endpoint writes `viewpoint.ini`, `_SandboxVars.lua`, or the mod list.
- Optional: a `POST /config/check` that evaluates `nix eval` on a candidate
  value and reports type/assertion errors without committing.

This keeps the web UI useful for discovery while the rebuild remains the only
way to change state.

## 7. Non-goals (explicit)

- INI/SandboxVars/mod writes — reverted by `merge_ini.py`/`renderSandbox`.
- Start/stop/restart ownership — systemd + polkit only.
- Setup wizard / steamcmd install — the module does it.
- File manager / SFTP editor — large attack surface, no declarative value.
- JWT/RBAC/multi-user auth — Caddy basic auth + tailnet/ZeroTier ACLs.
- Panel self-update — nothing to update.
- Docker lifecycle control.

## 8. Risks and decisions

| Risk | Mitigation |
| --- | --- |
| RCON is plaintext | Bind loopback; if remote, restrict TCP to `tailscale0`/ZeroTier; never expose publicly |
| Arbitrary RCON input | Fixed verb table; validate player names against the RCON reply; no raw terminal in v1 |
| Bridge is a file queue | Reuse the MIT Lua mod; pin the rev; treat the queue dir as untrusted input (size/parse caps) |
| Lua checksum with `localMods` | Prefer the Workshop item; document `DoLuaChecksum=false` only for the local-mod route |
| Pack coupling to `ZCPB` | It is an optional pack entry; keep it out of the base catalogue unless wanted |
| Map tile host dependency | Cache + graceful fallback; no map until Phase 5 |
| Two control planes | `pz-manage` reads systemd state; it never spawns PZ |
| Python service grows | Stdlib-only, one file per concern; keep it behind `manage.enable = false` by default |

## 9. Open questions

1. **Bridge delivery**: Workshop item `ZCPB` in the pack (clients download it),
   or a pinned `localMods` entry (server-only, checksum off)?
2. **Where does `pz-manage` run?** On the PZ host (loopback RCON) or on the
   dashboard host (tailnet RCON)? The former is simpler and needs no firewall
   change.
3. **Map now or later?** It is the largest UI piece and the least
   operationally important.
4. **Discord**: webhook-only, or a bot with slash commands?
5. **Leaderboard/character history**: worth a state dir and sampling, or skip?

## 10. What to do first

Phase 0 + Phase 4 are the highest value per unit of risk:

- Enable RCON (`secretFiles.RCONPassword`, `rconPort` already 27017) and add
  `pz-manage` with `/status`, `/players`, `/logs`.
- Add the backup timer/restore script.

Both are small, testable, and do not touch the declarative config. Phase 3
(PanelBridge) is the real project and should be scoped separately once the
delivery question in §9 is answered.

## 11. Implementation status (2026-11-12)

| Phase | Status | Where |
| --- | --- | --- |
| 0 — RCON, status, players, logs | implemented | `modules/manage/server.py`, `modules/manage/rcon.py` |
| 1 — action allow-list | implemented | `manage.allowActions`, fixed verbs in `run_action` |
| 2 — read-only config view | implemented | `manageConfig` in `modules/manage.nix` |
| 3 — PanelBridge + handlers | **not implemented** | needs the delivery decision in §9.1 |
| 4 — backups + restore | implemented | `modules/manage/backups.py`, timer and `project-zomboid-restore` |
| 5 — map + tile cache | **not implemented** | needs the bridge for player positions |
| 6 — telemetry + Discord | **not implemented** | exporter and webhook are separate services |
| 7 — mod update detection | **not implemented** | Steam API comparison only |

The implemented slice deliberately stops at the declarative boundary: the UI
never writes `viewpoint.ini`, `_SandboxVars.lua`, `Mods=` or `WorkshopItems=`.
Restore is a CLI because it stops the server and replaces world files; the
dashboard only creates, lists, downloads and deletes archives.
