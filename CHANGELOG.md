# Changelog

All notable changes to this project. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Setting `rconPort` no longer opens the port in the firewall.** RCON is
  plaintext TCP, and the dashboard and idle-stop check read it over loopback.
  Opening it required only a non-zero port before, which contradicted the
  documentation and published RCON on every interface whenever a host enabled
  the dashboard. A new per-server `openRconFirewall` (default `false`) is the
  only way to open it now. TCP port collisions between `rconPort`, `manage.port`
  and ttyd consoles are also rejected at evaluation time.

- **Scheduled updates run the installer as the service user again.** The
  root timer used to execute the SteamCMD installer directly, leaving
  root-owned files in the data/install directories and a root-owned cached
  Steam login. It now restarts `project-zomboid-install.service`, which keeps
  `User = cfg.user`, then restarts the running servers.

- **The legacy dashboard POST route is CSRF-guarded.** Mutating requests now
  reject `Sec-Fetch-Site: cross-site`/`same-site` in addition to the
  `X-PZ-Manage` header on `/api/*`. Proxy basic auth does not prevent CSRF, so
  the legacy `/<server>/(start|stop|restart)` route needed its own check.

- **The ttyd console unit is sandboxed and no longer carries sudo.** The unit
  gained `NoNewPrivileges`, `ProtectSystem=strict`, `CapabilityBoundingSet=""`
  and the kernel/clock/hostname protections. The unused `pkgs.sudo` was removed
  from its PATH. ttyd still receives its basic-auth password via `--credential`,
  which is visible in the process list; the module now warns about that and the
  option docs point at proxy authentication instead.

- **Backup archives are no longer world-readable.** The backup unit now sets
  `UMask=0027` and the archive is chmodded to `0640`. This matters because the
  archives include `Zomboid/Server`, and that directory contains the merged
  `.ini` with the RCON and join passwords; the docs now say so. Restore also
  validates archive members and extracts with `--no-same-owner`, running as the
  server user through `runuser` instead of as root.

- **The client mod installer rejects unsafe ids.** A Workshop mod controls its
  `mod.info` `id=`, which becomes a directory name and, with `--force`, a
  `shutil.rmtree` target. Ids containing path separators or `..` are skipped, the
  destination is checked against the target directory, and `--ids` must be
  numeric.

- **The merged `.ini` and Steam login cache are private.** The prep script now
  writes the merged `.ini` as `0600` (PZ runs as its owner) and sets the cached
  Steam token directory under `<dataDir>/.local/share/Steam` to `0700`, so the
  web-console/dashboard group cannot read either.

- **Every unit now carries the sandbox directives that fit its job.** The game,
  install, updater, dashboard, backup, backup-directory and idle-stop units
  gained `NoNewPrivileges`, the kernel/control-group/clock/hostname protections,
  `LockPersonality` where the binary is native, `RestrictSUIDSGID`,
  `RestrictRealtime`, and `CapabilityBoundingSet=""` for the units that never
  need a capability. The game and install units deliberately keep their
  capabilities and namespaces: steam-run's bwrap user namespace and the 32-bit
  steamcmd fail without them. `extraServiceConfig` still merges last, so a host
  can weaken a unit deliberately.

### Removed

- **Two Viewpoint add-ons that crash on Build 42.22: Surface Fix and Physics &
  Collision.** 42.22 changed `IsoGridSquare.getObjects()` from `PZArrayList` to
  `List<IsoObject>`, and both Java mods were built against the old signature.
  Surface Fix (`vpinteriors`) aborts the client while the world is meshed with
  `NoSuchMethodError: 'zombie.util.list.PZArrayList zombie.iso.IsoGridSquare.getObjects()'`;
  Physics & Collision (`vpp`) detects the same mismatch and switches itself off,
  so it only adds an error to the log. The upstream collection (3812346398) no
  longer lists either. Both are removed from the `viewpoint` pack until the
  author publishes a 42.22 build. The same API is referenced by seven other
  42.21-era Viewpoint add-ons in the pack, so treat them as suspect if one of
  their code paths runs.

### Added

