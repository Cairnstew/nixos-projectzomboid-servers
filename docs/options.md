# Option reference

Every option under `services.project-zomboid-servers`, with its type and
default. **This page is completeness-checked**: the `options-documented` check
fails if `modules/options.nix` declares an option that does not appear here, so
it cannot silently fall behind the module.

Defaults shown are the *declared* defaults. A few resolve from the top level
downwards, which the entries call out.

For what the options are *for*, and the reasoning behind the surprising ones, see
the [README](../README.md) and [host recipes](host-recipes.md).

---

## Top level

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Master switch. |
| `package` | package \| null | `null` | Launcher wrapper. **Filled in by the flake's `nixosModules`** — you should not need to set it. Asserted non-null. |
| `user` | str | `project-zomboid` | Owns the install and runs every server. |
| `group` | str | `project-zomboid` | |
| `dataDir` | path | `/var/lib/project-zomboid` | Each server's `Zomboid` home lives at `<dataDir>/<name>`. **Saves grow without bound** — put this on a large disk. |
| `serverDir` | path | `<dataDir>/server` | Shared SteamCMD install (app 380870). One per host serves every server. |
| `workshopDir` | path | `<serverDir>/steamapps/workshop/content/108600` | **Dedicated-server** Workshop content. Must be absolute and end in `/steamapps/workshop/content/108600`; the module derives the Steam library root to pass to steamcmd. A client host never reads it. |
| `runDir` | path | `/run/project-zomboid-servers` | Console FIFOs. tmpfs, gone on reboot. |
| `steamcmd` | package | `pkgs.steamcmd` | Unfree. |
| `steamRun` | package | `pkgs.steam-run` | Unfree. Supplies the FHS environment the server binary needs. |
| `updateOnStart` | bool | `true` | steamcmd `validate` before each start. First boot fetches the game; later boots are a fast no-op. |
| `updateSchedule` | str \| null | `null` | Also validate on a systemd timer, e.g. `"daily"`. Restarts running servers afterwards. |
| `restartAfterUpdate` | bool | `true` | `try-restart` servers after a timer update, so a stopped one stays stopped. |
| `steamLogin` | str \| null | `null` | Steam account the shared install's downloads authenticate as, for items anonymous cannot fetch (e.g. Brita's Armor Pack). Token cached under `dataDir`; log in once interactively. See [Steam login](#steam-login). |
| `prune` | bool | `false` | Remove dedicated Workshop content no enabled server declares, and unlink a server's stale mod symlinks. Off because it **deletes** from the shared install; on for a clean pack switch. See [Prune](#prune). |
| `failOnMissingMods` | bool | `true` | Refuse to finish the install when a Workshop item cannot be downloaded, vs. `false` = log-and-skip so the servers boot without it. See [Steam login and private mods](#steam-login-and-private-mods). |
| `modpacks` | attrsOf submodule | `{}` | Map the catalogue in. See [modpacks](#modpacksname). |
| `servers` | attrsOf submodule | `{}` | See [servers.<name>](#serversname). |
| `managementSystem` | submodule | `{ systemd-socket.enable = true; }` | Default console backend. See [managementSystem](#managementsystem). |
| `startLimitIntervalSec` | int | `120` | Crash-loop window. |
| `startLimitBurst` | int | `5` | Restarts allowed in that window. |
| `webConsoleUpstreams` | listOf submodule | *(read-only)* | Derived. See [webConsoleUpstreams](#webconsoleupstreams). |
| `clientHosts` | attrsOf submodule | *(read-only)* | Derived from `servers.<name>.clientHost.enable`. See [clientHosts](#clienthosts). |
| `web` | submodule | disabled | See [web](#web). |
| `manage` | submodule | disabled | Dashboard + JSON API. See [manage](#manage). |
| `backup` | submodule | disabled | Scheduled archives. See [backup](#backup). |

### `managementSystem`

PZ reads server commands from **stdin**, so a console is fundamentally an fd 0.
Exactly one backend may be enabled (asserted).

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `systemd-socket.enable` | bool | `true` | A `.socket` unit with `ListenFIFO` owns the fd. Recommended: correct ownership and mode for free, and `systemctl stop` works by writing `quit` down the FIFO. |
| `tmux.enable` | bool | `false` | A detached tmux session. Attach with `tmux -S /run/project-zomboid-servers/<name>.sock attach`. |
| `tmux.socketPath` | name → path | `name: "/run/project-zomboid-servers/<name>.sock"` | Receives the server's attribute name. |

### `web`

ttyd consoles. Off by default, and `openFirewall` inside it is *also* off by
default: consoles are meant to sit behind a proxy, on loopback.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `web.enable` | bool | `false` | Master switch for web consoles. |
| `web.portBase` | port | `7682` | First auto-assigned console port. Starts at 7682 because 7681 is conventionally another ttyd's. |
| `web.bind` | str | `127.0.0.1` | Interface. Loopback by default; expose via a proxy or tailnet IP. |
| `web.user` | str | `project-zomboid-web` | Added to the server group, with a scoped polkit rule for `manage-units` on the `project-zomboid-*` units only (not sudoers). |
| `web.username` | str \| null | `null` | HTTP basic auth. Requires `passwordFile`. The password is passed to ttyd with `--credential`, so it is visible in the process list; prefer proxy auth where that matters. |
| `web.passwordFile` | path \| null | `null` | e.g. an agenix secret. |
| `web.openFirewall` | bool | `false` | Opens the console ports. Off: put an authenticating proxy in front instead. Without `username`/`passwordFile` the consoles have no authentication of their own. |

### `manage`

The `pz-manage` dashboard: a small Python service (stdlib only) that reads
systemd and RCON, performs a fixed allow-list of transient actions, and renders
the effective Nix config read-only. It never writes `viewpoint.ini`,
`_SandboxVars.lua`, `Mods=` or `WorkshopItems=` — those are re-applied on every
start, so a web editor for them would be a lie.

The UI is served at `/` (put it behind a proxy at `/pz-admin/`), and the JSON
API is documented in `modules/manage/server.py`. It binds loopback by default:
RCON is plaintext and the service has no user database, so authentication is a
property of the proxy or the private network, not of this module.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `manage.enable` | bool | `false` | Run the dashboard and API. |
| `manage.bind` | str | `127.0.0.1` | Interface. Keep it on loopback and proxy it. |
| `manage.port` | port | `27080` | Loopback TCP port. |
| `manage.user` | str \| null | `null` | `null` = `web.user`. The user must be in `group` and gets the same scoped polkit rule. |
| `manage.title` | str | `Project Zomboid` | Dashboard heading. |
| `manage.consoleBase` | str | `/pz` | Console URL prefix, only for the link the dashboard renders. |
| `manage.refreshSeconds` | int | `5` | Status/players/log refresh interval. |
| `manage.allowActions` | listOf enum | all verbs | `save`, `broadcast`, `kick`, `ban`, `unban`, `whitelist-add`, `whitelist-remove`, `reload-options`, `start`, `stop`, `restart`. Each maps to one fixed RCON command or systemctl verb — there is no raw RCON terminal. |
| `manage.openFirewall` | bool | `false` | Opens `manage.port`. The dashboard has no authentication of its own; keep it on loopback or behind a proxy/tailnet. |

### `backup`

Scheduled `tar --zstd` archives of each server's `Zomboid/{Saves,db,Server,Lua}`.
The Steam token under `.local/share/Steam` is deliberately excluded, but
`Zomboid/Server` contains the merged `.ini` and therefore the RCON and join
passwords: treat archives as secret material. They are created mode `0640` in a
`0770` directory so the dashboard's group can read them; encrypt any copy that
leaves the host. Restore is a CLI (`project-zomboid-restore`), not an HTTP
action: it refuses while the unit is active, validates archive members, takes a
safety archive first, and runs as the server user (use `sudo` for the
stop/start).

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `backup.enable` | bool | `false` | Run the timer and install `project-zomboid-restore`. |
| `backup.directory` | str \| null | `null` | `null` = `<dataDir>/backups`; one subdirectory per server. Created with `0770 <user>:<group>`. |
| `backup.keep` | int | `7` | Archives kept per server. `0` disables pruning. |
| `backup.schedule` | str | `daily` | systemd `OnCalendar`, e.g. `*-*-* 04:30:00`. |
| `backup.randomDelaySec` | int | `1800` | Random delay added to the timer. |

### `webConsoleUpstreams`

**Read-only**, derived from the servers with `webConsole = true`. This project
deliberately does not wire the consoles into any particular reverse-proxy module —
a standalone flake cannot depend on your private option namespace. Map it into
whatever you use:

```nix
proxy.upstreams = lib.mkMerge (map (u: {
  ${u.name} = {
    inherit (u) port path stripPrefix displayName;
  };
}) config.services.project-zomboid-servers.webConsoleUpstreams);
```

Each element has to be a **dynamic key**. `mkMerge` on an `attrsOf` option merges
the list's attrsets together as the option's value, so the mapping must produce
`{ "<name>" = { … }; }`. Two plausible-looking alternatives compile and register
nothing at all, which is the worst kind of failure here because the console
still works — it is just not reachable through the proxy:

```nix
# WRONG: `port`, `path` and `name` become top-level KEYS of `upstreams`,
# and the real entry never appears. Check with:
#   builtins.attrNames config.<your>.proxy.upstreams
#   → [ "displayName" "name" "path" "port" "stripPrefix" ]
lib.mkMerge (map (u: { inherit (u) port path stripPrefix displayName; name = u.name; }) …)

# ALSO WRONG: nameValuePair yields `{ name = …; value = …; }`, not a dynamic key.
lib.mkMerge (map (u: lib.nameValuePair u.name { … }) …)
```

If your proxy option is a **list** rather than `attrsOf`, the first (wrong) form
is the right one — key the shape off the option's type.

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `name` | str | — | Suggested upstream name, unique per server. |
| `port` | port | — | Loopback port the console listens on. |
| `path` | str | — | URL prefix, trailing slash. Defaults to `/pz/<name>/`. |
| `stripPrefix` | bool | `true` | ttyd requires this. |
| `displayName` | str | `""` | Label for proxy UIs. The module always populates it — `mkProxyUpstreams` sets `Project Zomboid console: <name>`. |

### `clientHosts`

READ-ONLY. One entry per server with `clientHost.enable = true`. **Independent of
`enable`** — see [clientHost](#clienthost).

A Project Zomboid world can be run two ways: as a dedicated server (the systemd
units this module creates) or from the game's own **Host** button, which runs the
server inside the client's process. Both read the same `<name>.ini`, the same
`<name>_SandboxVars.lua` and the same mod list. This option renders the *client*
half of that from the same pack, so the mod list is written down once and cannot
drift between the two hosts.

Nothing is installed by the NixOS module: `~/Zomboid` is a user-level path a
system module cannot own. The flake's **Home Manager** module installs it — see
[Home Manager](#home-manager).

| Field | Type | Notes |
| --- | --- | --- |
| `serverName` | str | The client-side name — the `<name>.ini` basename and the save folder. |
| `prepare` | path | A runnable, **config-only** script: `PZ_CLIENT_ZOMBOID=~/Zomboid /nix/store/…-client-host`. It writes `Server/<name>.ini` and `Server/<name>_SandboxVars.lua`, plus — when `clientHost.preset.enable` is set — one merged preset line in `Lua/pz_modlist_settings.cfg`. It never runs steamcmd and never references a Steam library. |
| `iniFile` | path | The Nix-rendered base `.ini`, *before* the merge. Hand this to `prepare`; installing it directly would overwrite `Seed`/`ServerPlayerID` on an existing world. |
| `sandboxFile` | path | The Nix-rendered `<name>_SandboxVars.lua`. |
| `mods` | listOf str | The resolved `Mods=` list. |
| `workshopItems` | listOf str | The resolved `WorkshopItems=` list (Steam Workshop ids). |
| `presetName` | str \| null | The effective preset name, or `null` when `clientHost.preset.enable` is off. |
| `presetFile` | path \| null | The Nix-rendered single-line preset fragment (`<name>:id;id;…;`), or `null`. `prepare` merges it; installing it directly would drop the player's other presets. |

```nix
# In the client user's Home Manager configuration — nothing else is needed, and
# no path has to be written down:
imports = [ inputs.project-zomboid-servers.homeModules.default ];
```

Behaviours worth knowing:

- The `.ini` is **merged, not rewritten**, so `Seed`, `ServerPlayerID` and
  `LastModified` survive — the same reason the dedicated server merges. Re-running
  is safe.
- Named keys come from the server's resolved settings, so a server defined with
  `public = true` will **overwrite** a client-side `Public=false` in that file.
  Override it in `settings` if the client host should stay private.
- The game's Host screen rewrites `<name>.ini` and drops every key it does not
  know. Re-running the merge re-applies the declared keys while `Seed`,
  `ServerPlayerID` and the rest of the world identity survive, so repeated
  activations are safe. `SelfManagedMods` is not written for Build 42 at all —
  the key does not exist in 42.21.
- No mods are installed, linked or copied by this half. With
  `WorkshopItems=` populated, the Host button fetches everything through Steam
  into the library that owns the PZ install, before it reads `~/Zomboid/mods`.
  See [mod delivery](mod-delivery.md).
- When `clientHost.preset.enable` is set, `prepare` also **merges** one named
  preset into `~/Zomboid/Lua/pz_modlist_settings.cfg`. The preset lists the
  pack's ordered `mods`, and exists because the Host flow's server-side `Mods=`
  does not enable the client's own mods outside a hosted world. The merge keeps
  the player's other presets and favourites; re-running never duplicates the
  managed line.
- Project Zomboid **re-orders a preset when it is applied**, using each mod's
  `mod.info` `require=` only (`ModSelector.Model:correctAndSaveModOrder`). The
  order written here is the pack order and is useful for sharing, but it is not
  a promise. Mods that are not downloaded are listed by the game's “missed
  mods” window and simply left off.

---

## Home Manager

The flake exports the other half of the module as
`inputs.project-zomboid-servers.homeModules.default`. It writes the files
`clientHosts` describes into the client user's `~/Zomboid`, so enabling a client
host is enough — no `home.activation` hook, and no path written down anywhere.

The pack is read back from `osConfig`, so the mod list, SandboxVars and
client-side server name stay described exactly once, on the NixOS side, and
cannot drift from what the dedicated server would have run. Under **standalone**
Home Manager there is no `osConfig`, and the module is inert rather than an
error.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `services.project-zomboid-servers.home.enable` | bool | on exactly when `osConfig` has `clientHosts` | Set `false` to keep the pack rendered but write nothing. |
| `services.project-zomboid-servers.home.installMods` | bool | `false` | **Deprecated.** Fetch the pack's Workshop items and install them as **local mods** in `~/Zomboid/mods`. Isolated from Steam (own HOME/staging under `~/.cache/pz-client-mods`); it cannot write `libraryfolders.vdf`. |
| `services.project-zomboid-servers.home.steamLogin` | str \| null | `null` | Steam account for the deprecated fetch, for items that answer `Access Denied` anonymously. Log in once with `HOME=~/.cache/pz-client-mods/home steamcmd +login <account>`. |

**The link-sharing option is gone.** `home.linkSteamWorkshop` used to symlink the
dedicated download into the client's Steam library. It was removed because the
client enumerates Workshop mods through Steam's subscription list and never
scans that directory, so the links were invisible to the game. Set
`WorkshopItems=` (which the pack already does) and let the Host flow fetch the
items.

**Subscribing cannot be automated.** Steam has no public write API for
subscriptions, `steamcmd` has no subscribe command, and the client's
`appworkshop_<appid>.acf` carries no `subscribed` flag. `home.installMods` is
therefore a deprecated local-mods escape hatch, not the supported client path.
A pack's non-Workshop `mods` cannot be downloaded and are reported for manual
placement.

---

## `modpacks.<name>`

This module ships **no** modpacks. The catalogue is a flake output
(`inputs.project-zomboid-servers.modpacks`) so packs can be versioned
independently of your configuration.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `description` | str | `""` | Human-readable summary. |
| `workshopMods` | listOf submodule | `[]` | Steam Workshop items. Order is preserved and becomes `WorkshopItems=`. |
| `workshopMods.*.id` | str | — | Numeric id **as a string**, e.g. `"2625441155"`. |
| `workshopMods.*.title` | str \| null | `null` | Cosmetic; for humans reading the pack. |
| `mods` | listOf str | `[]` | Local mod **folder** names — the `id=` values from each mod's `mod.info`, *not* Workshop ids. |
| `defaultSettings` | attrs | `{}` | `.ini` keys any server using this pack inherits. A server's own `settings` wins. |
| `defaultSandbox` | attrs | `{}` | Same, for SandboxVars. |

Two separators matter here, and mixing them up is a reliable source of silent
misconfiguration:

- `WorkshopItems=` — **semicolon** separated
- `Mods=` — **semicolon** separated
- `Map=` — **semicolon** separated

---

## `servers.<name>`

Each enabled server becomes a `project-zomboid-<name>` service and, by default,
a matching `.socket` for its console.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `enable` | bool | `true` | `false` generates no unit and leaves data untouched. |
| `name` | str | the attribute name | Determines `<name>.ini`, `<name>_SandboxVars.lua` and the save folder. |
| `description` | str | `""` | Falls back to the modpack's. |
| `modpack` | str \| null | `null` | Inline `workshopMods`/`mods` are **appended** to the pack's, not substituted. |
| `workshopMods` | listOf submodule | `[]` | Extra Workshop mods, on top of the pack's. Same shape as `modpacks.<name>.workshopMods`. |
| `mods` | listOf str | `[]` | Extra local folder names, on top of the pack's. |
| `localMods` | attrsOf path | `{}` | Non-Workshop mods as `folder-name = directory`. Symlinked into `Zomboid/mods` and added to `Mods=` — the fallback for a mod that cannot be downloaded (private/mature-gated Workshop item, or modworkshop.net). See [Private mods](#private-mods-and-steam-login). |
| `map` | str \| null | `null` | `null` = **derive** from installed mods. Semicolon separated. See [Maps](#maps). |
| `baseMap` | str | `Muldraugh, KY` | The vanilla map, always placed **last**. |
| `mapOrder` | submodule | `{}` | See [mapOrder](#maporder). |
| `spawn` | submodule | `{}` | See [spawn](#spawn). |
| `defaultPort` | port | `16261` | `DefaultPort`, UDP. Must be unique across enabled servers. |
| `udpPort` | port | `16262` | `UDPPort`, UDP. PZ binds **two** UDP ports per instance; both must be unique. |
| `rconPort` | port | `0` | `0` = RCON off. A port alone is not enough: PZ starts RCON only when `RCONPassword` (via `secretFiles`) is non-empty too, and warns at eval time otherwise. |
| `openRconFirewall` | bool | `false` | Opens `rconPort`. Off by default: RCON is plaintext TCP, and the dashboard/idle-stop read it over loopback. Set only for an external RCON client, preferably behind a restricted rule. |
| `openFirewall` | bool | `false` | Opens this server's two UDP ports. |
| `public` | bool \| null | `null` | Server browser. `null` = true. |
| `publicName` | str \| null | `null` | Browser name. `null` = the attribute name. |
| `maxPlayers` | int (1–254) | `32` | Excludes admins. PZ warns above 32; the 42.21 build caps it at 254. |
| `settings` | attrs | `{}` | Free-form `.ini` keys. **Never a secret**; module-owned keys are rejected — see [reserved keys](#reserved-keys-in-settings). |
| `sandbox` | attrs | `{}` | SandboxVars. Nested B42 tables use dotted keys — see [nested keys](#nested-sandboxvars-keys). **Never a secret.** |
| `open` | bool \| null | `null` | `null` = true. `false` requires a populated `whitelist`. |
| `whitelist` | listOf str | `[]` | **Build 41 only.** |
| `admins` | listOf str | `[]` | **Build 41 only.** Grants in-game rights; never creates the login. |
| `compatibility.build41` | bool | `false` | Re-enables `Whitelist=` / `Users=`. |
| `adminAccount` | submodule \| null | `null` | Creates the Build 42 admin login. |
| `secretFiles` | attrsOf path | `{}` | `Key = path`. The only way to set a secret. |
| `passwordFile` | path \| null | `null` | Sugar for `secretFiles.Password`. Wins if both are set. |
| `extraArgs` | listOf str | `[]` | Appended to the command line. **Never a credential** — it lands in a world-readable unit. |
| `upnp` | bool | `false` | `UPnP=`. **Build 41 only** — Build 42 has no UPnP implementation, so the resolver warns and the router is never touched. PZ defaults this **true**; see [below](#two-defaults-that-differ-from-pz). |
| `selfManagedMods` | bool | `true` | **Build 41 only.** Stops PZ rewriting `Mods=`. The key does not exist in 42.21, so nothing is rendered for Build 42. |
| `softReset` | bool | `false` | Discard world identity so clients reroll characters. **The map is kept** — see [softReset](#softreset). Destructive. |
| `betaBranch` | str \| null | `null` | e.g. `"legacy41"`. Per-server, but applied by the **shared** install, so set it on every server or none. |
| `jvmOpts` | str | `-Xmx4G -Xms2G` | Placed **before the `--`** the launcher inserts, which is what routes flags to the JVM rather than to the game. The only way to set the heap. |
| `javaAgent` | submodule \| null | `null` | `{ jar, args }` — a JVM agent (e.g. ZombieBuddy) prepended to `jvmOpts`. A headless server **must** set a non-prompting policy. |
| `autoStart` | bool | `true` | Start at boot. Independent of `schedule.start`; set `false` for schedule-only uptime. |
| `schedule` | submodule | `{}` | Scheduled start times. See [schedule](#schedule). |
| `idleStop` | submodule | disabled | Stop after a period with no players. See [idleStop](#idlestop). |
| `restart` | str | `"always"` | See [below](#why-restart-is-always). |
| `managementSystem` | submodule | inherits top level | Override per server to mix backends. |
| `hardware` | submodule | `{}` | See [hardware](#hardware). |
| `extraServiceConfig` | attrs | `{}` | Extra `serviceConfig`. Avoid sandboxing directives that break `steam-run`'s user-namespace FHS. |
| `webConsole` | bool | `true` | Needs `web.enable`. |
| `port` | port \| null | `null` | Web console port; `null` assigns from `web.portBase` in sorted server order. |
| `clientHost` | submodule | disabled | Render files for the game's in-game **Host** button from this same pack. See [clientHost](#clienthost). |

### `schedule`

A systemd timer that starts the server at each `OnCalendar` expression. It does
**not** stop the server; use `idleStop` or `systemctl stop`.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `schedule.start` | listOf str | `[]` | systemd `OnCalendar` expressions, e.g. `[ "*-*-* 22:00:00" ]`. Empty = no timer. |
| `schedule.persistent` | bool | `false` | Start late if the host was off at the scheduled time. Off by default: a game server starting during boot is usually worse than waiting. |

`autoStart` and `schedule.start` are independent. For a server that should only
be up in the evening, set both `autoStart = false` and a start schedule:

```nix
servers.main = {
  autoStart = false;
  schedule.start = [ "*-*-* 22:00:00" ];
};
```

### `idleStop`

A once-a-minute timer that stops the server after it has been empty for
`idleStop.timeout`. **Requires RCON** (`rconPort` + `secretFiles.RCONPassword`);
evaluation fails otherwise. The check is conservative: an unreachable RCON is
not treated as empty, and the player count is re-queried immediately before the
stop so a just-joined player is not kicked.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `idleStop.enable` | bool | `false` | Run the idle-shutdown timer. |
| `idleStop.timeout` | str | `"30m"` | One number and one unit: `90s`, `30m`, `2h`, `1d`. |

```nix
servers.main = {
  rconPort = 27017;
  secretFiles.RCONPassword = config.age.secrets.pz-rcon.path;
  idleStop = {
    enable = true;
    timeout = "30m";
  };
};
```

`PauseEmpty = true` is a separate Project Zomboid setting: it freezes the world
clock while nobody is online. It is not a substitute for `idleStop` — the JVM
still runs — but the two compose well. Set it through `settings` (the
`viewpoint` and `vanilla-plus` packs already do):

```nix
settings.PauseEmpty = true;
```

### Reserved keys in `settings`

`settings` is deliberately open — any Build 42 `.ini` key can be set without this
module enumerating PZ's ~150 of them. But a handful of keys are **not** free-form:
each has a dedicated option, or is rendered by the module itself. Setting one in
`settings` is an evaluation error rather than a silently duplicated line:

| Key | Use instead |
| --- | --- |
| `DefaultPort` | `defaultPort` |
| `UDPPort` | `udpPort` |
| `RCONPort` | `rconPort` |
| `Public` | `public` |
| `PublicName` | `publicName` |
| `MaxPlayers` | `maxPlayers` |
| `Open` | `open` |
| `Map` | `map`, or leave it unset to derive from the installed mods |
| `Mods` | the pack's `mods`, or the server's `localMods` |
| `WorkshopItems` | the pack's / server's `workshopMods` |
| `UPnP` | `upnp` |
| `SelfManagedMods` | `selfManagedMods` |
| `Whitelist` | `whitelist` (`compatibility.build41`) |
| `Users` | `admins` (`compatibility.build41`) |

`Map` gets the strongest version of this guard: the prep script always supplies
the effective value at start, so a `settings.Map` would be overwritten on every
boot with no warning at all.

Values are rendered verbatim, and **a newline is rejected** in an `.ini` value —
the format has no escape for one. Use PZ's literal `<LINE>` token for the keys
that support line breaks (`ServerWelcomeMessage`, `PublicDescription`). In
`sandbox`, a newline inside a Lua string is escaped to `\n` rather than emitted
raw, because a raw newline would make the whole file a syntax error.

### Build 41 keys in a Build 42 config

PZ **ignores an unknown key silently** — the server starts cleanly and the
setting simply does nothing. A config copied from a Build 41 guide is therefore
the worst kind of wrong. The renderers reject known B41 names and name the
replacement:

| B41 key | Build 42 |
| --- | --- |
| `FoodLoot`, `CannedFoodLoot`, `MedicalLoot`, `MechanicsLoot`, … | `*LootNew` (a `0.00`–`4.00` multiplier, not a `1`–`5` enum) |
| `WeaponLoot`, `RangedWeaponLoot`, `AmmoLoot` | `WeaponLootNew`, `RangedWeaponLootNew`, `AmmoLootNew` |
| `FuelStationGas` | `FuelStationGasMin` / `FuelStationGasMax` / `FuelStationGasEmptyChance` |
| `LootRespawn` | `HoursForLootRespawn` / `SeenHoursPreventLootRespawn` / `MaxItemsForLootRespawn` |
| `MinutesPerPage`, `HoursForLootRespawn`, `ConstructionPreventsLootRespawn` | these moved to `sandbox` |
| `DisableSafehouseWhenPlayerConnected` | `DisableSafehouseWhenOwnerConnected` |
| `DiscordChannel` / `DiscordChannelID` | `DiscordChatChannel` (also `DiscordLogChannel`, `DiscordCommandChannel`) |

The full table is `staleIniKeys` / `staleSandboxKeys` in `lib/default.nix`; every
entry was checked against a generated 42.21 file. B41-only keys with no
replacement (`SteamPort1`/`SteamPort2`, `UPnPLeaseTime`, `PlayerSaveOnDamage`,
`SaveTransactionID`, `VoiceSampleRate`, …) fail with "removed in Build 42".

### Nested SandboxVars keys

Build 42 moved several groups into nested Lua tables: `ZombieLore`,
`ZombieConfig`, `MultiplierConfig` (skill XP rates), `Map` and `Basement`. The
server registers them by dotted name (`ZombieConfig.PopulationStartMultiplier`),
so a **flat** key is an unknown option and is silently ignored. Write them with
a dotted key:

```nix
sandbox = {
  Zombies = 5;
  "ZombieConfig.PopulationStartMultiplier" = 1.5;
  "ZombieConfig.PopulationPeakMultiplier" = 2.0;
  "ZombieLore.Speed" = 2;
};
```

A flat `PopulationStartMultiplier` / `Speed` is an evaluation error naming the
dotted spelling. The table is rendered as a real nested Lua table.

One name is ambiguous: `Farming` flat is the farming-speed enum; the skill XP
multiplier is `"MultiplierConfig.Farming"`. The table of known keys is
`nestedSandboxTables` in `lib/default.nix` (from the 42.21 `SandboxOptions`
classes, cross-checked against a generated `SandboxVars.lua`); a dotted key with
an unknown table or short name is rejected.

The renderer always writes the version header (`VERSION = 6` for 42.21). It is
**not** optional: a file without it is read as version 0, and PZ then runs its
old-build value migrations — `DayLength = 8` (5 hours) becomes the B41-era index
14 (11 hours). Set `sandbox.VERSION` only if you are targeting an older build.

### `softReset`

**It rerolls characters; it does not regenerate the world.** The option clears
PZ's identity keys (`Seed`, `ResetID`, `ServerPlayerID`, …), so clients are told
their character belongs elsewhere and create a new one. `Saves/` is untouched:
terrain, constructions, loot and vehicles all persist, and the old save is still
there if you flip the option back.

PZ's own `Seed` comment says a genuinely new map also needs `map_worldgen.bin`
deleted from the save directory. This option deliberately does not do that — a
declarative switch that silently destroys a world is a bad trade. Move
`Saves/Multiplayer/<name>/` aside by hand if that is what you want.

### `clientHost`

Render this pack's config for the game's own **Host** button, i.e. a world hosted
from inside a client rather than as a dedicated server. The result is exposed as
[`clientHosts`](#clienthosts); this module never installs it.

**Deliberately independent of `enable`.** `enable` decides whether a dedicated
server exists on this host; a client host is a different way to run the same
world, and the common case is exactly the one where `enable = false` — a player's
own machine, where the pack drives the Host screen and no dedicated server is
installed at all.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Produce a `clientHosts.<attr>` entry. |
| `name` | str | `"servertest"` | The client-side server name. PZ names both `<name>.ini` and `Saves/Multiplayer/<name>` after it — so changing it makes a **new world** rather than reusing the existing one. `servertest` is what the Host screen uses by default. |
| `preset.enable` | bool | `false` | Merge one managed preset into `~/Zomboid/Lua/pz_modlist_settings.cfg`. It lists the pack's ordered `mods` so the client's own Mods menu can enable them outside a hosted world. It does **not** replace the Host flow's server-side `Mods=`. |
| `preset.name` | str | `""` | Preset name in the Mods menu. Empty means the server attribute name (`viewpoint`). A name containing `:`, `;`, `\` or a newline is rejected. |
| `openFirewall` | bool | `false` | Open `defaultPort`/`udpPort` for this client host. The server-level `openFirewall` cannot: it is fed from the enabled servers, and a client host normally has `enable = false`. Opening the ports is necessary but not sufficient behind NAT — see [troubleshooting](troubleshooting.md#a-friend-cannot-join-a-client-host). |

The `.ini` is merged rather than rewritten (see
[`clientHosts`](#clienthosts)), and the mods are delivered by the Host flow:
the game fetches `WorkshopItems=` through Steam, into the library that owns the
PZ install. This module does not install, copy or link mods for the client. Note
that the client half of a Java-mod pack needs its JVM agent installed **in the
client**, which is a launch-option (or `ProjectZomboid64.json`) change outside
this module — see the pack's own instructions.

`clientHost.preset.enable` is the one extra: it writes a **preset** into the
client's Mods menu listing the pack's ordered mods, so the client-side half
(Viewpoint's own code, UI mods, …) can be enabled outside a hosted world. The
Host flow's `Mods=` only covers the session the server runs; the client's own
list is a separate setting. The preset is merged into the existing file, so the
player's own presets and favourites survive. See
[mod delivery](mod-delivery.md#client-side-mod-preset).

**This renders even with `enable = false`.** A client host is not a dedicated
server, so the master switch off means no install unit, no steamcmd and no
`project-zomboid` user — just the two config files.

### Maps

`Map=` is the one setting that **cannot** be written down statically. A map
exists only if some installed mod ships `media/maps/<name>/`, and which mods are
installed is not known until `steamcmd` has run. So `map = null` — the default —
means *derive it*, at start, from what is actually on disk.

The order is load-bearing. PZ resolves `media/maps/<name>` across **every** loaded
mod, so when two mods ship the same map name the winner is whichever the mod
loader reaches first — which depends on download order. Non-deterministic, and
silently so: the server starts fine and the wrong tiles load.

So the sort key is **total**, and every component is a stable comparison of data
we control:

1. mod maps first, by `(priority, kind, numeric id, mod id, map name)`
2. the `baseMap` **last**, always

Base map last is deliberate: mod maps add new areas rather than patching vanilla
tiles, so letting the base map resolve last means any genuine overlap goes in
favour of vanilla — the direction that cannot corrupt terrain players already
know. A mod shipping the base map's own name is an **error**, because it shadows
vanilla terrain.

```console
$ nix run .#pz-maps -- --workshop-root ./server/steamapps/workshop/content/108600 \
    --base-map "Muldraugh, KY" --explain
pz-maps: warning: map 'West Point, KY' is shipped by 2 mods
  using: workshop mod 200
  ignored: workshop mod 300
pz-maps: ordering:
  Louisville, KY: from workshop mod 100 (rank (0, 0, 100, '100', ...))
  West Point, KY: from workshop mod 200 (rank (0, 0, 200, '200', ...))
  Muldraugh, KY: base map, always ordered last
Louisville, KY;West Point, KY;Muldraugh, KY
```

Also available as `pz-dedicated-server --list-maps`, which is the thing to reach
for when a mod is not showing up on the map.

#### `mapOrder`

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `enable` | bool | `true` | Forced off when `map` is set — an explicit value wins outright. |
| `priority` | listOf str | `[]` | Mod ids that win duplicate-map clashes and order first, in order. |
| `strict` | bool | `false` | Refuse to start on any clash. For CI, or once a pack is known clean. |
| `dedupe` | bool | `false` | Rename losers to `*.pz-duplicate`. **Writes to the shared install**, so off by default; recoverable by renaming back. |

Set `map` explicitly to pin the list and turn detection off — which you must do
if you want a map no mod ships.

For context: the most popular server-config editor for the game, Workshop item
2725216703 ("Mod Manager: Server", ~1.4M subscribers), documents that it
explicitly does *not* manage maps or spawn regions, leaving them to hand-editing.
Deriving them is most of what this module does that a GUI cannot.

### `spawn`

`<server>_spawnpoints.lua` and `<server>_spawnregions.lua` are two of the four
files PZ lists as necessary for a server to work. Both are generated by PZ when
absent, so they are written only when non-empty and **removed** when emptied —
otherwise dropping the option would silently do nothing to a running server.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `spawn.points` | listOf submodule | `[]` | Extra spawn points, grouped by profession. |
| `spawn.points.*.pos` | listOf int | `[ 0 0 0 ]` | World `[ x y z ]`. |
| `spawn.points.*.profession` | str | `"unemployed"` | Points are grouped by this key. |
| `spawn.regions` | listOf submodule | `[]` | Rendered in the order given. |
| `spawn.regions.*.name` | str | — | Region name as PZ shows it. |
| `spawn.regions.*.file` | str | — | Path to the region's `spawnpoints.lua`, relative to the install — the same form PZ's own file uses. |

`pos` is a coordinate triple. So, for the avoidance of doubt, is PZ's own
`SpawnPoint=` ini key: `SpawnPoint=0,0,0` is the world origin, not a preset and
not an index. Profession keys are emitted bare when they are valid Lua
identifiers — matching PZ's own generated file — and bracket-quoted otherwise.

### `adminAccount`

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `username` | str | — | Steam account name to create or update as a server admin. |
| `passwordFile` | path | — | Required. There is deliberately **no way to give the password inline**. |

Build 42 has **no `.ini` key** for the admin login: it is a row in
`Zomboid/db/<servername>.db`, and the only supported way to write it is the
`-adminusername` / `-adminpassword` command-line pair. This option passes them.

**Known limitation:** a process argument is visible in `ps` for the lifetime of
the server. PZ offers no alternative and every other deployment shares the
exposure — but the password is at least read from a file rather than baked into
the unit, so it never reaches `systemctl cat` or the Nix store.

### `hardware`

cgroup caps and scheduler niceness for the unit. All `null` = no cap.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `memoryMax` | str \| null | `null` | systemd `MemoryMax` — hard cap; the unit is OOM-killed above it. |
| `memoryHigh` | str \| null | `null` | `MemoryHigh` — soft throttle target. |
| `memorySwapMax` | str \| null | `null` | `MemorySwapMax`. |
| `cpuQuota` | str \| null | `null` | `CPUQuota` — percentage of one core, e.g. `"200%"`. |
| `nice` | int \| null | `null` | systemd `Nice`. |
| `ioWeight` | int \| null | `null` | `IOWeight`, 1–10000. |

`jvmOpts` and `hardware.memoryMax` are two different caps and both are worth
setting: the JVM heap is what `-Xmx` bounds, and `memoryMax` is what stops a JVM
that decides otherwise from taking the host down with it.

---

## Steam login and private mods

Anonymous `steamcmd` can download most Project Zomboid Workshop items but not
all: an item behind Steam's mature-content check, or restricted by its author,
answers `Access Denied` / `File Not Found`. Brita's Armor Pack is the known
example. `steamLogin` fixes it — the install then logs in as an account that
*owns Project Zomboid* (with mature content enabled).

The password is never stored. SteamCMD caches a login token under `HOME`, and
the install runs with `HOME = <dataDir>`, so log in once as the server user:

```bash
sudo -u project-zomboid env HOME=/var/lib/project-zomboid steamcmd +login <account>
```

One interactive command answers the password and Steam Guard prompts; every
later non-interactive run reuses the token. A missing or expired token simply
fails the install, loudly, listing each item that could not be fetched — never
a silent start with mods missing.

Prefer a degraded-but-up server over no server? Set `failOnMissingMods = false`
(standalone: `--lenient`). The missing items are **logged with the reason and
skipped**, the install reports success, and the servers boot without them —
PZ warns about the missing content at start, and a later install fetches the
items the moment they become fetchable, with nothing re-declared.

For an item that still cannot be fetched (the author disabled downloads
entirely), install it as a **local mod**: obtain the mod folder (e.g. from a
subscribed client), point `servers.<name>.localMods` at it, and it is symlinked
into the server's `Zomboid/mods` and named in `Mods=` automatically:

```nix
services.project-zomboid-servers.servers.main.localMods = {
  BritasArmorPack = /srv/mods/BritasArmorPack;   # folder containing mod.info
};
```

The key is the mod's `id=` (the same string `Mods=` takes), and only symlinks
the module created are ever removed, so a hand-placed directory is safe.

## Prune

Every install and prep step is *additive* — nothing ever subtracts. Switch a
server from one pack to another and the shared download keeps every mod any
pack ever asked for, and the server's `Zomboid/Workshop/content/108600` keeps a
symlink for every mod it ever declared. Neither is merely disk use: `Map=` is
derived by scanning the shared workshop root, so a map from a removed mod keeps
being injected into the server config.

`prune = true` makes the config the truth:

- `workshopDir` is reduced to the union of every enabled server's
  `workshopItems`; and
- each server's workshop link farm is reduced to its own list, and its
  `Zomboid/mods` farm to its `localMods`.

Client hosts are not part of either set: they do not read this directory and do
not get a link farm.

Prune runs only after every declared item has verified as present, and with the
environment's `PZ_PRUNE=1` as the standalone runner's equivalent
(`--prune`). Off by default because it deletes from the shared install.

---

## Secrets

The Nix-rendered base `.ini` is a store path — mode `444`, world-readable.
Anything in `settings` is therefore **not a secret**: it is a plaintext file any
local user can `grep` out of `/nix/store`. `RCONPassword`, `DiscordToken` and
`WebhookAddress` are all reachable that way.

So use `secretFiles`, which carries paths rather than values:

```nix
services.project-zomboid-servers.servers.foo = {
  passwordFile = config.age.secrets.pz-join.path;         # → Password=
  secretFiles = {
    RCONPassword = config.age.secrets.pz-rcon.path;
    DiscordToken = config.age.secrets.pz-discord.path;
  };
};
```

Values are read at start and written straight into the key. Evaluation **fails**
if one of those keys appears in `settings` or `sandbox`, in a modpack's
`defaultSettings` or `defaultSandbox`, and the renderer filters them
independently — so a bare module import cannot leak one either.

The merged `<name>.ini` in the data directory is therefore written mode `0600`
by the prep script: Project Zomboid runs as its owner, while the web console and
dashboard users do not need to read it (they use their own secret path). The
cached Steam login under `<dataDir>/.local/share/Steam` is also set to `0700`,
for the same reason.

`extraArgs` is the same trap in a different place: it is baked into a
world-readable unit file.

---

## Two defaults that differ from PZ

- **`upnp = false`.** PZ defaults `UPnP=true`. Automatic port forwarding is a poor
  default for a managed host: it silently punches holes in a firewall that
  `openFirewall` and your own rules deliberately keep closed, and it cannot work
  behind a container at all. Use `openFirewall`.
- **`rconPort` default is `0`** (off), and the suggested port when you do enable
  it is **27016**, not PZ's 27015 — that is Minecraft's default, and this module
  is meant to sit alongside a Minecraft server. A port is not enough on its own:
  PZ starts RCON only when `RCONPassword` (set through `secretFiles`) is
  non-empty too. `rconPort` without a password is reported as an evaluation
  warning, because otherwise it looks configured and silently does nothing.

### Why `restart` is `always`

Stopping a PZ server cleanly sends `quit` down the console, which makes the JVM
exit `0`. Under `on-failure` that is a *success*, so the unit would not come back
— including after a deliberate `systemctl stop`-then-boot. Use `on-failure` only
if you want a crash-looping server to stay down.

### Keys deliberately not given first-class options

A few keys are reachable through `settings` but have no dedicated option, because
they could not be verified against an authoritative source:

- **`STEAMPORT1` / `STEAMPORT2`** appear in at least one community
  implementation's environment template but are **absent from the Build 42 ini
  key list**. Rather than guess, they are left as plain `settings` keys —
  reachable if you need them, but not blessed with an option whose name would
  imply the module knows what they do.
- **`MIN_MEMORY` / `MAX_MEMORY`** in the same template are JVM heap sizing, which
  this module already exposes properly as `jvmOpts`.

If you set one of these and it does not appear to take effect, that is why: it is
not a documented key, so the game may ignore it.