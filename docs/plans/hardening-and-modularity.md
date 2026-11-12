# Hardening and modularity plan

Status: in progress. Baseline `HEAD 7b0c584`; both `nix flake check --no-build`
and `nix flake check ./examples/single-server --no-build` pass.

This plan tracks the audit findings in the order they will be implemented. Each
checkbox is a commit-sized change with its own verification step.

## P0 — correctness and exposure

- [x] **RCON is not opened in the firewall by default.**
  - Add `servers.<name>.openRconFirewall` (`bool`, default `false`).
  - Use it in `modules/services/server.nix` instead of the unconditional `rconPort`
    open.
  - Add `rconPort`, web-console and dashboard ports to the evaluation-time
    TCP port-collision assertion.
  - Add a module-eval check that a config with `rconPort` set but no
    `openRconFirewall` produces `allowedTCPPorts = [ ]`.
  - Update `docs/options.md`, `docs/manage.md` and `README.md`.

- [x] **Scheduled updates stop running SteamCMD as root.**
  - Always define `project-zomboid-install` when `updateSchedule` is set, not
    only when `updateOnStart` is set.
  - Make the root `project-zomboid-update` unit call
    `systemctl restart project-zomboid-install.service`; the install itself
    stays `User = cfg.user`.
  - Assert in `module-eval` that the install unit runs as `cfg.user` and the
    updater runs as root (it needs `try-restart`).

- [x] **Require complete ttyd credentials and warn on unauthenticated control
  planes.**
  - Assert `web.username != null` implies `web.passwordFile != null`.
  - Add evaluation warnings for `web.enable` without credentials,
    `manage.openFirewall` with no dashboard authentication, and the ttyd
    credential appearing in process argv.
  - Add a module-eval check for the assertion.

- [x] **Reduce ttyd exposure.**
  - Remove the unused `pkgs.sudo` from the unit `path`.
  - Add baseline systemd hardening to the ttyd unit
    (`NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp`,
    `RestrictAddressFamilies`, `UMask`, kernel/clock/hostname protections).
  - Document the `--credential` argv limitation and the proxy-auth preference.

- [x] **Close the legacy POST CSRF hole.**
  - Reject `Sec-Fetch-Site: cross-site` (and `same-site`) on all mutating
    requests, including the legacy `/<server>/(start|stop|restart)` route.
  - Keep the `X-PZ-Manage` header requirement for `/api/*`.
  - Add a pure-function test in the `pz-manage` check.

## P1 — data protection

- [x] **Backups: permissions and secret content.**
  - Set `UMask=0077` on the backup unit.
  - `chmod 0600` the archive after `os.replace` (or document the group-read
    exception needed by the dashboard download endpoint).
  - Document that `Zomboid/Server` contains `RCONPassword`/`Password` and that
    off-host copies are secret material.

- [x] **Restore without root-owned artifacts.**
  - Run the extraction as the server user, or drop to it around `tar`.
  - Add `--no-same-owner` and `--no-same-permissions`.
  - Chown or create the safety archive as the server user.

- [x] **Client mod installer path containment.**
  - Validate `mod.info` ids and `--ids`; reject separators, `..`, and empty ids.
  - Resolve `dest` and assert it stays under `target` before copy/`rmtree`.

- [x] **Merged `.ini` and Steam-token permissions.**
  - `chmod 0600` the merged `.ini` in `merge_ini.py` (the server user owns it).
  - `chmod 0700` the Steam cache directory created under `dataDir`.
  - Document the group-read blast radius.

## P2 — structure and remaining hardening

- [x] Move `webPort` into `lib/mkWebPort`; align `serverDefaults.webConsole`
  with the option default.
- [x] Move `unitName`/prefix into `lib/` and use it from the polkit rule,
  `manage.nix` and the Python-facing JSON.
- [x] Extract `flake.nix` checks into `checks/default.nix`; `flake.nix` is now
  461 lines. Further per-domain splitting is optional if the file grows.
- [x] Fix the polkit-vs-sudo documentation drift in `options.nix`,
  `docs/options.md` and `docs/host-recipes.md`.
- [x] Split `modules/options.nix` and `modules/services.nix` by concern
  (`modules/options/` and `modules/services/`, with the shared types/context in
  `types.nix` and `context.nix`; both top-level files are thin import lists).
- [x] Delete the dead `pkgs/project-zomboid-server/derivation.nix`.
- [ ] Reduce `README.md` option-table duplication.
- [x] Add a VM smoke test with a stub `package` to exercise systemd hardening
  (`checks/vm.nix`; boots a real system, starts the game unit against the stub,
  and asserts the hardening plus the prep-script write path).
- [x] Add `AGENTS.md` with check/format/commit conventions.
- [x] Add the remaining systemd hardening directives with per-unit opt-outs
  (`extraServiceConfig` still merges last). Game/install keep capabilities and
  namespaces for steam-run/bwrap and 32-bit steamcmd.

## Verification after each step

```bash
nix flake check --no-build
nix flake check ./examples/single-server --no-build
```

The first P0 item also needs a targeted eval:

```bash
nix eval --json --impure --expr '
let
  f = builtins.getFlake (toString ./.);
  pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; };
  ev = f.lib.tests.eval {
    inherit pkgs;
    config.services.project-zomboid-servers = {
      enable = true;
      servers.main = {
        defaultPort = 16261; udpPort = 16262;
        rconPort = 27017;
        secretFiles.RCONPassword = "/run/secrets/rcon";
      };
    };
  };
in ev.config.networking.firewall.allowedTCPPorts'
```
