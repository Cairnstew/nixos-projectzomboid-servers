---
name: pz-deploy
description: Use when deploying an updated Project Zomboid modpack from this repo to the user's NixOS hosts (desktop, server) — commit and push the catalogue change, then on each host bump the `project-zomboid-servers` flake input, `nix run` to activate, and verify the dedicated server actually loaded the new pack.
---

# Deploy a Project Zomboid modpack update

Invoked by `/pz-deploy` (`.opencode/commands/pz-deploy.md`), or load this skill
directly when asked to deploy a modpack update.

End-to-end rollout for a change in `modpacks/` (or `mods/`). It touches three
places in this order:

1. **This repo** (`nixos-projectzomboid-servers`) — commit and push the pack.
2. **`~/nixos-config` on `desktop`** — bump the pz input, activate, verify.
3. **`~/nixos-config` on `server`** — bump the pz input, activate, verify the
   dedicated `viewpoint` server.

Both hosts consume this repo as a flake input:
`github:Cairnstew/nixos-projectzomboid-servers`. The input URL has no branch, so
it resolves `master`; **the push in Phase 1 is what makes the update visible.**

This workflow assumes a **catalogue/data** change. If the commit also changes
module behavior or options under `modules/`, update the consuming host configs
(and `docs/options.md`) first — bumping the input alone can fail evaluation or
silently leave a new option unset.

## Non-negotiable invariants

- **One host at a time.** Never run two `nix` builds/evals concurrently; these
  machines OOM. Finish `desktop`, then do `server`.
- **Check memory first.** On each host run `free -h`; if `available` is under
  5Gi, stop and wait. Do not start a rebuild on a loaded host.
- **Never force-push.** `git push --force` is always wrong here.
- **Never commit secrets, tokens, `.env`, or `result*` store links.** The repo
  gitignores them; do not override.
- **A dirty host checkout is not yours to clean.** If `~/nixos-config` has
  *tracked* modifications on a host, stop and ask. Untracked files (for example
  `.opencode/ensemble.json` on `server`) are harmless — leave them alone.
- **The server restart drops players.** If `project-zomboid-viewpoint.service`
  is active, activation restarts it. Ask before Phase 3.
- **This repo must be on `master`.** If it is not, stop; the input URL points
  there.

## Host map

| Host | Access | `~/nixos-config` branch | What runs there |
| --- | --- | --- | --- |
| `desktop` | local (`hostname -s` prints `desktop`) | `desktop` | No dedicated server. `clientHost.enable=false`, `home.installMods=false`, `updateOnStart=false`. Rebuild refreshes packages/config only. |
| `server` | `ssh seanc@server` (tailnet) | `server` | Dedicated `viewpoint` server, schedule-only (`autoStart=false`, midnight start, 30m idle stop), `updateOnStart=true`. |

Paths on `server`:

- rendered config:
  `/mnt/data/project-zomboid/viewpoint/Zomboid/Server/viewpoint.ini`
  (mode `0600`; read it with `sudo -n`)
- Workshop tree:
  `/mnt/data/project-zomboid/server/steamapps/workshop/content/108600`
  (world-readable; `seanc` is in group `project-zomboid`)

`nix run` in `~/nixos-config` activates the host's own configuration. It runs
`sudo /run/current-system/sw/bin/nixos-rebuild switch --flake <cleanFlake>#<host>`;
`sudo -n true` succeeds on both hosts, so no TTY is needed. Do **not** use
`nix run .#update` for this input — that updates only `nixpkgs`, `home-manager`
and `nixos-unified` (`primary-inputs`). Use `nix flake update
project-zomboid-servers`.

## Phase 0 — read-only preflight

From this repo:

```bash
git status --short
git branch --show-current          # must be master
git diff --stat
git log -1 --oneline
```

Confirm which pack changed:

```bash
git diff --name-only -- modpacks mods
git status --short -- modpacks mods
```

Check both hosts (read-only). Each host's `~/nixos-config` must be on its own
branch and have no tracked modifications:

```bash
free -h
sudo -n true
test "$(git -C ~/nixos-config branch --show-current)" = desktop
git -C ~/nixos-config status --porcelain --untracked-files=no

ssh -o BatchMode=yes -o ConnectTimeout=8 seanc@server '
  set -e
  free -h | head -2
  sudo -n true
  git -C ~/nixos-config status --porcelain --untracked-files=no
  test "$(git -C ~/nixos-config branch --show-current)" = server
  systemctl is-active project-zomboid-viewpoint.service || true
'
```

If the server is active, say so and get confirmation before Phase 3.

Record the current pin on each host (the "before" value):