- **A NixOS VM smoke test for the unit sandbox.** `checks/vm.nix` boots a real
  system with a stub server package, starts the game unit, and asserts the
  hardening properties plus that the prep script can still write the data
  directory. It also checks the dashboard and backup units accept their sandbox.
  Evaluation-only checks cannot catch systemd rejecting a directive or a
  read-only mount blocking the merge.

- **The dashboard shows scheduled starts and idle-shutdown countdowns.** The
  `Schedule` panel lists each server's `schedule.start` expressions and the next
  elapse from the start timer, plus the `idleStop` timeout and a live countdown
  while the server is empty. Countdowns use the server's clock as an offset, so
  a browser with a skewed clock still shows the correct remaining time.

- **Scheduled starts and idle shutdown per server.** `servers.<name>.schedule.start`
  takes systemd `OnCalendar` expressions and creates a start timer; the server
  can then run `autoStart = false` so a boot does not bring it up outside the
  window. `servers.<name>.idleStop` adds a once-a-minute timer that stops the
  server after `timeout` (default `30m`) with no players. It reads the player
  list over RCON, so `rconPort` and `secretFiles.RCONPassword` are required and
  an unreachable RCON is never treated as empty. The count is re-queried
  immediately before stopping, so a just-joined player is not kicked. Use it
  together with the game's own `PauseEmpty = true` to freeze the world clock
  while the JVM is up and stop the JVM after the idle period. See
  `docs/options.md#schedule` and `docs/host-recipes.md`.

- **`pz-manage`: a dashboard, JSON API, RCON actions and scheduled backups.**
  `manage.enable` runs a stdlib-only Python service on loopback with a small web
  UI: status, uptime, memory, players (RCON), log tail, a read-only view of the
  effective Nix config, save/broadcast/kick/ban/whitelist and
  start/stop/restart. `backup.enable` adds a systemd timer that writes
  `tar --zstd` archives of `Zomboid/{Saves,db,Server,Lua}` and a
  `project-zomboid-restore` CLI. The UI never writes `viewpoint.ini`,
  `_SandboxVars.lua`, `Mods=` or `WorkshopItems=`: the prep script re-applies
  those on every start. Restore is a CLI because it stops the server and
  replaces world files. See `docs/manage.md`.

- **Corpse- and container-wide batch ripping, for the `viewpoint` pack.**
  `Tear All Clothes [B42 MP]` (`TearAllClothesMP`, the B42.20+ fork of
  3519629457) replaces `Rip-A-Holic` (`rip-a-holic`), whose Rip All only
  scanned the player's inventory and bags. It adds Selected / Surrounding /
  All batches: **Surrounding** tears clothing in nearby open containers, on
  the floor and on corpses, and **All** adds the inventory and bags, while
  equipped and favorited garments are left alone. Each garment runs through
  one of the mod's own recipes, so consumption and output are
  server-authoritative instead of a client-side item move, and socks, belts,
  underwear, bandanas, gloves and recoverable shoes are included even where
  B42 omits the vanilla ripping tag. Verified from the download:
  `versionMin=42.20.0`, no `require=`, `incompatible=3519629457` (the
  original's Workshop id — do not add the original item alongside it). It
  drives the vanilla `RipClothing` / `RipDenimClothing` recipes and disables
  itself with a `[TACMP]` log line if either is missing. The mod's blurb asks
  for `DoLuaChecksum=true`; the pack keeps it `false` for its ~390 Workshop
  items, which drops only the integrity check. Lost with Rip-A-Holic: Train
  Tailoring and leather-from-strips (TFC Combine Leather still covers leather
  sewing); Tear All Clothes awards 0.3 Tailoring XP per item instead.

- **Wring out all wet clothing without undressing, for the `viewpoint` pack.**
  `Wesch's Better Wringing` (`w_betterwringing`) adds a "Wring Out All Wet
  Clothing" context entry and re-equips a garment after a single wring in
  singleplayer. Its `[MP FIX]` companion (`w_betterwringing_mpfix`) replaces
  that action by load order so on a server it wrings every wet garment in place
  and **never unequips**: B42 clothing wetness is server-authoritative, and an
  unequip pushes wetness 0, which makes `ISWringClothing:isValid()` fail and
  `resetQueue()` discard the re-equip and every remaining garment. That is the
  reported "it just unequips and maybe wrings out" behaviour. The fix must load
  after the original; vanilla's own per-item wring option is left in place.

- **Read-all and multiplayer fast-forward for the `viewpoint` pack.**
  `DWTB Auto Reader` (`DWTB_AutoRead`) queues every still-useful recipe
  magazine and skill book within reach through the vanilla `ISReadABook`
  action, then returns borrowed books; it is client-side, dependency-free and
  works with the pack's Read While Walking. `MP Fast Forward`
  (`MPFastForward`) is the maintained B42 rewrite of Fast Forward (MP): pause
  plus three speeds, agreed by all players or forced by an admin, cancelled by
  movement or a nearby zombie; it speeds reading and crafting too, so it pairs
  with Auto Reader. It only sets `GameTime`'s multiplier instead of overriding
  `isGamePaused`/`getGameSpeed`, which Viewpoint reads. Two Viewpoint caveats:
  Auto Reader's entry is in the inventory context menu, so first person needs
  Viewpoint Interface's "Use the game's inventory windows" (or the isometric
  view), and MP Fast Forward's speed panel sits under the clock where the
  vanilla minimap is.

