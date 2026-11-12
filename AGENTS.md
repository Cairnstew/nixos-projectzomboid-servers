# AGENTS.md

This repository is a NixOS module for Project Zomboid dedicated servers plus a
shared modpack catalogue. It is not a host configuration: it exports
`nixosModules`, `homeModules`, `modpacks`, `lib`, packages, apps and checks.

## Commands

```bash
nix flake check --no-build            # evaluation only
nix flake check                       # the CI gate
nix flake check ./examples/single-server
nix run .#pz-modpack -- list          # inspect the catalogue
nix run .#pz-maps -- --help           # inspect derived Map= resolution
```

`nix fmt` is deliberately not used: the formatter is invoked per file (see
`.github/workflows/ci.yml`). To match CI:

```bash
out=$(nix build .#formatter.x86_64-linux --no-link --print-out-paths)
"$out/bin/nixfmt" flake.nix modules/*.nix lib/*.nix
"$out/bin/nixfmt" --check flake.nix modules/*.nix lib/*.nix
```

Python is stdlib-only and checked with `python3 -m py_compile scripts/*.py
modules/manage/*.py`.

## Layout

| Path | Contents |
| --- | --- |
| `modules/options.nix` | every option, and nothing else |
| `modules/config.nix` | users/groups, tmpfiles, assertions, polkit, derived upstreams |
| `modules/services.nix` | systemd units: install, servers, consoles, ttyd, timers |
| `modules/manage.nix` | `pz-manage` dashboard and backup units |
| `modules/home.nix` | Home Manager side: writes `~/Zomboid` client config |
| `lib/default.nix` | pure renderer/resolver/proxy helpers, `unitName`, `mkWebPort` |
| `lib/prepare.nix` | the prep and install scripts shared with `nix run` |
| `modpacks/` | plain data catalogue; no module, no `pkgs` |
| `pkgs/` | launcher, standalone runner, client mod fetcher |
| `scripts/` | Python helpers (merge, maps, prune, Workshop, client mods) |
| `docs/options.md` | the complete option reference, checked by CI |

## Conventions

- **One implementation.** A value or script shared by the module, the runner and
  the checks lives in `lib/` or `pkgs/`. Do not copy `webPort`, `unitName`,
  rendering or merge logic.
- **Secrets never enter the store.** `settings`, `sandbox`, `extraArgs` and
  `jvmOpts` are world-readable. Use `secretFiles`/`passwordFile`/`adminAccount`.
  The merged `.ini` is mode `0600`; do not relax that.
- **Exec lines are store paths.** `ExecStart`/`ExecStop`/`ExecStartPre` must be
  `lib.getExe` of a `writeShellApplication`. Never interpolate a multi-line
  string into a Nix `''` block.
- **Assert, don't guess.** Port collisions, missing RCON, beta mismatch, secret
  leaks and invalid Workshop dirs fail evaluation with a message that names the
  fix. Add an assertion rather than a silent no-op.
- **Trap comments are load-bearing.** The long comments explain bugs that
  actually shipped. Keep them accurate; do not replace them with restatements
  of the code.
- **Every option appears in `docs/options.md`.** CI checks names; update the
  prose when behaviour or defaults change.
- **Add a check.** A new branch (a unit, a flag, a renderer path) needs a
  `checks.*` entry in `flake.nix` or it can rot. Negative assertions belong in
  the `failedMessages` helper.
- **Formatting:** `nixfmt-rfc-style`; `deadnix` must be clean; `statix` is
  advisory.

## Security defaults

- `openFirewall` opens only the two UDP game ports. `rconPort` is **not** opened
  unless `openRconFirewall = true`; RCON is plaintext and loopback-only for the
  dashboard.
- The scheduled updater is root only to call `systemctl`; the installer runs in
  `project-zomboid-install.service` as `cfg.user`.
- The dashboard and ttyd have no authentication of their own. They bind
  loopback by default and are meant to sit behind an authenticating proxy or a
  tailnet. `manage.openFirewall` and `web.openFirewall` are off for that reason.
- `extraServiceConfig` is merged **after** the module's hardening directives; a
  consumer can weaken a unit deliberately. Keep that escape hatch, but do not
  rely on it for defaults.

## Commits

Imperative subject line, body explaining the failure mode (not just the diff).
Use `[fix]` for corrections. Update `CHANGELOG.md` for user-visible changes.
Do not commit `node_modules`, `__pycache__`, `result*` or generated store links.
