# Plan: in-depth startup/shutdown progression in `pz-manage`

> Status: **proposal only, nothing implemented**. Target: `modules/manage/`
> (Python, stdlib only), `modules/manage/static/` (no build step), the server
> units in `modules/services/server.nix`, and `lib/prepare.nix`.
>
> Today the dashboard answers "is it up?" with one `systemctl is-active`
> (`modules/manage/server.py:279-283`) and a `state` badge
> (`modules/manage/static/app.js:214-278`). It cannot answer "is it *starting*,
> which step is it on, how long has that taken, and will the stop kill it?" —
> the question an operator actually has during the 30 s–5 min a PZ server spends
> loading a large modpack, or the 15–90 s a stop takes.

## 1. What "progression" means here

One panel, one ordered stage list per direction, live elapsed times, an explicit
current step, and no invented percentage:

```
Lifecycle                                    ● STARTING · prep
─────────────────────────────────────────────────────────────────────
✓ start requested                                   12:00:03
✓ install / update (shared steamcmd unit)           12:00:04   1m 12s
   downloading 438 Workshop item(s) as seanc
● prep: map, .ini, sandbox, mod links               12:01:16    00:08
· spawn launcher (steam-run)                         —
· console / RCON listening                           —
· world loaded (RCON answers)                        —
─────────────────────────────────────────────────────────────────────
start operation 1m 20s
```

```
Lifecycle                                    ● STOPPING · quit sent
─────────────────────────────────────────────────────────────────────
✓ stop requested                                    12:31:02
✓ save sent (waits 15 s for the write)              12:31:02
● quit sent, waiting for the JVM to exit            12:31:17
· stopped                                            —
─────────────────────────────────────────────────────────────────────
stop operation 15s · SIGKILL to the cgroup in 75s
```

Three properties matter more than the pixels:

1. **Never blank, never a lie.** An unknown systemd `SubState` maps to a generic
   phase with the raw value shown, not to "unknown".
2. **The long poles are named.** With `updateOnStart = true` (the default) every
   start can sit behind `project-zomboid-install.service`; today that looks like
   a dead page.
3. **The escalation is visible.** A stop that has passed ~15 s is normal (the
   save window); one that is approaching `TimeoutStopSec = 90s`
   (`modules/services/server.nix:255-258`) is one the operator should expect to
   end in SIGKILL.

## 2. Data sources

| Source | Gives | Privilege | Cost |
| --- | --- | --- | --- |
| `systemctl show <unit> -p …` (one batched call per unit) | `ActiveState`, `SubState`, `StateChangeTimestamp`, `InactiveExit/ActiveEnter/ActiveExit/InactiveEnter` timestamps, `ExecMainStart/ExitTimestamp`, `Result`, `ExecMainStatus`, `NRestarts`, `InvocationID`, `Job`, `TimeoutStopUSec`, `RestartUSec` | none (same as today) | ~5 ms, replaces the current 3–4 separate `show` calls |
| `systemctl show project-zomboid-install` | why a start is queued (the shared install/update unit) | none | one call, only while a start is pending |
| TCP connect to `rconHost:rconPort` | "RCON listener is accepting connections" (world is up enough to answer) | none | refused connect costs nothing |
| existing RCON `players` round-trip | "authenticated and answering" = ready | none | already done per refresh |
| progress file written by the prep/stop scripts (§6) | which *sub-step* prep is on, and save/quit milestones | none | one tmpfiles dir, a few `printf`s |
| `journalctl -u <unit>` (optional, §7) | last prep lines on failure, the install unit's steamcmd lines, transitions missed while no browser was open | `systemd-journal` group — **opt-in** | one subprocess per request when enabled |

Every source is read-only; nothing here writes a file Nix owns.

## 3. Phase model

Pure function in a new `modules/manage/lifecycle.py`:
`derive(props, job, install, probe, progress, now) -> dict`. Unit-tested in
`checks/default.nix` (see §9); `server.py` only gathers inputs.