- **`clientHost.preset` — an opt-in mod preset for the client's own Mods menu.**
  A client-hosted world loads the pack's `Mods=` only for the hosted session;
  the client's own list is a separate setting, so Viewpoint's client-side code
  and UI mods are not loaded outside the Host flow. Setting
  `servers.<name>.clientHost.preset.enable = true` now renders the pack's ordered
  `mods` as one named preset (default: the server attribute, `viewpoint`) and
  **merges** it into `~/Zomboid/Lua/pz_modlist_settings.cfg`, preserving the
  player's other presets and favourites. The write is idempotent and
  non-destructive; a second activation replaces the managed line rather than
  appending a copy. The preset name is validated at build time, and ids
  containing `:`, `;`, `\` or a newline are rejected rather than silently split.
  Vanilla re-sorts a preset on apply using `require=` only, and reports mods that
  are not downloaded in its “missed mods” window — both are documented limits,
  not module behaviour. `client-host-prepare` now asserts the merge semantics,
  and `module-eval` asserts the preset renders with `enable = false`.

- **`upnp` is asserted dead on Build 42.** The 42.21 jar contains no UPnP class
  and `ServerOptions.uPnp` is never read, so `UPnP=` forwards nothing — a silent
  no-op in exactly the place a broken port forward is hardest to see. The
  resolver now warns when `upnp` is set on a Build 42 server and points at the
  router (or a UPnP client such as `miniupnpc`) instead. Build 41 is unchanged.

- **`clientHost.openFirewall`.** A client host's ports can now be opened from
  Nix. The server-level `openFirewall` never covered one: it is wired from the
  *enabled* servers, and the usual client-host configuration has
  `enable = false` with no systemd unit. The new option feeds `defaultPort` and
  `udpPort` into `networking.firewall.allowedUDPPorts` from `clientResolved`,
  and `module-eval` asserts both reach the firewall. `docs/troubleshooting.md`
  documents the rest of the path (`server-address@<public-ip>` advertisement,
  router forwarding, UPnP discovery).

- **`PublicDescription` for the `viewpoint` pack.** The world previously had a
  name and an empty browser description (`PublicDescription=`), so the public
  listing showed nothing. It now carries a one-line summary of the pack. It is
  a pack default, so the dedicated server and the client host show the same text;
  override it in a server's `settings` if a deployment needs different wording.

- **Dotted `sandbox` keys for Build 42's nested tables.**
  `sandbox."ZombieLore.Speed"` and
  `sandbox."ZombieConfig.PopulationStartMultiplier"` now render a real nested
  Lua table. A flat key from one of those tables is rejected with the dotted
  spelling, because PZ ignores unknown keys silently — the server registers
  `ZombieConfig.PopulationStartMultiplier`, never a top-level
  `PopulationStartMultiplier`. `Farming` stays valid flat as the farming-speed
  enum; the XP multiplier is `"MultiplierConfig.Farming"`. The known tables and
  keys (`ZombieLore`, `ZombieConfig`, `MultiplierConfig`, `Map`, `Basement`)
  come from the 42.21 `SandboxOptions` classes and a generated
  `SandboxVars.lua`.

- **Large/heavy vehicles for the `viewpoint` pack.** W900 Semi-Truck (with its
  Oshkosh M911 compatibility patch), LIAZ 300, RVs, Heavy Duty & Trailers
  (19 RVs/ambulances/work trucks/trailers with Viewpoint support), Road Builder
  (a Volvo FE6 dump truck that lays gravel roads), and the RKC heavy set:
  the Trucksmith framework plus HEMTT M977 Cargo, M984 Wrecker and M978 Tanker.
  W900 and LIAZ require `tsarslib`; the HEMTTs require `Trucksmith`; all are
  already ordered after their dependencies. Every item was downloaded and its
  `mod.info` `id=`/`require=` checked. Deliberately excluded: the WIP Ford
  Transcontinental, the BETA Double Decker Bus, Project RV Interior (mid-save
  and load-order warnings), Viewpoint - 3D RVs (WIP), the Wingsmith aircraft
  family (a second flight framework), and combat vehicles (LAV-25, HEMTT C-RAM).

- **Vehicle content, Viewpoint vehicle bridges and QoL for the `viewpoint`
  pack.** Filibuster Rhymes' Certified Used Cars (53 cars + 6 trailers) with
  Vehicle Animations Sinked for its multiplayer door/window sync, More Car
  Variants (KI5) for extra KI5 skins, the '85 Club Car Golf Cart, and Immersive
  Cars: Decay (pairs with the existing Parts Picked). Viewpoint-specific
  additions: Immersive Driving, the KI5 Vehicle Parts Fix, the KI5/vanilla
  Vehicle Interior Fix, Real Vehicle VFX plus its RVV+Viewpoint bridge, and
  Visible Vehicle Coupling plus its Viewpoint addon. QoL/fixes: Essential Car
  Notifications, Let Me Drive!, Proper Vehicle Injuries for MP, and Vehicle
  Ground Guard (loaded last among vehicle mods). Every item was downloaded and
  its `mod.info` `id=`/`require=`/`loadModAfter=` checked; dependencies
  (ZombieBuddy, Viewpoint, YAPZLib, SpecLoot, damnlib, RVVFX, VVC) are already
  in the pack. Vanilla Vehicles Replacer (KI5) is deliberately excluded:
  More Car Features says to drop vehicle replacers and use its spawn-zone
  settings instead.

- **Maps for the `viewpoint` pack.** 48 Build 42 map mods plus the tile packs
  they require, covering central Knox Country, Louisville, the Leavenburg
  corridor, Louisville International Airport, and a large set of towns and
  bunkers. The pack pins `Map=` instead of deriving it: several B42 map mods
  still ship their B41-era map folder next to the B42 one (Chestown, Greenport),
  so detection would load both and overlap terrain. The pinned list names only
  the intended folders and keeps the authors' order for the contiguous groups
  (Jasperville → bridge → Leavenburg, Anruisi → Safeharbor, Chinatown →
  expansion, Cathaya → highway). Every selected map was downloaded and its
  `mod.info` `id=`/`require=`/`incompatible=` and `*.lotheader` cell footprint
  checked, so the set has no unintended cell overlap. Also adds the Viewpoint
  map-layer fix and 3D map-furniture shim.
- **An optional Steam Web API key for the Workshop catalogue helpers.**
  `pz-workshop expand` / `resolve` query `api.steampowered.com` anonymously by
  default, which works but has a tight rate budget. Set
  `PZ_STEAM_API_KEY_FILE` to a file holding a key
  (`steamcommunity.com/dev/apikey`) for a higher budget — a *path*, never the
  key itself, so the value is read at run time and stays out of the store path
  and `ps`. Unset keeps the anonymous path unchanged, and an unreadable file
  warns rather than failing.

  Deliberately **not** a `steamLogin` replacement, and it cannot be one: the key
  authenticates read-only API queries, while Workshop *content* downloads
  authenticate as a Steam account via `steamcmd +login`, so mature-gated and
  author-restricted items still need `steamLogin`. Nor a module option — no
  server unit reads it, and the helpers run on a workstation where `nix run`
  never evaluates the module.
- **`workshopDir` — the dedicated server's Workshop directory is explicit.**
  Defaults to `<serverDir>/steamapps/workshop/content/108600`, is asserted
  absolute and asserted to end in that suffix (SteamCMD installs relative to a
  library root, which the module derives from it), and is passed to both
  steamcmd and the prep/map/launcher path as `PZ_WORKSHOP_DIR`. A dedicated
  install no longer assumes the content lives under `serverDir`.
- **A client host renders with the dedicated half switched off.** `clientHosts`
  moved out of the `enable` gate, so a configuration that only sets
  `servers.<name>.clientHost.enable = true` produces no install unit, no
  steamcmd run and no `project-zomboid` user. That is now covered by
  `module-eval`'s client-only scenario.
- **New checks.** `client-host-prepare` proves the client script writes only
  `~/Zomboid/Server/`, contains no Steam/steamcmd/mod path, and restores
  `SelfManagedMods` after the game strips it. `pz-client-mods-isolation` proves
  the deprecated downloader receives an isolated HOME and has no Steam-library
  mode. `module-eval` gained a custom-`workshopDir` scenario.

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
- **`prune` — a clean pack switch.** With `prune = true` `workshopDir` is reduced
  to the union of what enabled dedicated servers declare, and each server's
  Workshop and local-mod link farms to its own declared list. Prune runs only
  after every item verifies, and
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

  The script is **config only** and takes exactly one environment variable,
  `PZ_CLIENT_ZOMBOID`. It writes only
  `~/Zomboid/Server/<name>.ini` and `_SandboxVars.lua`; it never runs steamcmd,
  never references a Steam library, and never writes `~/Zomboid/mods`. With
  `WorkshopItems=` populated, the game's Host button fetches every item through
  Steam into the library that owns the PZ install. The shared install unit no
  longer downloads a client host's items: the two paths are independent.

  Note this is the *config* only. A pack whose mods need a JVM agent
  (e.g. ZombieBuddy) also needs that agent installed in the **client**, which is
  a launch-option change outside any NixOS module and is left to the pack's own
  instructions.

- **A Home Manager half, so enabling a client host writes the files itself.** A
  new `homeModules.project-zomboid-servers` (alias `homeModules.default`)
  installs the `clientHosts` files into the client user's `~/Zomboid`, reading
  the pack back off `osConfig.services.project-zomboid-servers.clientHosts` so it
  stays described once and cannot drift from the dedicated server's config.
  Previously every consumer had to hand-write a `home.activation` hook. It now
  needs no path at all: the activation exports only `PZ_CLIENT_ZOMBOID` and runs
  the config-only script. Inert under standalone Home Manager, which has no
  `osConfig`. `services.project-zomboid-servers.home.enable = false` turns it off.

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

- **`nix run .#pz-client-mods -- <pack>` (deprecated) installs local mods.**
  It downloads each Workshop item with `steamcmd` and installs the mod(s) it
  contains as **local mods** in `~/Zomboid/mods` — the one form Project Zomboid's
  client loads with no Steam subscription, per the upstream wiki's "manual local
  installation". The install keys each folder by its `mod.info` `id=`, the same
  id the server's `Mods=` list uses. `--login` is for items that answer
  `Access Denied` anonymously. SteamCMD now runs with an isolated HOME and
  staging directory under `~/.cache/pz-client-mods`, so it cannot read or write
  `~/.local/share/Steam` or rewrite `libraryfolders.vdf`; the old
  `--steam-library` target was removed, because the client does not load library
  bytes until subscribed and pointing steamcmd at a real library was the cause of
  a `libraryfolders.vdf` clobber. Covered by the `pz-client-mods-plan` and
  `pz-client-mods-isolation` checks.

