# Installing and consuming

Three ways to use this project. Pick by whether your configuration uses flakes
and whether you want servers supervised by systemd or run ad hoc.

| | Flake input | `fetchTarball` | `nix run` |
| --- | --- | --- | --- |
| Supervised by systemd | ✅ | ✅ | ❌ |
| Needs a NixOS host | yes | yes | no |
| Config lives in | your flake | your `configuration.nix` | your shell |
| Use it for | production servers | existing non-flake hosts | trying it out, CI, one-off |

There is deliberately **no Home Manager module.** This manages system services,
a shared Steam install and cgroup limits — all `systemd.services` and `systemd.users`, which
need root. Under Home Manager you would get a module that cannot work. If you
want the CLI without a server, use `nix run .#pz-maps` or `pz-modpack`.

---

## Requirements

- **NixOS**, with flakes unless you use the `fetchTarball` route.
- **`allowUnfree = true`.** Project Zomboid is a Steamworks title: the launcher,
  `steamcmd` and `steam-run` are all unfree. Not negotiable.
- **`x86_64-linux`** for the flake outputs. PZ has no ARM Linux build, so
  `steamcmd`/`steam-run` cannot be instantiated there.

  You *can* still consume the module on an ARM host — it is just Nix code, and it
  will evaluate — but `package` will not build. Run the server elsewhere, or
  build x86_64 under emulation. This is why `systems` is restricted: advertising
  an output that cannot evaluate breaks `nix flake check --all-systems`.
- **Disk.** The dedicated server download is several GB, plus whatever the
  modpacks pull. Saves grow without bound — point `dataDir` at a large disk, not
  at `/var`.
- **RAM.** The default `jvmOpts` is `-Xmx4G -Xms2G`. A heavily modded server wants
  more heap *and* a `hardware.memoryMax` above it; see [hardware](options.md#hardware).
- **Two free UDP ports per server** (16261/16262 by default). PZ binds two.
- **Outbound access to Valve's CDN** on first start, for `steamcmd`.

### Verified compatibility

The module is evaluated by `nix flake check` against `nixos-unstable`, and a
representative two-server configuration was separately evaluated against each of
these, with **zero failed assertions** and both the service and console socket
units produced:

| nixpkgs | Result |
| --- | --- |
| `nixos-24.11` | evaluates clean |
| `nixos-25.05` | evaluates clean |
| `nixos-unstable` | evaluates clean |

It uses no unstable-only options. The stable PZ build it targets is in
[`versions.json`](../pkgs/project-zomboid-server/versions.json); flag names move
between PZ builds, which is why `extraArgs` and `jvmOpts` are free-form strings.

---

## Route 1 — flake input (recommended)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    project-zomboid-servers.url = "github:you/nixos-projectzomboid-servers";
    # Pin it. An unpinned input means your servers can change under you:
    #   project-zomboid-servers.url = "github:you/nixos-projectzomboid-servers/<rev>";
  };

  outputs =
    { nixpkgs, project-zomboid-servers, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        modules = [
          (
            {
              imports = [ project-zomboid-servers.nixosModules.project-zomboid-servers ];

              # Unfree: PZ is a Steamworks title.
              nixpkgs.config.allowUnfree = true;

              services.project-zomboid-servers = {
                enable = true;
                dataDir = "/mnt/data/project-zomboid";

                # The catalogue, or any subset of it.
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
          )
        ];
      };
    };
}
```

`nixosModules.project-zomboid-servers` and `nixosModules.default` are the same
module. The wrapper is what supplies `package`; the bare module file cannot,
because a flake input's module scope has no path back to its own flake.

Then:

```bash
nixos-rebuild switch --flake .#myhost
systemctl start project-zomboid-main
```

The first start downloads the game and the pack's Workshop mods — expect several
GB and a few minutes. `project-zomboid-install.service` is `RemainAfterExit`, so
N servers trigger **one** install at boot, not N.

There is no `map` in that config, and that is deliberate: `Map=` is derived from
the maps the installed mods actually ship, in a deterministic order. Set `map`
only to pin it — see [Maps](options.md#maps).

A complete, `nix flake check`-able example is in
[`examples/single-server`](../examples/single-server).

### What you get from the flake

| Output | Purpose |
| --- | --- |
| `nixosModules.project-zomboid-servers`, `.default` | The module. |
| `modpacks` | The catalogue, as plain data. |
| `lib` | `resolveServer`, `renderIniLines`, `renderSandbox`, `mkProxyUpstreams`, `tests.eval`. |
| `overlays.default` | Adds `pkgs.project-zomboid-server`. |
| `packages.<system>.project-zomboid-server` | The launcher. |
| `apps` | `pz-dedicated-server`, `pz-maps`, `pz-modpack`, `pz-<pack>`. |
| `checks` | Ten checks; `nix flake check` runs them all. |

The overlay is **not required** — the module defaults `package` itself. It exists
for a non-flake consumer, or to reach the wrapper from your own package set.

---

## Route 2 — no flakes

Use `builtins.fetchTarball` and import the module straight out of the tree. The
top level of `default.nix` is a plain attrset precisely so this works:

```nix
# configuration.nix
{
  imports = [
    (import (builtins.fetchTarball {
      url = "https://github.com/you/nixos-projectzomboid-servers/archive/main.tar.gz";
      sha256 = "";  # see below
    })).nixosModules.default
  ];

  nixpkgs.config.allowUnfree = true;

  services.project-zomboid-servers = {
    enable = true;
    modpacks = (import (builtins.fetchTarball { /* … */ })).modpacks;
    servers.main = { modpack = "vanilla-plus"; openFirewall = true; };
  };
}
```

Get the hash non-interactively:

```bash
nix-prefetch-url --unpack https://github.com/you/nixos-projectzomboid-servers/archive/main.tar.gz
```

`default.nix` exports `nixosModules` (both names), `modpacks`, `lib` and
`overlay`. It does **not** export `apps`, `checks`, `packages`, `devShells` or
`lib.tests` — those are per-system flake outputs, and `lib.tests` needs
nixpkgs' full `lib` (which has `nixosSystem`; `pkgs.lib` does not).

`default.nix` reads `<nixpkgs>` for its own `lib`, so this route requires
`nixpkgs` on `NIX_PATH` — that is, the channel. For a pinned revision, fetch
nixpkgs the same way and pass `nixpkgs.pkgs`.

### Do not mix sources

Importing this project **both** as a flake input and via `fetchTarball` declares
every option twice, and NixOS rejects it:

```
The option `services.project-zomboid-servers.web.enable' in
`…-source/modules/options.nix' is already declared in
`/home/you/repo/modules/options.nix'.
```

