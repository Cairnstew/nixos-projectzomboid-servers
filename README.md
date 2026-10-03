# nixos-projectzomboid-servers

Declarative [Project Zomboid](https://projectzomboid.com) dedicated servers for
NixOS, plus a shared modpack catalogue.

Two separate things, deliberately:

- **a NixOS module** (`services.project-zomboid-servers`) that manages servers —
  systemd units, the SteamCMD install, console sockets, the `.ini` and
  `SandboxVars.lua`, firewall, resource caps;
- **a modpack catalogue** (`self.modpacks`) — plain data, no module — so packs can
  be shared and versioned independently of anybody's configuration.

The module ships **no modpacks of its own**. Wire the catalogue in, or cherry-pick
from it, or ignore it entirely and write your own.

Modelled on [`Infinidoge/nix-minecraft`](https://github.com/Infinidoge/nix-minecraft),
which is the closest equivalent for Minecraft server fleets.

---

## Running a server

Two ways in. Both share one implementation (see [lib/prepare.nix](lib/prepare.nix)),
so a server behaves the same whichever you pick.

### `nix run` — no NixOS host needed

```bash
# Unmodded
nix run github:you/nixos-projectzomboid-servers#pz-dedicated-server -- myserver

# With a catalogue pack baked in — one app per pack
nix run github:you/nixos-projectzomboid-servers#pz-vanilla-plus -- myserver
```

The first run downloads the dedicated server (several GB) with steamcmd, fetches
the pack's Workshop mods, writes the config, then runs the server **with your
terminal as the console**. Ctrl-C — or end-of-input — saves and quits cleanly
rather than killing the JVM mid-save.

```
project-zomboid: server    myserver
project-zomboid: modpack   vanilla-plus
project-zomboid: data-dir  /mnt/pz
project-zomboid: install   /mnt/pz/server
project-zomboid: ports     16261 (udp) / 16262 (udp) / 0 (rcon)
project-zomboid: prepared myserver in /mnt/pz/myserver
project-zomboid: starting myserver
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--data-dir PATH` | Base directory. Default `$PWD/pz-data`. |
| `--port` / `--udp-port` / `--rcon-port` | Override the baked-in ports at runtime. |
| `--jvm-opts "-Xmx8G -Xms4G"` | Heap. Reaches the JVM ahead of the vendor script. |
| `--set KEY=VALUE` | Any `.ini` key, repeatable. Beats the modpack. |
| `--secret KEY=PATH` | Read an `.ini` key's value from a file. **Use this, not `--set`, for secrets.** |
| `--map NAME` | Pin `Map=` instead of deriving it. |
| `--base-map NAME` | The vanilla map, ordered last. |
| `--map-priority ID` | Mod id that wins a duplicate-map clash. Repeatable. |
| `--strict-maps` / `--dedupe-maps` | Fail on a clash / rename losers aside. |
| `--list-maps` | Print the derived `Map=` and why, then exit. No server needed. |
| `--extra-arg ARG` | Argument for the server command line. Repeatable. |
| `--admin-user` + `--admin-pass-file` | Create/update the Build 42 admin login. |
| `--soft-reset` | Discard world identity, generating a fresh world. |
| `--no-install` | Skip the steamcmd validate — much faster restarts. |
| `--print-config` | Write and print the config, then exit. **Needs no game files.** |

`--print-config` is the fast loop for "what does this modpack actually do?":

```console
$ nix run .#pz-vanilla-plus -- --data-dir ./d --no-install --print-config myserver
== ./d/myserver/Zomboid/Server/myserver.ini ==
DefaultPort=16261
Map=Muldraugh, KY
WorkshopItems=2625441155;2625840413;2679583791;2634209060;2705410157;2705410286
DoLuaChecksum=false
PVP=true
…
== ./d/myserver/Zomboid/Server/myserver_SandboxVars.lua ==
SandboxVars = {
    Zombies = 3,
    DayLength = 4,
…
```

To add a local (non-Workshop) mod, put its folder in
`<server-dir>/Zomboid/mods` and add its `mod.info` `id` to the pack's `mods`.

### Under NixOS

Use the module — see [Quick start](#quick-start) below.

```nix
services.project-zomboid-servers = {
  enable = true;
  modpacks = inputs.project-zomboid-servers.modpacks;
  servers.main = {
    modpack = "vanilla-plus";
    hardware.memoryMax = "8G";
  };
};
systemctl start project-zomboid-main
```

### What "shared" actually means

`lib/prepare.nix` owns the install/validate step, the `.ini` merge, the
SandboxVars render and the Workshop symlinks. The module runs those scripts from
a systemd unit's `ExecStartPre`; the runner runs the identical scripts with
`--data-dir`. Only the supervision differs — systemd's `.socket` unit owning a
FIFO versus a small shell supervisor.

The `.ini` merge is the reason this matters: it has to preserve Project Zomboid's
world-identity keys, and two copies of that logic would drift, and the wrong one
would reset worlds.

## Quick start

```nix
{
  inputs.project-zomboid-servers.url = "github:you/nixos-projectzomboid-servers";

  outputs = { nixpkgs, project-zomboid-servers, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        {
          imports = [ project-zomboid-servers.nixosModules.project-zomboid-servers ];

          # Project Zomboid is a Steamworks title; its packages are unfree.
          nixpkgs.config.allowUnfree = true;

          services.project-zomboid-servers = {
            enable = true;
            dataDir = "/mnt/data/project-zomboid";

            # The catalogue, or any subset of it.
            modpacks = {
              inherit (project-zomboid-servers.modpacks) vanilla-plus;
            };

            servers.main = {
              modpack = "vanilla-plus";
              defaultPort = 16261;
              udpPort = 16262;
              openFirewall = true;
              hardware.memoryMax = "8G";
            };
          };
        }
      ];
    };
  };
}
```

Then `systemctl start project-zomboid-main`. The first start downloads the game
(Steam app 380870) and the pack's Workshop mods — expect several GB and a few
minutes.

Note there is no `map` in that config, and that is deliberate: `Map=` is derived
from the maps the installed mods actually ship, in a deterministic order. Set
`map` only to pin it — see [Maps are derived](#maps-are-derived-and-ordered-deterministically).

A complete, buildable example is in [`examples/single-server`](examples/single-server).

---

## Options at a glance

Namespace: `services.project-zomboid-servers`.

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Master switch. |
| `dataDir` | path | `/var/lib/project-zomboid` | Per-server homes and `serverDir` live here. |
| `serverDir` | path | `${dataDir}/server` | The shared SteamCMD install. One per host. |
| `runDir` | path | `/run/project-zomboid-servers` | Console FIFOs. tmpfs, gone on reboot. |
| `package` | package | the flake's launcher | Must be set; the flake's `nixosModules` fills it in. |
| `user` / `group` | str | `project-zomboid` | |
| `steamcmd` / `steamRun` | package | `pkgs.steamcmd` / `pkgs.steam-run` | |
| `updateOnStart` | bool | `true` | Validate the install before each server starts. |
| `updateSchedule` | str \| null | `null` | Also update on a systemd timer. |
| `restartAfterUpdate` | bool | `true` | `try-restart` running servers after a timer update. |
| `modpacks` | attrsOf submodule | `{}` | Map the catalogue in. |
| `servers` | attrsOf submodule | `{}` | One service + console socket per entry. |
| `managementSystem` | submodule | `{ systemd-socket.enable = true; }` | Exactly one of `systemd-socket` / `tmux`. |
| `startLimitIntervalSec` / `startLimitBurst` | int | `120` / `5` | Crash-loop bound. |
| `web.*` | submodule | disabled | ttyd consoles. See below. |

Per server:

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `name` / `description` | str | attr name | `name` drives the `.ini`, lua files and save folder. |
| `modpack` | str \| null | `null` | Inline `workshopMods`/`mods` are **appended** to the pack's. |
| `workshopMods` / `mods` | list | `[]` | Workshop ids vs local mod folder names — not interchangeable. |
| `map` | str \| null | `null` | `null` = derive from installed mods. Semicolon separated. See below. |
| `baseMap` | str | `Muldraugh, KY` | The vanilla map; always ordered **last**. |
| `mapOrder` | submodule | see below | Collision policy for derived `Map=`. |
| `spawn.points` / `spawn.regions` | list | `[]` | Rendered to `<server>_spawnpoints.lua` / `_spawnregions.lua`. |
| `defaultPort` / `udpPort` | port | `16261` / `16262` | PZ binds **two** UDP ports; both must be unique. |
| `rconPort` | port | `0` | `0` = RCON off. See the note on 27015 below. |
| `openFirewall` | bool | `false` | Opens the two UDP ports. |
| `public` / `publicName` / `maxPlayers` | | `true` / name / `32` | |
| `settings` / `sandbox` | attrs | `{}` | Any PZ key. **Never put a secret here** — see Secrets. |
| `secretFiles` | attrsOf path | `{}` | `Key = /path/to/secret`. The only way to set a secret. |
| `passwordFile` | path \| null | `null` | Sugar for `secretFiles.Password`. Wins if both set. |
| `adminAccount` | submodule \| null | `null` | Creates the Build 42 admin login. |
| `whitelist` / `admins` | listOf str | `[]` | **Build 41 only.** Inert on 42 unless `compatibility.build41`. |
| `compatibility.build41` | bool | `false` | Re-enables `Whitelist=` / `Users=`. |
| `extraArgs` | listOf str | `[]` | Appended to the server command line. No credentials. |
| `upnp` | bool | `false` | `UPnP=`. PZ defaults this **true**; see below. |
| `selfManagedMods` | bool | `true` | Stop PZ rewriting the mod list out from under you. |
| `softReset` | bool | `false` | Discard world identity, generating a fresh world. Destructive. |
| `betaBranch` | str \| null | `null` | e.g. `"legacy41"`. One install = one branch (asserted). |
| `jvmOpts` | str | `-Xmx4G -Xms2G` | Injected **ahead of** the vendor launcher. |
| `autoStart` / `restart` | bool / str | `true` / `always` | |
| `managementSystem` / `hardware` / `extraServiceConfig` | submodule / attrs | inherited / `{}` | |
| `webConsole` / `port` | bool / port \| null | `true` / auto | ttyd console. |

### Maps are derived, and ordered deterministically

`Map=` is the one setting that **cannot** be written down statically. A map exists
only if some installed mod ships `media/maps/<name>/`, and which mods are installed
is not known until `steamcmd` has run. So by default `map = null` means *derive it*,
and `scripts/pz_maps.py` does that at start from what is actually on disk.

The order is load-bearing. PZ resolves `media/maps/<name>` across *every* loaded
mod, so when two mods ship the same map name the winner is whichever the mod
loader reaches first — which depends on `Mods=`/`WorkshopItems=` order, and
therefore on download order. That is non-deterministic, and silently so: the
server starts fine and the wrong tiles load.

So the sort key is **total**, and every component is a stable comparison of data
we control — nothing depends on how the filesystem listed a directory:

1. mod maps first, by `(priority, kind, numeric id, mod id, map name)`
2. the `baseMap` **last**, always — mod maps add new areas rather than patching
   vanilla tiles, so letting the base map resolve last means any genuine overlap
   goes in favour of vanilla, which is the direction that cannot corrupt terrain
   players already know.

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

Note the separators differ per key, which is a reliable source of silent
misconfiguration: `Map=` is **semicolon** separated, `Mods=` is **comma**
separated, and `WorkshopItems=` is **semicolon** separated.

| `mapOrder` | Default | Notes |
| --- | --- | --- |
| `enable` | `true` | Forced off when `map` is set — an explicit value wins outright. |
| `priority` | `[]` | Mod ids that win duplicate-map clashes and order first, in order. |
| `strict` | `false` | Refuse to start on any clash. For CI, or once a pack is known clean. |
| `dedupe` | `false` | Rename losers to `*.pz-duplicate`. **Writes to the shared install**, so off by default; recoverable by renaming back. |

Set `map` explicitly to pin the list and turn detection off — which you must do
if your mods conflict, or you want a map no mod ships. A mod shipping the
`baseMap`'s own name is reported as an **error**, because it shadows vanilla
terrain.

For context: the most popular server-config editor for the game — Workshop item
2725216703, "Mod Manager: Server", ~1.4M subscribers — documents that it
explicitly does *not* manage maps or spawn regions, leaving them to be edited by
hand. Deriving them is most of what this module does that a GUI cannot.

### Secrets

The rendered base `.ini` is a `pkgs.writeText` store path, which is mode `444`
and world-readable. Anything in `settings` is therefore **not a secret** — it is a
plaintext file any local user can `grep` out of `/nix/store`. `RCONPassword`,
`DiscordToken` and `WebhookAddress` are all reachable that way.

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

The values are read at start by `merge_ini.py` and written straight into the
key. Evaluation **fails** if one of those keys appears in `settings` or
`sandbox`, and `renderIniLines` filters them independently, so a bare module
import cannot leak one either. The `secrets-not-in-store` check enforces this.

`extraArgs` is the same trap in a different place — it is baked into a
world-readable unit file, so no credentials there either.

### Admin accounts

Build 42 has **no `.ini` key** for the admin login: it is a row in
`Zomboid/db/<servername>.db`, and the only supported way to write it is the
`-adminusername` / `-adminpassword` command-line pair.

```nix
adminAccount = {
  username = "seanc";
  passwordFile = config.age.secrets.pz-admin.path;
};
```

**Known limitation:** a process argument is visible in `ps` for the lifetime of
the server. PZ offers no alternative and every other deployment shares the
exposure, but the password is at least read from a file rather than baked into
the unit, so it never reaches `systemctl cat` or the Nix store.

`whitelist` and `admins` are **Build 41 only**. `Whitelist=` and `Users=` are
not documented Build 42 ini keys, so writing them produced a config that listed
admins and a whitelist and did nothing. They are now gated behind
`compatibility.build41 = true`, off by default.

### Spawn points and regions

`<server>_spawnpoints.lua` and `<server>_spawnregions.lua` are two of the four
files PZ lists as necessary for a server to work. Both are generated by PZ when
absent, so the module writes them only when configured, and **removes** them when
emptied — otherwise dropping the option would silently do nothing to a running
server.

```nix
spawn = {
  points = [
    { pos = [ 12067 6801 0 ]; }                    # profession defaults to unemployed
    { pos = [ 5000 5000 0 ]; profession = "engineer"; }
  ];
  regions = [
    { name = "Mod Spawn"; file = "media/maps/ModName/spawnpoints.lua"; }
  ];
};
```

`pos` is a world coordinate triple. So, for the avoidance of doubt, is PZ's own
`SpawnPoint=` ini key: `SpawnPoint=0,0,0` is the origin, not a preset and not an
index. Profession keys are emitted bare when they are valid Lua identifiers
(matching PZ's own generated file) and bracket-quoted otherwise, and the
`spawn-and-reset` check parses the result with a real Lua interpreter — two
syntax errors got through grep before that existed.

### Keys deliberately not given first-class options

A few keys are reachable through `settings` but have no dedicated option,
because they could not be verified against an authoritative source:

- **`STEAMPORT1` / `STEAMPORT2`** appear in at least one community
  implementation's environment template but are **absent from the Build 42
  ini key list**. Rather than guess, they are left as plain `settings` keys —
  reachable if you need them, but not blessed with an option whose name would
  imply the module knows what they do.
- **`MIN_MEMORY` / `MAX_MEMORY`** in the same template are JVM heap sizing,
  which this module already exposes properly as `jvmOpts`.

If you set one of these and it does not appear to take effect, that is the
reason: it is not a documented key, so the game may ignore it.

### Two defaults that differ from PZ

- **`upnp = false`.** PZ defaults `UPnP=true`. Automatic port forwarding is a poor
  default for a managed host: it silently punches holes in a firewall that
  `openFirewall` and the operator's own rules deliberately keep closed, and it
  cannot work behind a container at all. Use `openFirewall`.
- **`rconPort` default is `0`** (off), and when you do enable it the flake's
  suggested port is **27016**, not PZ's 27015 — that is Minecraft's default, and
  this module is meant to sit alongside a Minecraft server.

---

## How it fits together

```
project-zomboid-install.service     (oneshot, RemainAfterExit)
  └─ steamcmd +app_update 380870 validate
  └─ steamcmd +workshop_download_item 108600 <id>…   (de-duplicated)

project-zomboid-foo.service        (one per enabled server)
  ├─ ExecStartPre → merges Zomboid/Server/<name>.ini   (world identity kept)
  │                 resolves Map= from the installed mods  (deterministic)
  │                 writes _SandboxVars.lua, _spawnpoints.lua, _spawnregions.lua
  │                 links Zomboid/Workshop/content/108600/<id>
  ├─ ExecStart     → project-zomboid-server <name>  (the launcher package)
  └─ ExecStop      → writes `save`, waits, writes `quit` down the console FIFO

project-zomboid-foo.socket        (ListenFIFO on runDir/foo.fifo, mode 0660)

project-zomboid-foo-web.service   (optional ttyd console)
```

### Why the `.ini` is merged and not written

Project Zomboid keeps world identity — `Seed`, `ResetID`, `LastModified`,
`ServerPlayerID`, `Password` — in the *same* `.ini` it reads config from. Writing
that file from scratch renumbers every world on every start. So `scripts/merge_ini.py`
updates only the keys the module owns and leaves every other line untouched.

`_SandboxVars.lua` is the opposite case: PZ regenerates it entirely, so the module
owns it outright and renders it to a store file.

### Why `Map=` is the one thing derived at runtime

Every other value is catalogue data and stays in Nix. `Map=` cannot: a map exists
only if an installed mod ships it, and the mod list on disk is not known until
`steamcmd` has run. `scripts/pz_maps.py` resolves it at start, in a total order
so the result is reproducible. See "Maps are derived" above.

### Why generated files are `install`ed, not `cp`ed

A store file is mode `444`, and `cp` gives a new file the source's permissions —
so the destination was created read-only and the **second** start failed with
`cp: cannot create regular file: Permission denied`. In production PZ rewrites
`_SandboxVars.lua` in between and masks it, which is exactly why it survived.
`install -m 0644` unlinks first, so it is correct regardless of the current mode.

### Why `steam_appid.txt` is written by the launcher

It must contain exactly one line — the **join** app id `108600`, not the
dedicated-server app id. A file with two or more ids makes Build 42 abort with
`Assertion Failed: Illegal termination of worker thread`. The launcher overwrites
it on every start, so a stale multi-id file cannot accumulate.

### Why `jvmOpts` is injected before the launcher

`start-server.sh` sets its own hardcoded `-Xms`/`-Xmx` and ignores anything set
after it — the wiki is explicit that you must edit the script. Passing the flags
ahead of it in `PZ_JVM_OPTS` is the declarative equivalent.

### Why the console is a socket unit

PZ reads server commands from stdin, so "the console" is fundamentally an fd 0.
A `.socket` unit with `ListenFIFO` owns that fd, which means correct ownership and
mode for free, no `ExecStartPre` `mkfifo` dance, and `systemctl stop` works by
writing `quit` down the FIFO rather than by signalling a process that does not
handle `SIGTERM`.

To use tmux instead (attach with `tmux -S /run/project-zomboid-servers/<name>.sock attach`):

```nix
services.project-zomboid-servers = {
  managementSystem.tmux.enable = true;
  managementSystem.systemd-socket.enable = false;
};
```

---

## Build 42 notes

Things that bite, recorded so they are not re-learned:

- **`DoLuaChecksum = true` has a Linux false-positive bug** that blocks clients
  from joining. Both example packs set it to `false`.
- **Admin accounts live in SQLite**, at `Zomboid/db/<servername>.db`, and there
  is no `.ini` key for them — only the `-adminusername`/`-adminpassword` pair.
  Use `adminAccount`; see "Admin accounts" above for the `ps` caveat.
- **`Whitelist=` and `Users=` are not Build 42 ini keys.** They are Build 41
  leftovers; the whitelist is a table in the same SQLite database. They are
  written only under `compatibility.build41`.
- **`SpawnPoint=` is a world coordinate triple** (`x,y,z`), not a preset or an
  index. `SpawnPoint=2` means two metres from the origin.
- The stable build at time of writing is **42.21.0**; wiki pages still target
  42.20.x, so flag names move between them.
- `mod.info` ships with CRLF, so validating a downloaded mod with a shell `grep`
  needs `grep -llx -E "id=$mod[[:cntrl:]]?"`.
- Build 42's native Prometheus endpoint only starts if `-DprometheusPort=<port>`
  is in `ProjectZomboid64.json`'s `vmArgs` — and Steam `validate` can replace that
  file, so it is game state, not config you own.

## Depot pinning (not done yet)

The game binary is fetched by `steamcmd` into `serverDir` at activation time.
It is **not** a store path, and `versions.json` deliberately contains no depot
`manifestId` or content hash.

Those values rotate on every PZ build, so hand-committing them would be wrong
within days. They need a generated manifest from a real fetcher —
`fetchSteam` from [`nix-community/steam-fetcher`](https://github.com/nix-community/steam-fetcher)
(note: **not** in nixpkgs). When that lands, `pkgs/project-zomboid-server`
becomes a `fetchurl`-style derivation and `serverDir` becomes immutable.

Everything else here already assumes the split: the module only ever references
`serverDir` as a path.

## Reverse proxy

The web consoles bind loopback and register **plain data**, not a dependency on
anyone's proxy module:

```nix
proxy.upstreams = lib.mkMerge (map (u: {
  inherit (u) port path stripPrefix displayName;
  name = u.name;
}) config.services.project-zomboid-servers.webConsoleUpstreams);
```

`path` defaults to `/pz/<name>/` and `stripPrefix` to `true`, which ttyd needs.

---

## Development

```bash
nix flake check          # all checks, both systems
nix run .#pz-modpack -- list
nix run .#pz-modpack -- show vanilla-plus
nix develop              # nixfmt, shellcheck, deadnix, statix, python3
```

Inspect a pack's effective config without downloading anything:

```bash
nix run .#pz-vanilla-plus -- --data-dir ./d --no-install --print-config myserver
```

The checks:

| Check | What it proves |
| --- | --- |
| `launcher` | The wrapper builds — `writeShellApplication` means shellcheck runs at build time, so a shell error fails the build. |
| `modpack-catalogue` | Every pack in `modpacks/` is well-formed plain data. |
| `module-eval` | Two configurations (one plain, one with web consoles + tmux) produce the right units, ports and Exec paths. |
| `prep-roundtrip` | Runs the real prep script against a seeded world: the merge preserves world identity, runtime overrides win, SandboxVars is written, mods are linked and stale ones unlinked. |
| `secrets-not-in-store` | No secret value appears in any rendered store file, and `secretFileArgs` references paths only. |
| `secret-guard` | The assertion actually **fires** — on a secret in `settings`, in `sandbox`, in a modpack's `defaultSettings` and in its `defaultSandbox` — and stays silent for a config using `secretFiles`. |
| `spawn-and-reset` | The dead Build 42 keys are absent (and present under `build41`), spawn lua renders, **is parsed by a real Lua interpreter**, and `--soft-reset` is scoped to the identity keys. |
| `map-ordering` | Two trees built in opposite orders give identical `Map=`; a non-map directory never leaks in; a duplicate is reported, deterministic and overridable; `--strict` fails; base-map shadowing is an error. |
| `map-pin-clean` | Pinning `Map=` suppresses detection without passing an empty argument. |

Four of those exist because they caught a real bug rather than because the
behaviour was speculative — the store-mode-444 `cp`, the `${v+$v}` argument, the
empty-argument quoting trap, and the missing comma in the Lua table. That is the
argument for executing the prep script in a check at all: every one of those is
invisible to `nix flake check --no-build` and to reading the generated file.

`module-eval` is the interesting one. It asserts in Nix — not shell — that every
server got a service *and* a console socket, that `ExecStart`/`ExecStartPre`/`ExecStop`
are absolute store paths, that `jvmOpts` actually reached the unit, that the unit
the servers `Requires` exists, that no unit depends on an undefined one, and that
the firewall opened exactly the ports that opted in. Those are all defects that
shipped broken in the module this was ported from.

To iterate on the module without booting a VM, use the same helper the check uses:

```bash
nix develop
nix eval --impure --json --expr '
  let flake = builtins.getFlake "path:/home/seanc/Projects/nixos-projectzomboid-servers";
  in (flake.lib.tests.eval { }).config.systemd.services
'
```

`eval` takes `{ config, base, extraImports }` — see [`lib/tests.nix`](lib/tests.nix).
It runs `lib.nixosSystem`, so `assertions` and the real systemd service generation
are exercised; only the running-system parts are skipped.

## Licence

MIT — see [LICENSE](LICENSE). Note the *game* is not MIT and is not distributed
here; only the Nix plumbing is.