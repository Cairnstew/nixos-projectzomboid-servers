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
| `runDir` | path | `/run/project-zomboid-servers` | Console FIFOs. tmpfs, gone on reboot. |
| `steamcmd` | package | `pkgs.steamcmd` | Unfree. |
| `steamRun` | package | `pkgs.steam-run` | Unfree. Supplies the FHS environment the server binary needs. |
| `updateOnStart` | bool | `true` | steamcmd `validate` before each start. First boot fetches the game; later boots are a fast no-op. |
| `updateSchedule` | str \| null | `null` | Also validate on a systemd timer, e.g. `"daily"`. Restarts running servers afterwards. |
| `restartAfterUpdate` | bool | `true` | `try-restart` servers after a timer update, so a stopped one stays stopped. |
| `modpacks` | attrsOf submodule | `{}` | Map the catalogue in. See [modpacks](#modpacksname). |
| `servers` | attrsOf submodule | `{}` | See [servers.<name>](#serversname). |
| `managementSystem` | submodule | `{ systemd-socket.enable = true; }` | Default console backend. See [managementSystem](#managementsystem). |
| `startLimitIntervalSec` | int | `120` | Crash-loop window. |
| `startLimitBurst` | int | `5` | Restarts allowed in that window. |
| `webConsoleUpstreams` | listOf submodule | *(read-only)* | Derived. See [webConsoleUpstreams](#webconsoleupstreams). |
| `clientHosts` | attrsOf submodule | *(read-only)* | Derived from `servers.<name>.clientHost.enable`. See [clientHosts](#clienthosts). |
| `web` | submodule | disabled | See [web](#web). |

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
| `web.user` | str | `project-zomboid-web` | Added to the server group, with scoped password-less sudo for `systemctl {start,stop,restart,status}` on PZ units only. |
| `web.username` | str \| null | `null` | HTTP basic auth. Requires `passwordFile`. |
| `web.passwordFile` | path \| null | `null` | e.g. an agenix secret. |
| `web.openFirewall` | bool | `false` | Opens the console ports. Off: put a proxy in front instead. |

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
| `prepare` | path | A runnable script that seeds the client's Zomboid home. Takes `PZ_CLIENT_ZOMBOID` (required) and `PZ_SERVER_DIR` from the environment. `PZ_CLIENT_WORKSHOP` overrides the Steam library it links into — **discovered** from Steam when unset; `PZ_LINK_STEAM_WORKSHOP=0` skips the link entirely. |
| `iniFile` | path | The Nix-rendered base `.ini`, *before* the merge. Hand this to `prepare`; installing it directly would overwrite `Seed`/`ServerPlayerID` on an existing world. |
| `sandboxFile` | path | The Nix-rendered `<name>_SandboxVars.lua`. |
| `mods` | listOf str | The resolved `Mods=` list. |
| `workshopItems` | listOf str | The resolved `WorkshopItems=` list (Steam Workshop ids). |

```nix
# In the client user's Home Manager configuration — nothing else is needed, and
# no path has to be written down:
imports = [ inputs.project-zomboid-servers.homeModules.default ];
```

Two behaviours worth knowing:

- The `.ini` is **merged, not rewritten**, so `Seed`, `ServerPlayerID` and
  `LastModified` survive — the same reason the dedicated server merges. Re-running
  is safe.
- Named keys come from the server's resolved settings, so a server defined with
  `public = true` will **overwrite** a client-side `Public=false` in that file.
  Override it in `settings` if the client host should stay private.
- The Steam library is **discovered**, not configured: the script reads
  `steamapps/libraryfolders.vdf` (`scripts/pz_steam_workshop.py`) to find the
  library that actually holds Project Zomboid, so no host file hard-codes a path.
  When `PZ_SERVER_DIR` is also set it symlinks every Workshop item from the
  shared steamcmd download into that library, so one download serves both hosts.
  Not-installed-via-Steam is a normal condition — it is reported and skipped,
  never fatal, so seeding files before the first launch still works.
- ⚠ **The link is not what makes the mods load.** Project Zomboid's *client*
  enumerates Workshop mods through Steam's subscription list and never scans the
  library, so symlinked content is invisible to it — only the dedicated server,
  which does scan, sees it. A hosted world still needs its items **subscribed**
  in Steam. `PZ_LINK_STEAM_WORKSHOP=0` skips the link outright.

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
| `services.project-zomboid-servers.home.linkSteamWorkshop` | bool | `true` | Symlink the shared SteamCMD download into the client library. Does **not** make the mods load — see [clientHosts](#clienthosts). |

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
- `Mods=` — **comma** separated
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
| `map` | str \| null | `null` | `null` = **derive** from installed mods. Semicolon separated. See [Maps](#maps). |
| `baseMap` | str | `Muldraugh, KY` | The vanilla map, always placed **last**. |
| `mapOrder` | submodule | `{}` | See [mapOrder](#maporder). |
| `spawn` | submodule | `{}` | See [spawn](#spawn). |
| `defaultPort` | port | `16261` | `DefaultPort`, UDP. Must be unique across enabled servers. |
| `udpPort` | port | `16262` | `UDPPort`, UDP. PZ binds **two** UDP ports per instance; both must be unique. |
| `rconPort` | port | `0` | `0` = RCON off. |
| `openFirewall` | bool | `false` | Opens this server's two UDP ports. |
| `public` | bool \| null | `null` | Server browser. `null` = true. |
| `publicName` | str \| null | `null` | Browser name. `null` = the attribute name. |
| `maxPlayers` | int | `32` | PZ warns above 32. |
| `settings` | attrs | `{}` | `.ini` keys this server owns. **Never a secret.** |
| `sandbox` | attrs | `{}` | SandboxVars. **Never a secret.** |
| `open` | bool \| null | `null` | `null` = true. `false` requires a populated `whitelist`. |
| `whitelist` | listOf str | `[]` | **Build 41 only.** |
| `admins` | listOf str | `[]` | **Build 41 only.** Grants in-game rights; never creates the login. |
| `compatibility.build41` | bool | `false` | Re-enables `Whitelist=` / `Users=`. |
| `adminAccount` | submodule \| null | `null` | Creates the Build 42 admin login. |
| `secretFiles` | attrsOf path | `{}` | `Key = path`. The only way to set a secret. |
| `passwordFile` | path \| null | `null` | Sugar for `secretFiles.Password`. Wins if both are set. |
| `extraArgs` | listOf str | `[]` | Appended to the command line. **Never a credential** — it lands in a world-readable unit. |
| `upnp` | bool | `false` | `UPnP=`. PZ defaults this **true**; see [below](#two-defaults-that-differ-from-pz). |
| `selfManagedMods` | bool | `true` | Stop PZ rewriting `Mods=` out from under you. |
| `softReset` | bool | `false` | Discard world identity, generating a fresh world. Destructive. |
| `betaBranch` | str \| null | `null` | e.g. `"legacy41"`. Per-server, but applied by the **shared** install, so set it on every server or none. |
| `jvmOpts` | str | `-Xmx4G -Xms2G` | Placed **before the `--`** the launcher inserts, which is what routes flags to the JVM rather than to the game. The only way to set the heap. |
| `javaAgent` | submodule \| null | `null` | `{ jar, args }` — a JVM agent (e.g. ZombieBuddy) prepended to `jvmOpts`. A headless server **must** set a non-prompting policy. |
| `autoStart` | bool | `true` | |
| `restart` | str | `"always"` | See [below](#why-restart-is-always). |
| `managementSystem` | submodule | inherits top level | Override per server to mix backends. |
| `hardware` | submodule | `{}` | See [hardware](#hardware). |
| `extraServiceConfig` | attrs | `{}` | Extra `serviceConfig`. Avoid sandboxing directives that break `steam-run`'s user-namespace FHS. |
| `webConsole` | bool | `true` | Needs `web.enable`. |
| `port` | port \| null | `null` | Web console port; `null` assigns from `web.portBase` in sorted server order. |
| `clientHost` | submodule | disabled | Render files for the game's in-game **Host** button from this same pack. See [clientHost](#clienthost). |

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

The `.ini` is merged rather than rewritten (see
[`clientHosts`](#clienthosts)), and `PZ_CLIENT_WORKSHOP` shares one Workshop
download between the dedicated server and the client. Note that the client half
of a Java-mod pack needs its JVM agent installed **in the client**, which is a
launch-option (or `ProjectZomboid64.json`) change outside this module — see the
pack's own instructions.

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
  is meant to sit alongside a Minecraft server.

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