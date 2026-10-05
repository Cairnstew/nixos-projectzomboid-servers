---
name: pz-modpack
description: Use when working with Project Zomboid servers or modpacks built on nixos-projectzomboid-servers — adding or editing a pack in the modpacks/ catalogue, resolving Steam Workshop item IDs, wiring services.project-zomboid-servers.servers into a NixOS host config, or debugging a server that boots with no mods, the wrong map, or no console.
---

# Project Zomboid Modpacks & Servers

This project is two deliberately separate things:

- **a NixOS module** — `services.project-zomboid-servers.*` — managing servers:
  systemd units, the shared SteamCMD install, console sockets, the `.ini` and
  `SandboxVars.lua`, spawn files, firewall, resource caps;
- **a modpack catalogue** — `self.modpacks`, plain data with no module — so
  packs can be shared and versioned independently of anybody's configuration.

The server is the native Linux dedicated server (SteamCMD app **380870**),
driven as a headless Java process under `steam-run`. Mods are Steam **Workshop**
items for game app **108600**; modworkshop.net mods are not Workshop items at
all.

## Where things live

| What | Where |
| --- | --- |
| A pack | `modpacks/<name>.nix` here — one file per pack, no registration step |
| Packs as data | `self.modpacks` (flake output) |
| The module | `modules/{project-zomboid-servers,options,config,services}.nix` |
| The module's options | **`docs/options.md`** — completeness-checked by CI |
| Launcher package | `pkgs/project-zomboid-server` (fetches the game) |
| Host recipes | `docs/host-recipes.md` |
| Consumers | their own repo — servers live in *their* config, not here |

The module ships **no modpacks of its own**; the catalogue is separate so a
consumer can ignore it entirely.

## Adding a pack

Drop a file in `modpacks/`. `modpacks/default.nix` discovers files by scanning
the directory, so there is no registration step — the name is the filename
without `.nix`.

```nix
{
  description = "What this pack is for.";

  # Steam Workshop items. Order is preserved and becomes WorkshopItems=.
  workshopMods = [
    { id = "2625441155"; title = "Brita's Armor Pack"; }
  ];

  # Local mod FOLDER names — the id= values from each mod's mod.info,
  # NOT Workshop ids. These become Mods=.
  mods = [ ];

  # .ini keys any server on this pack inherits; the server's own `settings` win.
  defaultSettings = { PVP = true; };

  # SandboxVars any server on this pack inherits; the server's own `sandbox` wins.
  defaultSandbox = { Zombies = 3; };
}
```

Two separators, and mixing them up is the single most common reason a server
boots with no mods:

- `WorkshopItems=` — **semicolon** separated
- `Mods=` — **comma** separated
- `Map=` — **semicolon** separated

## Resolving Workshop item IDs

A mod's Workshop page is
`https://steamcommunity.com/sharedfiles/filedetails/?id=<id>`. Verify each id is
current for the server's build (41 / 42) before pinning it.

## Consuming the module

```nix
inputs.project-zomboid-servers.url = "github:you/nixos-projectzomboid-servers";

# PZ is a Steamworks title: the launcher, steamcmd and steam-run are all unfree.
nixpkgs.config.allowUnfree = true;

services.project-zomboid-servers = {
  enable = true;
  dataDir = "/mnt/data/project-zomboid";   # saves grow without bound

  modpacks = inputs.project-zomboid-servers.modpacks;   # or cherry-pick

  servers.main = {
    modpack = "vanilla-plus";
    defaultPort = 16261;    # UDP
    udpPort = 16262;        # UDP — PZ binds TWO ports per instance
    openFirewall = true;
    jvmOpts = "-Xmx8G -Xms4G";
    hardware.memoryMax = "10G";
  };
};
```

Import `nixosModules.project-zomboid-servers` (not the bare module file): the
wrapper is what supplies `package`, which the module asserts is non-null.

Servers are disabled by default conceptually — a server only gets a unit when
you define one.

## What the module creates

- `project-zomboid-<name>.service` — the server (steam-run + the launcher),
  plus a matching `project-zomboid-<name>.socket` owning its console FIFO.
- `project-zomboid-install.service` — `RemainAfterExit`, so N servers trigger
  **one** SteamCMD fetch of app 380870 at boot rather than N.
- `project-zomboid-<name>-web.service` — optional ttyd console (`web.enable`).

Stopping cleanly sends `quit` down the console so the JVM saves and exits `0`.

## Things that bite

- **`Map=` is derived, not written down.** A map exists only if an installed mod
  ships `media/maps/<name>/`, which is unknown until steamcmd has run. Leave
  `map = null` to derive it, with `baseMap` ordered last. Set `map` explicitly
  only to pin the list.
- **`Whitelist=` / `Users=` are Build 41 only.** Build 42 moved the whitelist
  and the admin login into `Zomboid/db/<server>.db`. Use `adminAccount` for an
  admin login and `compatibility.build41 = true` only if you really run 41.
- **Secrets never go in `settings` or `sandbox`.** The rendered `.ini` is a
  store path — mode 444, readable by every local user. Use `secretFiles.<Key>`
  or `passwordFile`. Evaluation *fails* if you get this wrong.
- **`restart` defaults to `always`.** A clean stop exits `0`, which under
  `on-failure` counts as success and the unit would not come back.
- **World identity lives in the same `.ini`** the module writes (`Seed`,
  `ResetID`, `ServerPlayerID`). `merge_ini.py` only touches keys the module owns,
  which is what makes upgrades preserve your world.

## Checking a pack

`pz-modpack-status` — read-only, no host needed:

```
pz-modpack-status                          # summarize all
pz-modpack-status {"modpack":"vanilla-plus"}   # detail one pack
```

## Without a NixOS host

```bash
nix run .#pz-vanilla-plus -- myserver        # your terminal is the console
nix run .#pz-vanilla-plus -- --list-maps myserver
nix run .#pz-maps -- --workshop-root <dir> --explain
nix run .#pz-modpack -- show vanilla-plus
```

Full option reference: `docs/options.md`. Host recipes: `docs/host-recipes.md`.