```bash
python3 - <<'EOF'
import json
d = json.load(open("/home/seanc/nixos-config/flake.lock"))
print(d["nodes"]["project-zomboid-servers"]["locked"]["rev"])
EOF
ssh seanc@server 'python3 -c "import json;d=json.load(open(\"/home/seanc/nixos-config/flake.lock\"));print(d[\"nodes\"][\"project-zomboid-servers\"][\"locked\"][\"rev\"])"'
```

For the pack itself, `pz-modpack-status` (read-only tool) reports the declared
Workshop ids and their count; use it to confirm the pack and to update the
CHANGELOG's pack counts if needed.

## Phase 1 — commit and push the modpack

Review the diff first, then stage everything that belongs to this update. The
usual set is `modpacks/`, `mods/` and `CHANGELOG.md`, but stage a `scripts/`,
`lib/` or `checks/` change too if the update includes one.

```bash
git status --short
git add -A
git diff --cached --stat
```

Before committing, confirm the staged set contains only intended files — never
`node_modules`, `__pycache__`, `result*` or a store link. Those are gitignored,
so `git add -A` should not see them; if it does, stop and fix the ignore rule
rather than committing them.

**Stage before evaluating.** Flakes only see git-tracked files, so a new
`modpacks/*.nix` (or any new path) is invisible to `nix flake check` until it is
staged. Now run the evaluation gate:

```bash
nix flake check --no-build
```

If the update touched Nix code rather than only `modpacks/` data, also run the
deadnix gate CI uses:

```bash
nix run nixpkgs#deadnix -- --fail .
```

Do **not** run `nixfmt --check` on `modpacks/`: those files are deliberately not
rfc-style formatted and CI's formatting job only catches parse errors, so a
`--check` there would block a valid pack change. Also remember that
`nixfmt <file>` formats **in place** (it is not a check) — running it on a file
you did not mean to change silently rewrites it.

A pack edit is user-visible, so `CHANGELOG.md` needs an entry under
`## [Unreleased]` (Keep a Changelog headings such as `### Added` / `### Fixed`)
covering the mod, its Workshop id, and the new pack counts. Add it before
committing if it is missing.

Commit with an imperative subject (repo convention; no `[pz]` prefix), and put
the *why* in the body:

```bash
git commit -m "Add <mod> to the <pack> pack" -m "<why the change exists>"
```

If the user supplied a commit message in the invocation, use it verbatim.

Push:

```bash
git push origin master
rev=$(git rev-parse HEAD)
short=$(git rev-parse --short HEAD)
echo "$rev  $short"
```

Do not continue unless `git rev-parse origin/master` equals `$rev` — the push
must have landed before any host can resolve the new input. Keep `$rev` and
`$short` for the host lock-bump commits and verification.

## Phase 2 — desktop (local)

`desktop` is this machine when `hostname -s` prints `desktop`; otherwise run the
same commands over `ssh`.

```bash
cd ~/nixos-config
git status --porcelain --untracked-files=no     # must be empty
nix flake update project-zomboid-servers
git diff --stat flake.lock
python3 -c "import json;d=json.load(open('flake.lock'));print(d['nodes']['project-zomboid-servers']['locked']['rev'])"
```

The printed rev must equal `$rev`. If it does not, stop — the push did not
propagate, or the input URL points elsewhere. If `git diff --quiet flake.lock`
(no change), the host is already at `$rev`; skip the commit and say so.

Commit only the lock bump and push the host branch:

```bash
git add flake.lock
git commit -m "[flake] Bump project-zomboid-servers to $short"
git push origin desktop
```

If the push is rejected because the branch moved, `git pull --rebase origin
desktop` and retry. Never force.

Activate:

```bash
nix run
```

Verify the activation succeeded (`nix run` exits 0) and the new generation is
current:

```bash
readlink -f /run/current-system
```

**Desktop has no dedicated server and no re-rendered client config.** Its
`clientHost.enable` and `home.installMods` are both false, and the Mods-menu
preset (`~/Zomboid/Lua/pz_modlist_settings.cfg`) is gated on
`clientHost.enable`, so `nix run` does **not** refresh `~/Zomboid/mods` or mod
order. Do not claim it did. If the user explicitly wants the client's local mods
refreshed (a large Steam Workshop download; it does not prune and does not write
a load-order file), run it only after confirming:

```bash
nix run ~/Projects/nixos-projectzomboid-servers#pz-client-mods -- viewpoint
```

## Phase 3 — server (remote)

Run each step separately so a failure is attributable. First, memory:

```bash
ssh -o BatchMode=yes seanc@server 'free -h | head -2'
```

If `available` is under 5Gi, stop and wait.

Confirm the checkout is clean (tracked files only):

```bash
ssh -o BatchMode=yes seanc@server '
  set -e
  cd ~/nixos-config
  git status --porcelain --untracked-files=no
'
```