| `ActiveState` (`SubState`) | phase key | label |
| --- | --- | --- |
| `inactive`/`dead`, `Job` set | `queued` | "queued behind install/update" |
| `activating (start-pre)` | `prep` | "preparing config and mod links" (+ sub-step from the progress file) |
| `activating (start)` | `spawn` | "spawning the launcher (steam-run)" |
| `active (running)`, RCON not up | `loading` | "loading world and mods" |
| `active (running)`, RCON answers | `running` | "running" |
| `activating (auto-restart)` | `retrying` | "crashed — systemd retries in Ns (k/N in window)" |
| `deactivating (stop)`, progress says `save-sent` | `saving` | "saving the world (15 s window)" |
| `deactivating (stop)` | `stopping` | "sending save, then quit" |
| `deactivating (stop-sigterm|stop-sigkill|stop-post)` | `exiting` | "waiting for the JVM to exit" |
| `failed` | `failed` | mapped from `Result` (§5) |
| anything else (incl. `Type=forking` tmux before the JVM loads) | `active`/`unknown` | raw `ActiveState (SubState)` |

Derived values: `direction` (`start` / `stop` / `steady`), `since` (epoch the
current sub-state began), `operationSince` (start: `InactiveExitTimestamp`;
stop: `ActiveExitTimestamp`), `elapsed`, `escalation.killIn` =
`TimeoutStopUSec − (now − stopStarted)`, `restartIn` = `RestartUSec − elapsed`.

Timestamps: request `--timestamp=unix` so the value is `@<epoch>` and no
locale-dependent date is parsed — the same trap `timer_next_elapse` documents at
`modules/manage/server.py:149-157`. It works on the systemd in nixpkgs unstable
(262 here, verified: `systemctl show … --timestamp=unix` prints
`ActiveEnterTimestamp=@1794130522`), but probe the capability once at start and
fall back to `*TimestampMonotonic` if it is missing; never parse a human date.

`InvocationID` is the generation key for the per-server probe state: it changes
on every unit start, so "RCON first answered at" is reset exactly when the
previous run ended.

## 4. Stages

Start: `requested` → `dependencies` (install/update, "skipped" when it was
already up to date) → `prep` → `spawn` → `console` → `world`.

Stop: `requested` → `save` → `quit` → `stop-post`/`stop` → `stopped`.

Each stage is `done | active | skipped | failed | pending` plus
`startedAt`/`endedAt`. A stage with no observable timestamp stays `pending` with
`—`; it is never filled in with an estimate.

## 5. Failure mapping (`Result`)

| `Result` | shown as |
| --- | --- |
| `exit-code` / `signal` / `core-dump` | "start/stop failed (status N)" + which stage was last active |
| `timeout` | "stopped by systemd timeout" + hint: the 90 s stop window, and that the kill escalates to the whole cgroup because `KillMode=mixed` |
| `oom-kill` | "killed by the OOM killer" + hint: `hardware.memoryMax` |
| `start-limit-hit` | "crash loop: N starts in `startLimitIntervalSec`" + `systemctl reset-failed` |
| `resources` | "cgroup resource limit reached" |

When the journal is available (§7) the block also shows the last 20 lines of the
failed invocation; otherwise it shows the exact `journalctl -u <unit>` command.

## 6. Instrumentation: the progress file (phase 2)

`systemd` can say `start-pre` for a 20 s prep and nothing finer; the stop path
sleeps 15 s inside `ExecStop` (`modules/services/server.nix:175-193`) with no
observable milestone. Both scripts already run as `cfg.user`, so they can write
a tiny append-only file under the existing run directory.

- One shared shell helper, written once in `lib/prepare.nix` as a store path
  sourced by the prep *and* the two stop scripts (AGENTS.md: one
  implementation):
  ```sh
  pz_phase() { [ -n "${PZ_PROGRESS_FILE-}" ] || return 0
               printf '%s %s\n' "$(date +%s)" "$1" >> "$PZ_PROGRESS_FILE"; }
  ```
