# nixos-projectzomboid-servers

Declarative [Project Zomboid](https://projectzomboid.com) dedicated servers for
NixOS, plus a shared modpack catalogue.

Two separate things, deliberately:

- **a NixOS module** (`services.project-zomboid-servers`) that manages servers —
  systemd units, the SteamCMD install, console sockets, the `.ini` and
  `SandboxVars.lua`, spawn files, firewall, resource caps;
- **a modpack catalogue** (`self.modpacks`) — plain data, no module — so packs can
  be shared and versioned independently of anybody's configuration.

The module ships **no modpacks of its own.** Wire the catalogue in, cherry-pick
from it, or ignore it and write your own.

Modelled on [`Infinidoge/nix-minecraft`](https://github.com/Infinidoge/nix-minecraft),
the closest equivalent for Minecraft server fleets.

---

## Documentation

| Page | For |
| --- | --- |
| **[docs/installing.md](docs/installing.md)** | Requirements, the three ways to consume this, pinning, upgrading. **Start here.** |
| **[docs/options.md](docs/options.md)** | Every option, with type and default. Completeness-checked in CI. |
| **[docs/host-recipes.md](docs/host-recipes.md)** | Fleets, web consoles, your own modpack, secrets, hardening. |
| **[docs/troubleshooting.md](docs/troubleshooting.md)** | Symptom → cause → fix, including every bug this project has actually shipped. |
| [examples/single-server](examples/single-server) | A complete, `nix flake check`-able one-server configuration. |
| [CHANGELOG.md](CHANGELOG.md) | What changed, and which changes were corrections rather than features. |

---

## Requirements

- NixOS with flakes (or `fetchTarball` — see [installing](docs/installing.md))
- **`allowUnfree = true`** — PZ is a Steamworks title
- **`x86_64-linux`** for the flake outputs; the module still evaluates elsewhere
- several GB of disk for the install, and a large disk for saves
- two free UDP ports per server

Evaluated clean against `nixos-24.11`, `nixos-25.05` and `nixos-unstable` with
zero failed assertions. Details in
[installing](docs/installing.md#verified-compatibility).

---

## Quick start

```nix
{
  inputs.project-zomboid-servers.url = "github:you/nixos-projectzomboid-servers";

  outputs = { nixpkgs, project-zomboid-servers, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        {
          imports = [ project-zomboid-servers.nixosModules.project-zomboid-servers ];

          nixpkgs.config.allowUnfree = true;

          services.project-zomboid-servers = {
            enable = true;
            dataDir = "/mnt/data/project-zomboid";   # saves grow without bound

            modpacks = project-zomboid-servers.modpacks;

            servers.main = {
              modpack = "vanilla-plus";
              defaultPort = 16261;
              udpPort = 16262;
              openFirewall = true;
              jvmOpts = "-Xmx8G -Xms4G";
              hardware.memoryMax = "10G";
            };
          };
        }
      ];
    };
  };
}
```

```bash
nixos-rebuild switch --flake .#myhost
systemctl start project-zomboid-main
```

The first start downloads the game (Steam app 380870) and the pack's Workshop
mods — several GB and a few minutes. Note there is no `map` in that config, and
that is deliberate: see below.

Prefer no flakes, or want to try it without a host? There are three consumption
paths in [docs/installing.md](docs/installing.md).

---

## What this does that a config GUI cannot

### `Map=` is derived, and ordered deterministically

`Map=` is the one setting that **cannot** be written down statically. A map exists
only if some installed mod ships `media/maps/<name>/`, and which mods are
installed is not known until `steamcmd` has run. So by default `map = null` means
*derive it*, at start, from what is actually on disk.

The order is load-bearing. PZ resolves `media/maps/<name>` across **every** loaded
mod, so when two mods ship the same map name the winner is whichever the mod
loader reaches first — which depends on `Mods=`/`WorkshopItems=` order, and
therefore on download order. That is non-deterministic, and silently so: the
server starts fine and the wrong tiles load.

So the sort key is **total**, and every component is a stable comparison of data
we control — nothing depends on how the filesystem listed a directory:

1. mod maps first, by `(priority, kind, numeric id, mod id, map name)`
2. the `baseMap` **last**, always — mod maps add new areas rather than patching
   vanilla tiles, so letting the base map resolve last means any genuine overlap
   goes in favour of vanilla, the direction that cannot corrupt terrain players
   already know.

A mod shipping the base map's own name is an **error**, because it shadows
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

Also available as `pz-dedicated-server --list-maps`. Duplicates are reported
rather than silently resolved; `mapOrder.priority` picks a winner,
`mapOrder.strict` refuses to start, `mapOrder.dedupe` renames losers aside.

For context: the most popular server-config editor for the game — Workshop item
2725216703, "Mod Manager: Server", ~1.4M subscribers — documents that it
explicitly does *not* manage maps or spawn regions, leaving them to hand-editing.

### Secrets that are actually secret

The rendered base `.ini` is a `pkgs.writeText` store path, which is mode `444`
and world-readable. Anything in `settings` is therefore **not a secret** — it is a
plaintext file any local user can `grep` out of `/nix/store`.

So use `secretFiles`, which carries paths rather than values. Evaluation **fails**
if a known-secret key appears in `settings` or `sandbox`, and the renderer filters
those keys independently, so a bare module import cannot leak one either:

```nix
services.project-zomboid-servers.servers.foo = {
  passwordFile = config.age.secrets.pz-join.path;         # → Password=
  secretFiles.RCONPassword = config.age.secrets.pz-rcon.path;
};
```

### Admin accounts that work on Build 42

Build 42 has **no `.ini` key** for the admin login: it is a row in
`Zomboid/db/<servername>.db`, and the only supported way to write it is the
`-adminusername` / `-adminpassword` pair.

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

Meanwhile `whitelist` and `admins` are **Build 41 only** — `Whitelist=` and
`Users=` are not documented Build 42 ini keys, so they are now gated behind
`compatibility.build41`, off by default.

### Spawn points and regions

`<server>_spawnpoints.lua` and `<server>_spawnregions.lua` are two of the four
files PZ lists as necessary for a server to work. Both are generated by PZ when
absent, so the module writes them only when configured, and **removes** them when
emptied — otherwise dropping the option would silently do nothing to a running
server.

---

## Options

Namespace: `services.project-zomboid-servers`. **Full reference, with types and
defaults: [docs/options.md](docs/options.md).** That page is completeness-checked
against `modules/options.nix` in CI, so it cannot fall behind.

Most-used options:

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Master switch. |
| `dataDir` | path | `/var/lib/project-zomboid` | Per-server homes live here. |
| `serverDir` | path | `<dataDir>/server` | Shared SteamCMD install. One per host. |
| `package` | package \| null | `null` | Filled in by the flake. Asserted non-null. |
| `modpacks` | attrsOf submodule | `{}` | Map the catalogue in. |
| `servers` | attrsOf submodule | `{}` | One service + console socket per entry. |
| `steamLogin` | str \| null | `null` | Steam account for Workshop items anonymous cannot fetch (e.g. Brita's Armor Pack). Token cached under `dataDir`. |
| `prune` | bool | `false` | Remove mods no server declares any more — the clean pack switch. Off because it deletes from the shared install. |
| `failOnMissingMods` | bool | `true` | Refuse to finish the install when a Workshop item can't be downloaded. `false` = log-and-skip so servers boot without it. |
| `web` | submodule | disabled | ttyd consoles on loopback. |
| `managementSystem` | submodule | `{ systemd-socket.enable = true; }` | Exactly one of socket / tmux. |

Per server:

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `name` / `description` | str | attr name | `name` drives the `.ini`, lua files and save folder. |
| `modpack` | str \| null | `null` | Inline `workshopMods`/`mods` are **appended** to the pack's. |
| `workshopMods` / `mods` | list | `[]` | Workshop ids vs local mod folder names — not interchangeable. |
| `localMods` | attrsOf path | `{}` | Private mods: `folder-name = directory`, symlinked into `Zomboid/mods` and added to `Mods=`. |
| `map` | str \| null | `null` | `null` = derive from installed mods. Semicolon separated. |
| `baseMap` | str | `Muldraugh, KY` | The vanilla map; always ordered **last**. |
| `mapOrder` | submodule | `{}` | `enable`, `priority`, `strict`, `dedupe`. |
| `spawn.points` / `spawn.regions` | list | `[]` | Rendered to `_spawnpoints.lua` / `_spawnregions.lua`. |
| `defaultPort` / `udpPort` | port | `16261` / `16262` | PZ binds **two** UDP ports; both must be unique. |
| `rconPort` | port | `0` | `0` = RCON off. |
| `settings` / `sandbox` | attrs | `{}` | Any PZ key. **Never a secret** here. |
| `secretFiles` | attrsOf path | `{}` | `Key = path`. The only way to set a secret. |
| `passwordFile` | path \| null | `null` | Sugar for `secretFiles.Password`. Wins if both set. |
| `adminAccount` | submodule \| null | `null` | Creates the Build 42 admin login. |
| `whitelist` / `admins` | listOf str | `[]` | **Build 41 only.** |
| `extraArgs` | listOf str | `[]` | Appended to the command line. No credentials. |
| `upnp` | bool | `false` | PZ defaults this **true**. |
| `selfManagedMods` | bool | `true` | Stop PZ rewriting `Mods=` out from under you. |
| `jvmOpts` | str | `-Xmx4G -Xms2G` | Injected **ahead of** the vendor launcher. |
| `hardware` | submodule | `{}` | cgroup caps; set `memoryMax` above your heap. |

### Two defaults that differ from PZ

- **`upnp = false`.** PZ defaults `UPnP=true`. Automatic port forwarding is a poor
  default for a managed host: it silently punches holes in a firewall that
  `openFirewall` and your own rules deliberately keep closed, and it cannot work
  behind a container at all. Use `openFirewall`.
- **`rconPort` default is `0`** (off), and when you do enable it the suggested
  port is **27016**, not PZ's 27015 — that is Minecraft's default, and this
  module is meant to sit alongside a Minecraft server.

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
that file from scratch renumbers every world on every start. So
`scripts/merge_ini.py` updates only the keys the module owns and leaves every
other line untouched. This is the most important property of the whole design,
and the `prep-roundtrip` check asserts it.

`_SandboxVars.lua` is the opposite case: PZ regenerates it entirely, so the module
owns it outright and renders it to a store file.

### Why `Map=` is the one thing derived at runtime

Every other value is catalogue data and stays in Nix. `Map=` cannot: a map exists
only if an installed mod ships it, and the mod list on disk is not known until
`steamcmd` has run. `scripts/pz_maps.py` resolves it at start, in a total order so
the result is reproducible.

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

tmux is available as an alternative — see
[host recipes](docs/host-recipes.md#the-tmux-console).

---

## Build 42 notes

Things that bite, recorded so they are not re-learned. More in
[troubleshooting](docs/troubleshooting.md).

- **`DoLuaChecksum = true` has a Linux false-positive bug** that blocks clients
  from joining. Both example packs set it to `false`.
- **Admin accounts live in SQLite**, at `Zomboid/db/<servername>.db`, and there
  is no `.ini` key for them — only the `-adminusername`/`-adminpassword` pair.
- **`Whitelist=` and `Users=` are not Build 42 ini keys.** They are Build 41
  leftovers; the whitelist is a table in the same SQLite database. Written only
  under `compatibility.build41`.
- **`SpawnPoint=` is a world coordinate triple** (`x,y,z`), not a preset or an
  index. `SpawnPoint=2` means two metres from the origin.
- The separators differ per key, which is a reliable source of silent
  misconfiguration: `Map=` is **semicolon** separated, `Mods=` is **comma**
  separated, and `WorkshopItems=` is **semicolon** separated.
- `mod.info` ships with CRLF, so validating a downloaded mod with a shell `grep`
  needs `grep -llx -E "id=$mod[[:cntrl:]]?"`.
- Build 42's native Prometheus endpoint only starts if `-DprometheusPort=<port>`
  is in `ProjectZomboid64.json`'s `vmArgs` — and Steam `validate` can replace that
  file, so it is game state, not config you own.
- **No game version is pinned anywhere.** `versions.json` holds only
  non-rotating identifiers — app ids and default ports — precisely because the
  game build rotates. The install is fetched by `steamcmd` at activation time, so
  you get whatever Steam's selected branch currently serves. Pin the *branch*
  (`betaBranch`) if you need reproducibility, and expect flag names to move
  between PZ builds.

## Depot pinning (not done yet)

The game binary is fetched by `steamcmd` into `serverDir` at activation time. It
is **not** a store path, and `versions.json` deliberately contains no depot
`manifestId` or content hash.

Those values rotate on every PZ build, so hand-committing them would be wrong
within days. They need a generated manifest from a real fetcher —
`fetchSteam` from
[`nix-community/steam-fetcher`](https://github.com/nix-community/steam-fetcher)
(note: **not** in nixpkgs). When that lands,
`pkgs/project-zomboid-server` becomes a `fetchurl`-style derivation and
`serverDir` becomes immutable.

Everything else here already assumes the split: the module only ever references
`serverDir` as a path.

---

## Development

```bash
nix flake check            # 14 checks
nix develop                # nixfmt, shellcheck, deadnix, statix, python3

nix run .#pz-modpack -- list
nix run .#pz-modpack -- show vanilla-plus

# Steam Workshop helpers
nix run .#pz-workshop -- emit vanilla-plus               # paste-ready URL list
nix run .#pz-workshop -- resolve pack vanilla-plus       # internal Mod IDs + Mods=/WorkshopItems=
nix run .#pz-workshop -- expand 3812346398 > draft.nix   # collection -> draft pack (mods prefilled)

# Put a pack's mods onto a CLIENT machine (local mods the game loads)
nix run .#pz-client-mods -- vanilla-plus
```

Inspect a pack's effective config without downloading anything:

```bash
nix run .#pz-vanilla-plus -- --data-dir ./d --no-install --print-config myserver
```

The checks:

| Check | What it proves |
| --- | --- |
| `launcher` | The wrapper builds — `writeShellApplication` runs shellcheck at build time, so a shell error fails the build. |
| `modpack-catalogue` | Every pack in `modpacks/` is well-formed plain data. |
| `module-eval` | Two configurations (one plain, one with web consoles + tmux) produce the right units, ports and Exec paths. |
| `nonflake-entry` | `default.nix` really is usable by a consumer without flakes: an attrset, supplies `package`, produces working units. |
| `options-documented` | Every option in `modules/options.nix` appears in `docs/options.md`. |
| `prep-roundtrip` | Runs the real prep script against a seeded world: the merge preserves world identity, runtime overrides win, SandboxVars is written, mods are linked and stale ones unlinked. |
| `secrets-not-in-store` | No secret value appears in any rendered store file, and `secretFileArgs` references paths only. |
| `secret-guard` | The assertion actually **fires** — on a secret in `settings`, in `sandbox`, in a modpack's `defaultSettings` and in its `defaultSandbox` — and stays silent for a config using `secretFiles`. |
| `spawn-and-reset` | The dead Build 42 keys are absent (and present under `build41`), spawn lua renders, **is parsed by a real Lua interpreter**, and `--soft-reset` is scoped to the identity keys. |
| `map-ordering` | Two trees built in opposite orders give identical `Map=`; a non-map directory never leaks in; a duplicate is reported, deterministic and overridable; `--strict` fails; base-map shadowing is an error. |
| `map-pin-clean` | Pinning `Map=` suppresses detection without passing an empty argument. |
| `pz-workshop-helper` | `emit` reproduces every pack's Workshop ids in order, `expand` orders collection children by Steam's own `sortorder`, escapes an interpolation in a title so the draft pack still evaluates, and parses each item's description `Mod ID:` (HTML/bbcode artifacts included) so the draft's `mods` list is prefilled and deduplicated. |
| `pz-client-mods-plan` | The client downloader's `--json` plan matches each pack's item count, defaults to the local-mods target, and rejects an unknown pack — all without touching the network. |

Every one of those bugs is invisible to `nix flake check --no-build` and to
reading the generated file. `nonflake-entry` is the clearest argument: the
non-flake entry point was **completely broken** — `(import (fetchTarball …))` could
not select an attribute off it at all — and `nix flake check` was blind to it,
because nothing in the flake referenced `default.nix`. That is the case for
executing the real code in a check rather than asserting about its shape.

`module-eval` is the interesting one. It asserts in Nix — not shell — that every
server got a service *and* a console socket, that
`ExecStart`/`ExecStartPre`/`ExecStop` are absolute store paths, that `jvmOpts`
actually reached the unit, that the unit the servers `Requires` exists, that no
unit depends on an undefined one, and that the firewall opened exactly the ports
that opted in. Those are all defects that shipped broken in the module this was
ported from.

To iterate on the module without booting a VM, use the same helper the check
uses:

```bash
nix eval --impure --json --expr '
  let flake = builtins.getFlake "path:/home/seanc/Projects/nixos-projectzomboid-servers";
  in (flake.lib.tests.eval { }).config.systemd.services
'
```

`eval` takes `{ config, base, extraImports, extraArgs, pkgs }` — see
[`lib/tests.nix`](lib/tests.nix). It runs `lib.nixosSystem`, so `assertions` and
the real systemd service generation are exercised; only the running-system parts
are skipped.

Note `nix fmt` does not work: `pkgs.nixfmt-rfc-style` is deprecated in current
nixpkgs and fails on `<stdin>` with "unexpected end of input". That is upstream
and reproducible on an untouched checkout. Invoke the formatter binary per file,
as `.github/workflows/ci.yml` does.

### OpenCode tooling

`.opencode/` holds this repo's own OpenCode config — a `pz-modpack` skill and a
`pz-modpack-status` tool. It lives here rather than in a consumer's config
because the knowledge it encodes is *this* project's: the catalogue layout, the
unit names, the `Map=` derivation, and which keys are Build 41 only.

```bash
# read-only, no host needed
pz-modpack-status                          # every pack + the consumer's servers
pz-modpack-status {"modpack":"vanilla-plus"}   # one pack, with Workshop URLs
```

`pz-modpack-status` reads `modpacks/` relative to the repo root, preferring
`nix eval` on `self.modpacks` and falling back to reading the directory when
`nix` cannot answer (offline, cold store, private input). It also detects a
consuming NixOS config — a tree containing
`modules/nixos/projectzomboid-server/servers/` — and reports those servers,
their enable state, chosen pack and inline Workshop mods.

---

## Licence

MIT — see [LICENSE](LICENSE). Note the *game* is not MIT and is not distributed
here; only the Nix plumbing is.