Must be empty. Bump the input:

```bash
ssh -o BatchMode=yes seanc@server '
  set -e
  cd ~/nixos-config
  nix flake update project-zomboid-servers
  python3 -c "import json;d=json.load(open(\"flake.lock\"));print(d[\"nodes\"][\"project-zomboid-servers\"][\"locked\"][\"rev\"])"
  git diff --stat flake.lock
'
```

The rev must equal `$rev`. If there is no diff, the server is already at `$rev`;
skip the commit. Otherwise commit on the `server` branch and push:

```bash
ssh -o BatchMode=yes seanc@server '
  set -e
  cd ~/nixos-config
  git add flake.lock
  git commit -m "[flake] Bump project-zomboid-servers to <short>"
  git push origin server
'
```

Use the literal `$short` value in place of `<short>`. If the push is rejected,
`git pull --rebase origin server`, retry, and never force.

Activate — **only after the player-drop confirmation from Phase 0**:

```bash
ssh -o BatchMode=yes seanc@server 'cd ~/nixos-config && nix run'
```

The server is schedule-only:

- **If it was active before activation**, `nix run` restarted it and
  `project-zomboid-install.service` ran first, so the new Workshop items are
  being downloaded now. Wait for the start and inspect the log (below).
- **If it was not active**, the rebuild does not start the **game** process.
  `nixos-rebuild switch` may still restart `project-zomboid-install.service`
  because its embedded `WorkshopItems=` list changed, so the download can happen
  during activation; the server process still only loads the new pack when it
  next starts. The midnight timer
  (`project-zomboid-viewpoint-start.timer`) starts it. To apply now, ask first,
  then start it explicitly:
  ```bash
  ssh -o BatchMode=yes seanc@server 'sudo -n systemctl start project-zomboid-viewpoint.service'
  ```

Check the unit and log:

```bash
ssh -o BatchMode=yes seanc@server '
  systemctl is-active project-zomboid-viewpoint.service || true
  systemctl status project-zomboid-install.service --no-pager -n 20 || true
  journalctl -u project-zomboid-viewpoint.service -n 120 --no-pager
'
```

Treat `required mod ... not found`, `Access Denied`, or a map that failed to
load as **deploy failures**, not warnings. A gated Workshop item needs the
cached `steamLogin` account; a missing mod is not something to ignore.

## Phase 4 — verify the pack actually loaded

Wait until `project-zomboid-install.service` has finished downloading (check its
log for `Workshop content ready`), then run the authoritative post-download
check, `pz-pack-doctor`. Run it on the server against the installed tree, using
the full pushed revision so it reads the same catalogue that was deployed:

```bash
ssh -o BatchMode=yes seanc@server '
  nix run github:Cairnstew/nixos-projectzomboid-servers/<full-rev>#pz-pack-doctor -- \
    --pack viewpoint \
    --workshop-root /mnt/data/project-zomboid/server/steamapps/workshop/content/108600
'
```

Add `--strict` when warnings should fail the deploy. Re-run after any manual
intervention. It catches a declared item that is missing, a `Mods=` entry
nothing provides, an item downloaded with nothing loaded, an incompatible pair,
a duplicate Mod ID, and a load order that contradicts `require=`/`loadModAfter`.

Also inspect the rendered order (the ini is `0600`, so use sudo):

```bash
ssh -o BatchMode=yes seanc@server '
  sudo -n grep -E "^(Mods|WorkshopItems|Map)=" \
    /mnt/data/project-zomboid/viewpoint/Zomboid/Server/viewpoint.ini | cut -c1-160
'
```

`Mods=` must contain the pack's `mods` in declared order; `WorkshopItems=` must
contain the pack's `workshopMods` ids.

**Removed mods need a clean switch.** The install is additive by default
(`prune=false`), so content no longer declared stays on disk, and a removed map
keeps contributing terrain because `Map=` is derived by scanning the Workshop
root. If the update *removes* mods, tell the user and offer the clean switch
(`prune = true` on `services.project-zomboid-servers`, or the upstream `--prune`
path). Do not silently enable it — it deletes from the shared install.

## Rollback

- **Pack content:** `git revert <sha>`, push `master`, then re-run Phases 2–3 on
  both hosts. Do not rewrite history or force-push.
- **A host's lock bump:** `git revert <bump-sha>` in that host's
  `~/nixos-config`, `git push origin <branch>`, then `nix run` on that host.
- **Server running a bad pack:** stop the unit and roll back the input on the
  `server` branch before the next start. Do not leave it running to "see".

## Reporting

Report, per host: the new `$rev`, the `nix run` result, the running-system
generation, and (server) the `pz-pack-doctor` result. State plainly which steps
did not run or failed; never claim the deploy succeeded when a step was skipped.