- **A Home Manager option so a client gets the pack's mods declaratively
  (deprecated).** `services.project-zomboid-servers.home.installMods` runs the
  downloader as an idempotent systemd user service at login. It is no longer the
  supported client-host path: the Host flow fetches `WorkshopItems=` through
  Steam, and enabling this option now emits an evaluation warning. It is kept
  only for a client that cannot subscribe, and its steamcmd is isolated from the
  user's Steam tree (see above). `home.steamLogin` covers items that answer
  `Access Denied` anonymously; log in once with
  `HOME=~/.cache/pz-client-mods/home steamcmd +login <account>` because a unit
  has no terminal to prompt on.

### Deprecated

- **`services.project-zomboid-servers.home.installMods`** (client local-mod
  installation). It remains off by default and now emits an evaluation warning
  pointing at the Host flow. Its steamcmd runs with an isolated HOME/staging dir
  under `~/.cache/pz-client-mods`, so it cannot touch the user's Steam library
  registration; `home.steamLogin` follows the same isolated token.
- **`nix run .#pz-client-mods`** is the same escape hatch in CLI form. It still
  installs local mods, but no longer offers a Steam-library target.

### Removed

- **`services.project-zomboid-servers.home.linkSteamWorkshop`.** It symlinked the
  dedicated download into the client's Steam library. The client enumerates
  Workshop mods through Steam's subscription list and never scans that directory,
  so the links were invisible to the game and only added a second directory to
  keep in sync. Set `WorkshopItems=` and let the Host flow fetch the items.
