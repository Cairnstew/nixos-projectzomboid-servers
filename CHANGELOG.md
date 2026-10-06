# Changelog

All notable changes to this project. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Web-console unit control now uses polkit instead of sudoers.** The scoped
  `security.sudo.extraRules` entry for the console user was unreachable on any
  host that sets `security.sudo.execWheelOnly = true`: that option makes the sudo
  wrapper executable by the `wheel` group only, so `project-zomboid-web` died with
  `sudo: unable to execute /run/wrappers/bin/sudo: Permission denied` before the
  rule was consulted — `.start`/`.stop`/`.restart` in the web console silently
  failed. Adding the user to `wheel` is not an option (with
  `wheelNeedsPassword = false` that is full passwordless root). The module now
  installs a polkit rule granting that user `manage-units` on `project-zomboid-*`
  and the console shim calls `systemctl` without sudo. This is strictly narrower
  than before and works under either hardening posture.

### Fixed

- **`autoStart = false` did not stop the server starting at boot.** The console
  FIFO socket declared `requires = [ "<unit>.service" ]` unconditionally, and a
  `Requires=` on a socket eagerly starts its paired service when the socket is
  started — while the socket is itself pulled in by `sockets.target` at boot.
  The option only removed the service from `multi-user.target`, so the socket
  brought it up anyway. Verified: `systemctl restart <unit>.socket` started the
  service with `autoStart = false`. The dependency is now conditional on
  `autoStart`; when it is off, the implicit same-name socket activation still
  starts the server on the first write to the console FIFO.

- **The web console never worked: ttyd was handed a store *directory*.**
  `mkWebShim` returns a `writeShellApplication`, whose store path is a directory
  containing `bin/<name>`, but the launcher interpolated the package itself into
  ttyd's command position. ttyd therefore tried to exec a directory, the child
  exited immediately with code 243, and the browser terminal opened and closed in
  a loop (`started process … process exited with code 243 … WS closed`). Now
  `lib.getExe (mkWebShim name)`. The HTTP page still served, which is why the
  console looked merely "broken" rather than absent.

- **Enabling `web.enable` deleted the server user.** The two halves of the
  service-user definition were combined with `//`, which is a *shallow* merge,
  and both halves carry a `users` key — so the web-console half's `users`
  replaced the server half's outright, dropping `users.project-zomboid` (its
  group survived, since only the other half defines `groups`). A server that was
  already running then failed on its next stop/start with `Failed to determine
  credentials for user 'project-zomboid': Unknown user` (`status=217/USER`),
  systemd waited out `TimeoutStopSec` and SIGKILLed it. Now `lib.recursiveUpdate`.
  This only fires on hosts that enable the console, and only once a server has
  been started — which is why the suite never caught it.

- **The module could not be enabled at all with the default `web.enable = false`.**
  `security.sudo.extraRules` is a *list* option, but was assigned
  `lib.optionalAttrs cfg.web.enable [ … ]`, which yields an **attrset** — `{}`
  when the console is off. Evaluation therefore died with "A definition for
  option `security.sudo.extraRules` is not of type `list of (submodule)`" for
  every server that did not turn the web console on, which is the default. Now
  `lib.optional`, so the option is `[ ]` or `[ { … } ]`. This only ever passed
  in the repo's own example because that example enables the web console.

- **`jvmOpts` never reached the JVM.** `pzexe` splits its arguments on a `--`
  separator: everything before it is a JVM flag, everything after is a game
  argument. The launcher was invoking it as `… "${jvm_opts[@]}" -servername …`
  with no separator, so every flag was handed to the *game*, which logged
  `unknown option "-Xmx…"` and ignored it. The JVM silently ran on the vendor's
  stock `-Xmx8g` — heap sizing, `-XX` flags and (later) `-javaagent` were all
  inert, with no error to show for it. Verified against a live 42.21.0 install:
  `-Xmxbad` via argv produces the game's `unknown option` and no JVM error,
  while the same flag after `--`, or in `ProjectZomboid64.json`'s `vmArgs`,
  produces the JVM's `Invalid maximum heap size`. The launcher now emits the
  separator.

### Added

- `javaAgent` (`{ jar, args }`, per server): loads a JVM agent before any mod
  class is on the classpath, prepended to `jvmOpts`. This is the hook Java-mod
  frameworks such as ZombieBuddy need — PZ's own mod system is Lua-only, and the
  mods those frameworks enable keep their JARs inside their own Workshop folders,
  so only the agent has to reach the JVM. A headless server must set a
  non-prompting policy (`policy=allow-all` for ZombieBuddy), or the framework
  waits on a stdin prompt nobody can answer and the server appears to hang.
- The `viewpoint` modpack: OwenOasis' "Project Viewpoint Vanilla+" Steam Workshop
  collection (122 of its 123 items; `ZombieBuddy Extensions` is excluded as
  `versionMax=42.0` and jar-less). Order follows the collection, which is what
  `WorkshopItems=` receives.

### Changed

- `jvmOpts` and the `mods` option descriptions corrected. The `mods` text had
  claimed `modworkshop.net` hosts Project Zomboid mods and that non-Workshop mods
  should be sought there; it does not, its API lists no Zomboid entry at all.

## [0.2.0] — 2026-10-03

The audit release. Fixes a secret leak, removes two Build 41 leftovers that were
being written to Build 42 servers, and derives `Map=` deterministically.

### Security

