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

Per server: `name`, `description`, `modpack`, `workshopMods`, `mods`, `map`,
`defaultPort`, `udpPort`, `rconPort`, `openFirewall`, `public`, `publicName`,
`maxPlayers`, `settings`, `sandbox`, `open`, `whitelist`, `admins`,
`passwordFile`, `jvmOpts`, `autoStart`, `restart`, `managementSystem`,
`hardware`, `extraServiceConfig`, `webConsole`, `port`.

---

## How it fits together

```
project-zomboid-install.service     (oneshot, RemainAfterExit)
  └─ steamcmd +app_update 380870 validate
  └─ steamcmd +workshop_download_item 108600 <id>…   (de-duplicated)

project-zomboid-foo.service        (one per enabled server)
  ├─ ExecStartPre → writes Zomboid/Server/<name>.ini   (MERGED in place)
  │                 writes Zomboid/Server/<name>_SandboxVars.lua (owned)
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
- **Admin accounts live in SQLite**, at `Zomboid/db/<servername>.db`, and the
  first-run password is an **interactive prompt** — not an `.ini` key. `admins`
  grants in-game admin; it does not create the login. If you need a headless
  admin, write the SQLite row yourself.
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

Three checks:

| Check | What it proves |
| --- | --- |
| `launcher` | The wrapper builds — `writeShellApplication` means shellcheck runs at build time, so a shell error fails the build. |
| `modpack-catalogue` | Every pack in `modpacks/` is well-formed plain data. |
| `module-eval` | A two-server configuration produces the right units, ports and Exec paths. |

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