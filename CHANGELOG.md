# Changelog

All notable changes to this project. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Workshop items are resolved before any download.** `pz-workshop expand` now
  pre-fills the draft pack's `mods` list from each item's description `Mod ID:`
  declaration (the Steam Web API returns the description text, so no HTML
  scraping — and a live 138-item collection declared one for every item). A new
  `pz-workshop resolve {collection,pack} <id>` maps a collection or an existing
  pack to its internal Mod IDs and prints the paste-ready `Mods=` /
  `WorkshopItems=` lines in the module's exact separators. Both stay
  best-effort: an author may also declare a dependency, and unresolved items are
  flagged for confirmation after the first download — the running server's
  `Mods=` is always the `mod.info`-derived one. Map folders are deliberately
  never read from descriptions (the text is too noisy — "map mods", "Maps are
  changing in B42"); `pz_maps.py` reads the files instead. The `pz-workshop-helper`
  check now covers the description parsing and the prefill.

- **The install is verified, not fire-and-forget.** The shared install now
  downloads a batch of Workshop items, checks each one on disk (an empty
  directory counts as a failure), retries the stragglers once, and — if any
  still have not arrived — exits non-zero naming each id and title, with
  remediation. The servers `Require` this unit, so they no longer quietly start
  with mods missing. A `PZ_STEAMCMD` override lets an operator pin a different
  steamcmd, and lets the check exercise the whole flow offline.
- **`steamLogin` — private and mature-gated Workshop items are now installable.**
  Items that answer `Access Denied` anonymously (Brita's Armor Pack is the known
  example) are fetched by logging the shared install's steamcmd in as an account
  that owns Project Zomboid. The password is never stored: the token is cached
  once under `dataDir` with `steamcmd +login <account>`, and non-interactive runs
  reuse it.
- **`localMods` — the fallback for a mod that cannot be downloaded at all.**
  `servers.<name>.localMods` takes `folder-name = directory`, symlinks each into
  the server's `Zomboid/mods`, and adds the key to `Mods=` automatically — so a
  private or modworkshop.net mod is declared once instead of hunted by hand.
- **`prune` — a clean pack switch.** With `prune = true` the shared
  `steamapps/workshop/content/<appid>` is reduced to the union of what enabled
  servers and client hosts declare, and each server's Workshop and local-mod link
  farms to its own declared list. Prune runs only after every item verifies, and
  `links` mode touches only symlinks the module made — a hand-placed directory is
  never deleted. Under `nix run` the same is `--prune`. Newly tested by
  `scripts/pz_prune.py` and offline install/prep checks.
- **`failOnMissingMods = false` — a degraded-but-up server.** When a Workshop item
  cannot be downloaded, log it, **skip** it, and let the install succeed instead
  of refusing (the default). The skipped item stays in `WorkshopItems=`, PZ warns
  at start, a later install picks it up with nothing re-declared, and prune is
  withheld while anything is missing so a re-login can fetch it. Standalone:
  `--lenient`. The install check now covers strict-fail, skip+log, and
  "no prune while missing" in one offline run.

- **A pack can now drive the in-game Host button, not only a dedicated server.**
  `servers.<name>.clientHost.enable` renders this server's config for the world a
  player runs from Project Zomboid's own **Host** button, exposed read-only as
  `clientHosts.<name>`: a `prepare` script, the base `.ini` and SandboxVars store
  files, and the resolved `Mods=`/`WorkshopItems=` lists. Both ways of hosting a
  world read the same files, so a pack is described once and the two cannot drift
  into different mod lists.

  Deliberately **independent of `enable`**: the main use of a client host is a
  machine with no dedicated server, and a pack must still render there. Deriving
  it from `enable` would have silently produced nothing for exactly that case.

  The `prepare` script reuses the dedicated server's `merge_ini.py`, so the
  client's `.ini` is **merged, not rewritten** — `Seed`, `ServerPlayerID` and
  `LastModified` survive and re-running is safe, the same guarantee the dedicated
  path has. Verified by running it against an existing client `.ini`: the three
  world-identity keys came through unchanged while `Mods=`/`WorkshopItems=` were
  filled in.

  Setting `PZ_SERVER_DIR` makes the script symlink every Workshop item from the
  shared steamcmd download into the client's Steam library — **one download
  serves both hosts** rather than two. The library is DISCOVERED from
  `libraryfolders.vdf` when `PZ_CLIENT_WORKSHOP` is unset, so no host file
  hard-codes where Steam put it; `PZ_LINK_STEAM_WORKSHOP=0` skips it instead.
  ⚠ Linking is server-side parity and a saved download only — the game CLIENT
  reads its Workshop items through Steam's subscription list and never scans the
  library, so a hosted world still needs them subscribed.
  The shared install/update unit now counts a client host's items among those it
  keeps downloaded, so that copy does not go stale the moment the last dedicated
  server is switched off — which is precisely the client-host configuration.

  Note this is the *config* only. A pack whose mods need a JVM agent
  (e.g. ZombieBuddy) also needs that agent installed in the **client**, which is
  a launch-option change outside any NixOS module and is left to the pack's own
  instructions.

- **A Home Manager half, so enabling a client host writes the files itself.** A
  new `homeModules.project-zomboid-servers` (alias `homeModules.default`)
  installs the `clientHosts` files into the client user's `~/Zomboid`, reading
  the pack back off `osConfig.services.project-zomboid-servers.clientHosts` so it
  stays described once and cannot drift from the dedicated server's config.
  Previously every consumer had to hand-write a `home.activation` hook and
  hard-code both the SteamCMD install path and their Steam library. Inert under
  standalone Home Manager, which has no `osConfig`.
  `services.project-zomboid-servers.home.enable = false` turns it off;
  `…home.linkSteamWorkshop = false` keeps the files but drops the link.

- **The Steam library is discovered rather than hard-coded.**
  `scripts/pz_steam_workshop.py` finds the library that actually holds Project
  Zomboid, by reading `steamapps/libraryfolders.vdf` and checking for the app's
  `appmanifest_108600.acf`, and `mkClientHostScript` calls it when
  `PZ_CLIENT_WORKSHOP` is unset. A machine with the game in a second library — or
  not installed via Steam at all — now behaves correctly where a baked-in path
  silently did nothing; the absent case is reported and skipped, never fatal.
  Covered by the `steam-workshop-discovery` check.

- **Two Steam Workshop CLIs, for moving between a collection and a pack.**
  `nix run .#pz-workshop -- expand <collection-id>` reads a Steam Workshop
  collection and prints a reviewable draft `modpacks/<name>.nix`, child order
  preserved; `… emit <pack>` prints a pack's items as paste-ready URLs. Steam has
  no public write API for collections, so "generate a collection" can only mean
  emit its contents for a human to paste — and a collection is never what a
  dedicated server consumes, which reads `WorkshopItems=` (individual ids). The
  draft is deliberately not a finished pack: a collection cannot say which items
  are inert on your build (the `viewpoint` pack drops ZombieBuddy Extensions) or
  the `Mods=` local-mod ids. Covered by the `pz-workshop-helper` check, whose
  offline half asserts child ordering and Nix-safe escaping.

- **`nix run .#pz-client-mods -- <pack>` fetches a pack's mods onto a CLIENT.**
  It downloads each Workshop item with `steamcmd` and installs the mod(s) it
  contains as **local mods** in `~/Zomboid/mods` — the one form Project Zomboid's
  client loads with no Steam subscription, per the upstream wiki's "manual local
  installation". The install keys each folder by its `mod.info` `id=`, the same
  id the server's `Mods=` list uses. `--steam-library` pre-seeds the Steam
  library instead (inert until subscribed, the client-host caveat); `--login`
  is for items that answer `Access Denied` anonymously (verified: some do, some
  do not; the authenticated download needs real credentials and is the one path
  the checks cannot cover). Staging defaults under `~/.cache` because NixOS
  `steamcmd` runs under `steam-run`, whose private `/tmp` silently swallows a
  download.
  Covered by the `pz-client-mods-plan` check.

- **A Home Manager option so a client gets the pack's mods declaratively.**
  `services.project-zomboid-servers.home.installMods` runs the downloader as an
  idempotent systemd user service at login, installing the mods for whatever the
  NixOS side marked `clientHost.<name>.enable`. It deliberately does not
  "subscribe": that is not possible — Steam has no public write API for
  subscriptions, `steamcmd` answers `Command not found: workshop_subscribe`, and
  the client's `appworkshop_<appid>.acf` carries no `subscribed` flag (all
  checked) — so it installs **local mods** in `~/Zomboid/mods`, the form the
  client actually loads. The new `home.steamLogin` covers items that answer
  `Access Denied` anonymously, reusing a SteamCMD token cached by a one-time
  `steamcmd +login` because a unit has no terminal to prompt on. The downloader
  became a package (`pkgs.project-zomboid-client-mods`) shared by the
  `pz-client-mods` app and this module, so the two cannot drift.

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