- `modules/services/server.nix`: add `PZ_PROGRESS_FILE=${cfg.runDir}/progress/${name}`
  to the unit `Environment`, and a tmpfiles rule
  `d '${cfg.runDir}/progress' 0755 ${cfg.user} ${cfg.group} - -` next to the
  existing runDir rule at `:503-506`. The prep script truncates the file first;
  no new option.
- Call sites: `maps`, `ini`, `sandbox`, `workshop-links`, `local-mods`, `prune`,
  `prepared` in the prep script (`lib/prepare.nix:156-349`); `save-sent`,
  `quit-sent` in both stop backends (`:132-154` tmux, `:175-193` fifo);
  `validating`, `workshop` in the install script (`lib/prepare.nix:~580-760`).
- `modules/manage.nix` passes `progressFile` per server in `manageConfig`
  (`:56-93`); `server.py` reads it with a size cap (4 KiB) and ignores
  unparsable lines. `runDir` is already read by the dashboard for the idle
  marker (`modules/manage.nix:85`), so permissions and `ProtectSystem=strict`
  are already proven.
- Reading the file is best-effort: absent → stages stay `pending`, everything
  else still works.

## 7. Optional journal access (phase 3)

- New option `manage.journal` (`mkEnableOption`, default false) documented in
  `docs/options.md`. When on, the manage unit gets
  `SupplementaryGroups = [ "systemd-journal" ]`.
- **This is a real privilege increase and must be documented as such:** the
  journal has no per-unit ACLs, so group membership grants read access to every
  unit's log on the host. Default off; the UI degrades to "journal not enabled —
  `journalctl -u <unit>`".
- Endpoint `GET /api/journal?server=&lines=200` (allow-listed server, clamped
  lines), used by the failure block. Also enables journal-derived transition
  history for operations that happened while no browser was attached.

## 8. API (additive only)

`GET /api/status` keeps every existing key (the legacy proxy card reads
`/status`), and each server gains:

```json
"lifecycle": {
  "phase": "prep", "label": "preparing config and mod links",
  "detail": "mod links (438 items)",
  "direction": "start",
  "since": 1794550816, "operationSince": 1794550803, "now": 1794550919,
  "subState": "start-pre", "activeState": "activating",
  "job": {"type": "start", "unit": "project-zomboid-install.service", "state": "running"},
  "stages": [{"key": "prep", "label": "…", "state": "active", "startedAt": 1794550816}],
  "probe": {"rconListeningAt": null, "rconReadyAt": null},
  "timeouts": {"stopSeconds": 90, "restartSeconds": 5},
  "escalation": {"killIn": null},
  "result": "success", "exitStatus": 0, "restarts": 0
},
"recent": [{"at": 1794550803, "from": "inactive", "to": "activating", "phase": "prep"}]
```

New `GET /api/lifecycle?server=<name>&limit=20`: the same `lifecycle` object plus
`recent`, without the RCON/players round-trip, for the 1 s poll during a
transition. Read-only, no body, no new verbs.

State lives in a `LifecycleTracker` in `server.py`: a lock, a per-server ring
buffer (last 20 transitions) and the probe timestamps. It is sampled by each
request **and** by one daemon thread every 5 s, so a start that happens while
nobody is looking still has its timeline; the ring buffer is in memory only and
resets when the service restarts (the journal is the durable record).

## 9. UI

`modules/manage/static/index.html` gains one `section.panel.span-2` ("Lifecycle")
above Status; `style.css` gains `.phase`, `.stages`, `.timeline`; `app.js` gains
`renderLifecycle()`.

- Phase header: badge with the existing state colours plus a pulse while
  `direction != steady`, the stage label, and a 1 s ticking "in this phase Ns".
- Stage list: `✓ ● ✗ ·` per stage, label, per-stage duration, and the
  `detail` line from the progress file under the active stage.
- Stop warning: while `direction == "stop"`, a countdown from
  `escalation.killIn`; amber below 30 s.