- **`scripts/pz_steam_workshop.py` and the `steam-workshop-discovery` check.**
  They existed only to find the library for that link (and for the removed
  `--steam-library` target).
- **`pz-client-mods --steam-library` / `--home` / `--steam-root`.** Pre-seeding a
  Steam library is inert until the item is subscribed, and pointing steamcmd at a
  real library is what let it rewrite `libraryfolders.vdf`. The downloader now
  writes local mods only.
- **A client host's Workshop ids no longer feed the dedicated install unit.**
  `allWorkshopItems` is the union of enabled dedicated servers only. A client
  host downloads for itself through Steam; the dedicated unit does not fetch on
  its behalf.

### Changed

- **`maxPlayers` is bounded to what Build 42 actually accepts: 1–254.** The
  wiki's "Min: 1 Max: 100" is out of date; the 42.21 server's own generated
  `.ini` says `Min: 1 Max: 254 Default: 32`. The option was a plain `int`, so
  `maxPlayers = 5000` passed evaluation and had no defined effect. It now fails
  the type check, and the description notes that the count excludes admins.

- **`softReset` is documented as rerolling characters, not the world.** It
  clears only PZ's identity keys (`Seed`, `ResetID`, `ServerPlayerID`, …);
  `Saves/` — terrain, constructions, loot — is untouched, and the guide now says
  so. The old text also claimed "the NixOS module clears it once
  `systemd.nixos.reboot` takes effect", which does not exist: a Nix option is
  static, so it is now stated plainly that you must set it back to `false` and
  rebuild. Docs in `options.md`, `installing.md` and `host-recipes.md` follow.

