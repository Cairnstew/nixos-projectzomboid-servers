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

One environment requirement comes with that: the client must run with a UTF-8
locale, because Java derives its filename encoding from it and a few Workshop
items ship a mod folder with a non-ASCII name. A C/POSIX locale (Steam exports
`LC_ALL=C` on some systems) makes the Host flow abort with
`InvalidPathException`. Set `LC_ALL=en_GB.UTF-8 %command%` in the game's Steam
launch options; see [troubleshooting](troubleshooting.md#a-client-host-fails-with-invalidpathexception-non-ascii-mod-folder).
The dedicated server sets `LANG`/`LC_ALL=C.UTF-8` itself.

### Client-side mod preset

The Host flow loads the server's `Mods=` **for the hosted session**. It does not
enable those mods in the client's own Mods menu, so outside a hosted world
(singleplayer, or before pressing Host) the client-side half of a pack —
Viewpoint's own code, UI mods, and so on — is not loaded.

`servers.<name>.clientHost.preset.enable = true` closes that gap. It writes one
named preset into the vanilla Build 42 preset file:

```text
~/Zomboid/Lua/pz_modlist_settings.cfg
!fav!:…
viewpoint:ZombieBuddy;Viewpoint;…;
```

Select it in the Mods menu's Presets dropdown and the client enables the whole
pack. The preset is **merged**, not installed over the file: the player's own
presets and favourites are preserved, a re-run replaces the managed line rather
than appending a second copy, and a file that has not changed is left untouched.
The preset name defaults to the server attribute (`viewpoint`) and can be
overridden with `clientHost.preset.name`.

Two limits are vanilla behaviour, not this module's:

- **Order is not preserved.** `ModSelector.Model:correctAndSaveModOrder`
  rebuilds the load order when a preset is applied, using each mod's `mod.info`
  `require=` only. The pack order is written for readability and sharing, but
  PZ does not promise it. Dependency order *is* preserved.
- **Unavailable mods are skipped.** If an item is not downloaded, applying the
  preset enables what is available and opens the game's “missed mods” window
  listing the rest. Steam owns the download; the Host flow or a subscription
  fetches it.

```nix
servers.viewpoint.clientHost = {
  enable = true;
  preset = {
    enable = true;
    # name = "viewpoint";  # default: the server attribute name
  };
};
```

### Why the client cannot load from the server's directory

Project Zomboid's client **enumerates Workshop mods through Steam's subscription
list**. It does not scan `<library>/steamapps/workshop/content/108600`, and it
does not read the dedicated server's `workshopDir`. A symlink farm placed there —
which an earlier revision of this module created — is invisible to the game.
That is why the link-sharing option was removed rather than fixed: there is
nothing on the client that would consume it.

### `SelfManagedMods` does not exist in Build 42

Build 41 used `SelfManagedMods=true` to stop the game rewriting `Mods=`. The key
was **removed in Build 42**: it appears nowhere in the 42.21 game jar (which
includes the client classes) and is absent from the 144-key `.ini` the server
writes back, so a Build 42 server never reads it — PZ drops it on the next
rewrite. The renderer therefore omits it for a Build 42 target (`legacyBuild41`
still writes it). Nothing is lost: the Host screen rewrites `Mods=` from its own
list either way, and re-running the merge re-applies the declared list.

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