- **Secrets no longer reach the Nix store.** A secret in `settings` produced a
  `pkgs.writeText` base `.ini` at mode `444`, world-readable, containing values
  in cleartext — greppable out of `/nix/store` by any local user.
  `RCONPassword`, `DiscordToken` and `WebhookAddress` were all affected.
  - New `secretFiles` option (`Key = path`), with `passwordFile` as sugar for
    `Password`. Values are read at start and written straight into the key.
  - Evaluation now **fails** if a known-secret key appears in `settings`,
    `sandbox`, or a modpack's `defaultSettings` / `defaultSandbox`.
  - The renderer filters those keys independently, so a bare module import cannot
    leak one either.
  - `merge_ini.py` gained `--secret-file Key=path`; `--password-file` is gone
    with a pointed error.
- `extraArgs` is documented as the same trap in a different place: it is baked
  into a world-readable unit file.

### Fixed

- **`Whitelist=` and `Users=` are not Build 42 ini keys.** They were being written
  unconditionally, producing a config that listed admins and a whitelist and did
  nothing. Now gated behind `compatibility.build41`, default `false`. The
  whitelist on Build 42 is a table in `Zomboid/db/<servername>.db`.
- **`SpawnPoint = 2` removed from `survival-hard`.** `SpawnPoint` is a world
  coordinate triple (`x,y,z`), so this meant *two metres from the origin*.
- **Generated files were created read-only.** `cp` of a mode-444 store file gives
  the destination the source's permissions, so the *second* start failed with
  `cp: cannot create regular file: Permission denied`. Masked in production
  because PZ rewrites `SandboxVars.lua` in between. Now `install -m 0644`.
- **Two optional arguments reached `merge_ini.py` as a single empty string.**
  `${v+$v}` expands whenever `v` is merely set (and `v=""` is set), and
  `"${v:+$v}"` passes one empty argument because a quoted expansion is always one
  word that never disappears. Both aborted the start with `arg '' has no '='`.
  Correct form: `${v:+"$v"}`.
- **Two Lua syntax errors in the spawn renderers**, both invisible to `grep`:
  missing commas between table entries, and `"farm worker" = {` (Lua reads the
  string as a positional value, then finds `=`). Keys are now emitted bare when
  valid identifiers — matching PZ's own output — and bracket-quoted otherwise.
- **`nix flake check --all-systems` failed.** `aarch64-linux` was declared in
  `systems`, but PZ is a Steamworks title with no ARM build, so
  `packages.aarch64-linux.…` could not evaluate. Outputs are now `x86_64-linux`
  only; an ARM host may still consume the module.

### Added

- **Derived `Map=`, deterministically.** `Map=` is the one setting that cannot be
  written down statically — a map exists only if an installed mod ships
  `media/maps/<name>/`, and installed mods are unknown until steamcmd has run. So
  `map = null` now means *derive it*, at start, via `scripts/pz_maps.py`.
  - Sort key is **total**: `(priority, kind, numeric id, mod id, map name)`, with
    `baseMap` always last. Nothing depends on filesystem iteration order.
  - Duplicate map names are **reported** rather than resolved silently by
    download order. PZ resolves `media/maps/<name>` across every loaded mod, so
    two mods shipping one name previously loaded the wrong tiles with no warning.
  - New `mapOrder.{enable,priority,strict,dedupe}`; a mod shadowing the base
    map's name is an error.
  - New `baseMap` option, and `pz-maps` app / `--list-maps` for inspection.
- **Spawn points and regions.** `spawn.points` and `spawn.regions` render
  `<server>_spawnpoints.lua` and `<server>_spawnregions.lua` — two of the four
  files PZ lists as necessary for a server to work. Written only when non-empty,
  and removed when emptied, since PZ regenerates them when absent.
- **Admin accounts.** `adminAccount.{username,passwordFile}` passes the
  `-adminusername`/`-adminpassword` pair, which is the only way to create a Build
  42 admin. The `ps` exposure is inherent to PZ and documented rather than
  glossed.
- New options: `adminAccount`, `extraArgs`, `betaBranch`, `upnp` (now `false`),
  `selfManagedMods` (now `true`), `softReset`, `compatibility.build41`.
- New runner flags: `--secret`, `--map`, `--base-map`, `--map-priority`,
  `--strict-maps`, `--dedupe-maps`, `--list-maps`, `--extra-arg`, `--admin-user`,
  `--admin-pass-file`, `--soft-reset`.
- New checks: `secrets-not-in-store`, `spawn-and-reset`, `map-ordering`,
  `map-pin-clean`, `secret-guard`.
- `versions.json` gained `defaultBaseMap`, and `defaultRconPort` moved
  27015 → **27016** (27015 is Minecraft's). Read by the flake so the package, the
  runner and the module cannot drift apart.

### Changed

- `selfManagedMods` defaults to `true`. With it off, a player who opens the
  server's mod screen can write a different `Mods=` back to the `.ini`, and the
  next start would faithfully apply their change over yours.
- `upnp` defaults to `false`, unlike PZ's `true`. Automatic port forwarding
  punches holes in a firewall you deliberately kept closed, and cannot work
  behind a container at all.
- README substantially rewritten; a `docs/` set added (see below).

## [0.1.0]

Initial release: the NixOS module, the modpack catalogue, the shared
install/prepare implementation, and the standalone `nix run` runner.

[Unreleased]: https://github.com/you/nixos-projectzomboid-servers/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/you/nixos-projectzomboid-servers/compare/v0.1.0...v0.2.0