- **The client-host prepare is config-only, and documented as such.** It takes
  only `PZ_CLIENT_ZOMBOID`; `PZ_SERVER_DIR`, `PZ_CLIENT_WORKSHOP` and
  `PZ_LINK_STEAM_WORKSHOP` are gone. `docs/mod-delivery.md` (new) explains the
  three delivery modes and the version-drift consequence. The game's Host flow
  rewrites `~/Zomboid/Server/<name>.ini` and strips `SelfManagedMods=true`; the
  module re-merges on every activation rather than fighting it.
- **The standalone runner gained `--workshop-dir`** and exports
  `PZ_WORKSHOP_DIR`, matching the module's explicit option.

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

- **The dedicated server now reads its per-server `Zomboid` home, not the
  service user's passwd home.** PZ's Java resolves `Zomboid` from `user.home`,
  which the JVM takes from the passwd entry, not from `$HOME`. The launcher set
  `HOME=<dataDir>/<name>` but never `-Duser.home`, so every server on a host
  shared `<dataDir>/Zomboid` and ignored the `<dataDir>/<name>/Zomboid` the prep
  script writes. On the first Viewpoint start that produced a fresh default
  world (`PublicName=My PZ Server`, `MaxPlayers=32`) with RCON off, while the
  real world and its `RCONPassword` sat unread in `viewpoint/Zomboid`. The
  launcher now pins `-Duser.home="$PZ_SERVER_HOME"` ahead of `PZ_JVM_OPTS`,
  while `HOME` stays the data dir so Steam finds its cached login at
  `<dataDir>/.local/share/Steam`; the `launcher` check asserts both.

