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

## Steam collections

A Steam Workshop **collection** is never something a server consumes — PZ reads
`WorkshopItems=` (individual ids). A collection is a source to *expand*:

```bash
nix run .#pz-workshop -- expand <collection-id>   # draft modpacks/<name>.nix
nix run .#pz-workshop -- resolve <collection-id>  # each item's internal Mod ID + Mods=/WorkshopItems=
nix run .#pz-workshop -- emit <pack>              # paste-ready URLs
```

The draft is for review, not to commit blind: a collection cannot tell you which
items are inert on your build (the `viewpoint` pack deliberately drops ZombieBuddy
Extensions). `expand` DOES prefill `mods` from each item's description `Mod ID:`
declaration (the Steam API returns the description text) so the draft is
runnable before the first download — verify it, since an author may also mention
a dependency, and items that do not declare one are flagged in the draft.
There is **no** publish command — Steam has no public write API for collections,
so `emit` is the whole of "generate a collection".

For a **client** (a player's machine), `nix run .#pz-client-mods -- <pack>`
downloads the pack's Workshop items with `steamcmd` and installs them as local
mods in `~/Zomboid/mods` — the form PZ's client loads without a subscription.
Anonymous `steamcmd` cannot fetch every item; add `--login <steam-name>` when it
answers `Access Denied`. On a Home Manager client the same thing is declarative:
`services.project-zomboid-servers.home.installMods = true` (plus `steamLogin`).
It does **not** subscribe — Steam has no API for that — it installs local mods.

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
- **Installs are additive; a pack switch is not clean unless you prune.** The
  shared `steamapps/workshop/content/108600` and each server's link farms only
  ever grow, and because derived `Map=` scans the shared root, a removed mod's
  map keeps being injected. `prune = true` (or `--prune` under `nix run`) makes
  the installed set match the declaration, but only after every item verifies.
- **A gated Workshop item is a missing mod, not a warning.** Anonymous steamcmd
  answers `Access Denied` for mature-content/author-restricted items (Brita's
  Armor Pack). Set `steamLogin` and run `steamcmd +login <account>` once as the
  server user; or supply the folder by hand through `servers.<name>.localMods`.

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
nix run .#pz-workshop -- expand <collection-id>    # collection -> draft pack (mods prefilled)
nix run .#pz-workshop -- resolve collection <id>   # internal Mod IDs + paste-ready ini lines
nix run .#pz-workshop -- resolve pack <name>       # same, for an existing pack
nix run .#pz-workshop -- emit vanilla-plus         # paste-ready Workshop URLs
nix run .#pz-client-mods -- vanilla-plus           # install a pack's mods for a client
```

Full option reference: `docs/options.md`. Host recipes: `docs/host-recipes.md`.