- Failure block: `Result` hint + journal tail when enabled.
- Server tabs get a small phase dot, so the tab row shows which server is
  starting or stopping without selecting it.
- Actions panel: disable the *opposite* verb while an operation is in flight
  (today only `active` matters, so "Start" is clickable while a stop is still
  running) and show "queued behind install/update" when `phase == queued`.
- Polling: replace the fixed `setInterval` with a `setTimeout` chain —
  1 s while `direction != steady`, `refreshSeconds` otherwise, unchanged
  visibility guard (`app.js:675-712, 755-757`).
- Status cards: add `SubState` and restarts; keep every existing card.

## 10. Files touched

| File | Change |
| --- | --- |
| `modules/manage/lifecycle.py` | new: phase/stage derivation, pure |
| `modules/manage/server.py` | batched `systemctl show`, job/install probe, tracker thread, `/api/lifecycle`, journal endpoint |
| `modules/manage/static/{index.html,app.js,style.css}` | the panel |
| `modules/services/server.nix` | `PZ_PROGRESS_FILE`, progress tmpfiles dir, `pz_phase` calls in the stop shims |
| `lib/prepare.nix` | shared `pz_phase` helper + call sites in prep and install |
| `modules/manage.nix` | `progressFile` in the config JSON; `SupplementaryGroups` when `manage.journal` |
| `modules/options/manage.nix` | `manage.journal` |
| `checks/default.nix` | lifecycle + progress-parser assertions in `pz-manage-check` |
| `docs/manage.md`, `docs/options.md`, `CHANGELOG.md` | documentation |

## 11. Tests (`checks/default.nix`, `pz-manage-check`)

Extend the existing offline check (`:665-910`), following the
`manage_server.systemctl = lambda …` monkeypatch precedent at `:824-830`:

- every `SubState` in §3, including `auto-restart`, `stop-sigterm`, and a
  `Type=forking` "active but RCON not listening" case;
- `Result` mapping for `exit-code`, `timeout`, `oom-kill`, `start-limit-hit`;
- escalation arithmetic from a fixed `TimeoutStopUSec` and `now`;
- a queued start (`Job` set, install unit `activating`) and an install-failed
  dependency (server `inactive`, install `failed`);
- progress-file parsing: valid lines, a malformed line, an oversized file, a
  missing file (all stages stay `pending`, no exception);
- legacy shape: `/status` still contains `name`, `active`, `state`, `uptime`,
  `players` for a fake server dict.

## 12. Phasing

| Phase | Scope | Effort |
| --- | --- | --- |
| **1** | `lifecycle.py`, systemd/install/probe inputs, tracker, `/api/lifecycle`, the panel, checks | ~1 day |
| **2** | `pz_phase` + progress file in prep/stop/install, sub-step detail in the UI | ~½ day |
| **3** | optional journal (`manage.journal`), failure tails, durable history | ~½ day |

Each phase is independently shippable; phase 1 already covers "what is it doing,
for how long, and will the stop kill it?".

## 13. Non-goals

- No writes to `viewpoint.ini`, `_SandboxVars.lua`, `Mods=`, `WorkshopItems=`,
  or any world file; the panel stays read-only.
- No invented progress bars or ETAs. Stages are facts; an unknown duration is
  `—`.
- No raw RCON terminal, no new mutating verbs, no auth/RBAC change.
- No `journalctl -f` streaming, no websocket — polling only.
- No change to the existing `/status` or legacy `POST /<server>/<verb>` shapes.

## 14. Open questions

1. **Journal (phase 3):** accept the `systemd-journal` group membership as an
   opt-in, or drop the journal entirely and rely on the progress file + a
   printed `journalctl` hint?
2. **Instrumentation (phase 2):** is a `${runDir}/progress/<name>` file
   acceptable, or should the prep/stop scripts stay untouched and the panel
   show only systemd-level phases?
3. **Panel placement:** above Status (proposal) or replacing the Status cards?