Pick one per host. The `nonflake-entry` check exercises this route in CI, which
is how the entry point is kept working.

---

## Route 3 — `nix run`, no host configuration at all

For trying it out, CI, or a throwaway server. No NixOS config, no systemd units —
a small shell supervisor owns the console instead.

```bash
# Unmodded
nix run github:you/nixos-projectzomboid-servers#pz-dedicated-server -- myserver

# With a catalogue pack baked in — one app per pack
nix run github:you/nixos-projectzomboid-servers#pz-vanilla-plus -- myserver
```

```
project-zomboid: server    myserver
project-zomboid: modpack   vanilla-plus
project-zomboid: data-dir  /mnt/pz
project-zomboid: install   /mnt/pz/server
project-zomboid: ports     16261 (udp) / 16262 (udp) / 0 (rcon)
project-zomboid: prepared myserver in /mnt/pz/myserver
project-zomboid: starting myserver
```

Your terminal **is** the console. Ctrl-C — or end-of-input — saves and quits
cleanly rather than killing the JVM mid-save.

`--print-config` is the fast loop, and needs no game files at all:

```console
$ nix run .#pz-vanilla-plus -- --data-dir ./d --no-install --print-config myserver
== ./d/myserver/Zomboid/Server/myserver.ini ==
DefaultPort=16261
Map=Muldraugh, KY
WorkshopItems=2625441155;2625840413;2679583791;2634209060;2705410157;2705410286
DoLuaChecksum=false
PVP=true
…
```

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
| `--print-config` | Write and print the config, then exit. |

Other apps:

```bash
nix run .#pz-maps -- --workshop-root ./server/steamapps/workshop/content/108600 --explain
nix run .#pz-modpack -- list
nix run .#pz-modpack -- show vanilla-plus
```

### Why one app per pack rather than a `--modpack` flag

Resolving a pack means merging Nix values and rendering `Key=value` lines. That
has to happen at *evaluation* time, so a runtime flag would mean shipping the
whole catalogue into the script and reimplementing the merge in shell — two
implementations that would drift. One app per pack keeps exactly one.

Which is also why `Map=` is the **only** runtime-derived value: a map exists only
if an installed mod ships it, and installed mods are unknown until steamcmd has
run.

---

## Upgrading

```bash
nix flake update project-zomboid-servers   # or pin a rev by hand
nix flake check                             # ten checks before you rebuild
nixos-rebuild switch --flake .#myhost
```

Read [CHANGELOG.md](../CHANGELOG.md) first — it records every behaviour change,
and a few of them are deliberate corrections rather than additions.

Two things worth knowing before you upgrade a live server:

- **World identity is preserved across upgrades.** `Seed`, `ResetID`,
  `LastModified` and `ServerPlayerID` live in the same `.ini` the module writes,
  and `merge_ini.py` only ever touches keys the module owns. This is the single
  most important property of the design.
- **A PZ beta branch changes the game, not the config.** `betaBranch` is applied
  by the *shared* install, so switching it re-downloads the server for every
  server on that install.

### Rolling back

```bash
git -C ~/.local/share/nixos-config revert <sha>   # or however you manage your config
nixos-rebuild switch
```

Nothing in the module is stored outside `dataDir` and `serverDir`, so reverting
the config reverts the behaviour. The one exception: `mapOrder.dedupe` renames
folders inside the shared install. It is off by default for exactly that reason;
if you enabled it, move the `*.pz-duplicate` folders back by hand.