- **Large Workshop packs no longer cascade "No Connection" or time out on a
  first install.** The install script sent one steamcmd invocation carrying
  every missing `+workshop_download_item` argument. A 438-item pack on a flaky
  link produced a cascade of per-item `No Connection` errors and the 45-minute
  unit timeout killed the install with 101 items left (2026-11-11). Downloads
  are now batched 20 at a time, verified after each pass, and retried up to
  three times with a growing pause; the install/update timeout is 2h.

- **`Mods=` is semicolon-separated, not comma-separated.** Build 42 splits the
  key on `;` only (the game's own `ServerSettingsScreen` joins and splits with
  `";"`), so the comma-joined list the module rendered was read as a single mod
  id. Every boot produced `required mod "<the whole Mods= line>" not found`, no
  mod was loaded, and every `Map=` entry whose folder lives in a mod was then
  `skipping non-existent map folder` — a client host therefore ran a vanilla
  world with no custom maps, no map `objects.lua` (`ZombiesType` zones) and no
  mod spawn points. `renderIniLines`, `pz-workshop resolve` and every doc/skill
  that stated "comma" now say semicolon, and the client-host check rejects a
  comma in the rendered `Mods=`. Build 41 uses semicolons too.

- **Four broken mod ids in the `viewpoint` pack.** `UH` was truncated
  (`UH-1BHelicopter`), `EchoCreek MilitaryBase回音河 军事基地` was the map
  *folder* name rather than the mod id (`EchoCreek MilitaryBase`), and `air`,
  `save` and `game` matched no `mod.info` on either the client or the server
  library. None of them can ever load; they only added noise to the boot.

- **A mod folder with a non-ASCII name no longer aborts mod loading.** Java
  derives its filename encoding from the process locale; under the C locale
  (what a systemd service gets with no `LANG`, and what Steam exports as
  `LC_ALL=C`) the JVM reports `sun.jnu.encoding = ANSI_X3.4-1968`, so
  `Paths.get()` throws `InvalidPathException: Malformed input or input contains
  unmappable characters` for a folder such as `小音庄园XiaoYinEstate`. Three
  Workshop items in the `viewpoint` pack ship one, and in a client host the
  exception terminated the co-op server on every retry. The server unit and the
  standalone runner now export `LANG`/`LC_ALL=C.UTF-8` (`C.UTF-8` is built into
  glibc ≥ 2.35, so no `i18n.supportedLocales` entry is needed), and `module-eval`
  asserts the unit carries it. A client host runs under Steam, whose environment
  the module cannot set — that case is documented in
  [troubleshooting](docs/troubleshooting.md) with the `LC_ALL=en_GB.UTF-8
  %command%` launch option.

- **`SelfManagedMods` is no longer written for Build 42.** The key does not
  exist in 42.21 — it appears nowhere in the game jar (client classes included)
  and is absent from the 144-key `.ini` the server writes back — so a Build 42
  server never read it and PZ dropped it on the next rewrite. It is now rendered
  only when `compatibility.build41` is set, where it is still honoured. The
  client-host check asserts the key is absent and that a re-run still preserves
  world identity and foreign keys.

- **`rconPort` without an `RCONPassword` is reported instead of failing
  silently.** `GameServer` starts RCON only when the port is non-zero **and** the
  password is non-empty (`if (port != 0 && password != null &&
  !password.isEmpty())`), so a port with no secret looked configured and opened
  nothing. `resolveServer` now returns a `warnings` list and the module emits it
  at evaluation time. With a non-zero port and no password, RCON stays off — this
  is a warning, not an error, because the rest of the server is unaffected.

