# Mod delivery

Project Zomboid has three ways to get Workshop mods onto a machine. This module
deliberately keeps them separate; conflating them is how a client ends up with a
second copy it never loads, or a dedicated server downloads on behalf of a
machine that already has Steam.

| Mode | Who fetches the mods | Where they land | Managed by this project |
| --- | --- | --- | --- |
| **Dedicated server** | the module's `project-zomboid-install` unit (`steamcmd`) | `workshopDir` — default `<serverDir>/steamapps/workshop/content/108600` | yes |
| **Client-hosted server** (the game's Host button) | the PZ **client**, through Steam | the Steam library that owns the PZ install, e.g. `/mnt/media/SteamLibrary/steamapps/workshop/content/108600` | **config only** |
| **Singleplayer** | the Steam client, through subscriptions | the same Steam library, plus optional `~/Zomboid/mods` local mods | out of scope |

## Dedicated server

One shared install serves every dedicated server on the host. The install unit
runs

```console
steamcmd +force_install_dir <serverDir> +app_update 380870 validate
steamcmd +force_install_dir <workshopDir's library root> \
  +workshop_download_item 108600 <id> …
```

`workshopDir` is an explicit option, defaulting under `serverDir`. It must be
absolute and end in `/steamapps/workshop/content/108600`, because SteamCMD
installs Workshop content relative to a library root and the module derives that
root from the path. Each server then symlinks the items it declares from
`workshopDir` into its own `Zomboid/Workshop/content/108600`; `Map=` is derived
from the same directory. Nothing on a client side reads it.

If `updateOnStart = false`, the dedicated copy is **frozen** at whatever was last
downloaded — steamcmd does not run at boot. The client, by contrast, gets the
current Steam build of an item whenever it subscribes. That is the version-drift
note below.

## Client-hosted server

`servers.<name>.clientHost.enable` renders `~/Zomboid/Server/<name>.ini` and
`~/Zomboid/Server/<name>_SandboxVars.lua` from the same pack the dedicated server
would have used. That is **all** it renders: the module never downloads, copies
or links a mod for the client, never runs steamcmd on the client side, and never
writes into a Steam directory.

With `WorkshopItems=` populated, the game's **Host** button asks Steam to fetch
every item before it reads `~/Zomboid/mods`. Steam puts the content in whichever
library owns the PZ install (for example
`/mnt/media/SteamLibrary/steamapps/workshop/content/108600`), and the client
loads it from Steam's subscription list.

### Why the client cannot load from the server's directory

Project Zomboid's client **enumerates Workshop mods through Steam's subscription
list**. It does not scan `<library>/steamapps/workshop/content/108600`, and it
does not read the dedicated server's `workshopDir`. A symlink farm placed there —
which an earlier revision of this module created — is invisible to the game.
That is why the link-sharing option was removed rather than fixed: there is
nothing on the client that would consume it.

### `SelfManagedMods` is not honoured here

The game's Host flow rewrites `~/Zomboid/Server/<name>.ini` and strips
`SelfManagedMods=true`. The module does not try to prevent that. Every Home
Manager activation re-merges the file and restores the key, so a re-run puts it
back, but the game may strip it again on the next Host. Treat it as a
client-side quirk. On a **dedicated** server the key is honoured normally.

## Singleplayer and local mods

Subscriptions and `~/Zomboid/mods` are a separate, manual mechanism and are out
of scope for this module. Two things are worth keeping distinct:

- **`servers.<name>.localMods`** is for a **dedicated** server: a directory per
  mod, symlinked into `<dataDir>/<name>/Zomboid/mods` and named in `Mods=`.
- **`home.installMods`** is a **deprecated** client-side escape hatch that
  installs a second copy of a pack as local mods in `~/Zomboid/mods`. It is not
  the supported client-host path. If it is enabled, its steamcmd runs with an
  isolated HOME and staging directory under `~/.cache/pz-client-mods`, so it
  cannot read or write `~/.local/share/Steam` or rewrite
  `libraryfolders.vdf`.

## Version drift

The client downloads the **current** Workshop version of an item. A dedicated
server's copy is whatever steamcmd last downloaded, which can be older if
`updateOnStart = false` (or if a pinned `betaBranch` differs). Client and server
can therefore disagree about a mod's version; PZ may warn about mismatched mods
or behave differently. If that matters, keep `updateOnStart = true` (the
default) or re-run `project-zomboid-install` before joining.

## Troubleshooting: `Staging library folder not found`

This is a **Steam client** failure, not a module failure. Steam registers its
libraries in `<steam root>/steamapps/libraryfolders.vdf`; when that registration
and the actual mount disagree — a moved library, a library on a disk that is not
mounted when Steam starts, or a `libraryfolders.vdf` rewritten by something else
— Steam reports the staging library as missing.

The module neither causes nor fixes this. In particular:

- the client-host half no longer touches `libraryfolders.vdf` or any Steam path;
- the deprecated `home.installMods` path runs steamcmd with an isolated HOME, so
  it cannot rewrite the user's library registration;
- the dedicated `workshopDir` is a plain directory the module owns, not a Steam
  library Steam itself needs to know about.

To recover, check that the library is still registered in Steam (Settings →
Storage), that its mount is present and **writable when Steam starts**, and that
`libraryfolders.vdf` names the path that actually exists. Fixing that is outside
this repository.