- **The rendered `SandboxVars.lua` had no `VERSION` header, so PZ migrated its
  values.** A missing version reads as 0, and `upgradeOptionValue` then rewrites
  old-build values — `DayLength = 8` (5 hours) becomes the B41-era index 14
  (11 hours), `CarSpawnRate` shifts, and so on. The renderer now writes
  `VERSION = 6` (the 42.21 value) unless `sandbox.VERSION` overrides it. This was
  invisible for the `viewpoint` pack, whose sandbox is empty, and easy to
  misread as harmless because the game rewrites the file after loading.

- **`survival-hard`'s sandbox used keys that do not exist in Build 42, or were
  in the wrong table.** `MeleeWeaponLootNew` is `WeaponLootNew`;
  `ZombieDamage` has no B42 key and is removed; `ZombieRespawn = 4` (the enum is
  `1–4`, so `0` was out of range); and `RedistributeHours`,
  `PopulationStartMultiplier`, `PopulationPeakMultiplier` moved under
  `ZombieConfig.`. The comments now describe what the values actually mean
  (`Zombies = 5` is Low, `DayLength = 8` is 5 hours, `Helicopter = 2` is Once).
  The first two were silently ignored, exactly like a Build 41 key.
  `vanilla-plus`'s `MaximumLooted = -1` was outside the option's 0–200 range;
  it is now `0`, which matches its "unlimited loot" comment (0 = never
  pre-looted).

- **Build 41 keys are rejected instead of silently ignored.** PZ ignores an
  unknown key, so a config copied from a B41 guide starts cleanly and does
  nothing. `lib/default.nix` now carries `staleIniKeys` / `staleSandboxKeys` —
  verified against a generated 42.21 file — and both renderers fail with the
  replacement named (`FoodLoot` → `FoodLootNew`, `MinutesPerPage` →
  `sandbox.MinutesPerPage`, `DisableSafehouseWhenPlayerConnected` →
  `DisableSafehouseWhenOwnerConnected`, …). `render-guards` covers the moves,
  the renames, the two invented spellings and the flat-nested form.

- **A newline in a setting corrupted the file it was written to.** The `.ini`
  format has no escape for a line break, so `settings.ServerWelcomeMessage = "a\nb"`
  produced a second line with no `=` that `merge_ini.py` then dropped — the value
  silently truncated on the next start. A raw newline in a `sandbox` string was
  worse: Lua forbids one inside a short string, so the whole `SandboxVars.lua`
  became a syntax error and PZ regenerated it from defaults, discarding every
  setting in the file. The `.ini` renderer now rejects a line break with an error
  pointing at PZ's `<LINE>` token; the Lua renderer escapes `\n`, `\r`, `\t`,
  `"` and `\`.

- **A reserved key in `settings` silently disagreed with its dedicated option.**
  `settings` is open, but `MaxPlayers`, `Map`, `UPnP` and friends are written by
  the module itself. `settings.MaxPlayers` emitted a second line (the last one
  wins in `merge_ini.py`, so the option and the file diverged), and
  `settings.Map` was overwritten by the value the prep script supplies at every
  start — with no warning. Such keys now fail evaluation, naming the option to
  use instead (`maxPlayers`, `map`, `upnp`, …). `resolveServer` checks the user's
  own `settings`; the renderer checks pack defaults and direct callers.

- **`serverDefaults` was missing `javaAgent`.** The comment above it says every
  field must exist on a `resolveServer` result, and the resolver's
  `inherit (srv) javaAgent` failed with "attribute 'javaAgent' missing" whenever
  the whole value was forced. Added as `null`, matching the option default.

- **`result=9` is reported as a rate limit, not a missing mod.** Exceeding the
  anonymous budget makes Steam answer `result=9` ("busy") with an empty title,
  which is indistinguishable from the item not existing — so `expand` reported
  live mods as "NOT FOUND or removed upstream", advice that sends you to delete
  mods that are perfectly alive. Throttled items are now collected across all
  batches and reported once, naming the ids; a genuinely absent item stays quiet.

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