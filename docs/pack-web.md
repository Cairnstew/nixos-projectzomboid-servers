# Pack web: publishing the connector mod

The connector is a small, per-pack Workshop item that ties a pack's mod list
together. It is **our own code and data only** — no other author's files are
copied, modified or redistributed — which is what makes it publishable.

It does four things:

1. **Loads last.** `loadModAfter=` every Mod ID in the pack. `require=` is
   deliberately absent: a missing or mature-gated item must not stop the
   connector from loading, because that is exactly when its audit matters.
2. **Carries the manifest.** A generated Lua table of every Mod ID the pack
   declares, in the pack's order.
3. **Audits at server start.** On `Events.OnServerStarted` (dedicated server)
   and `Events.OnGameStart` (a hosted world), it compares the active mod list to
   the manifest and logs missing and extra mods by name. It writes nothing,
   changes nothing, and makes no network calls.

   Both events are wired on purpose, and the first one wins. PZ raises
   `OnGameStart` from the client's `IngameState`, so a connector that registers
   only that event audits nothing on a dedicated server — the server raises
   `OnServerStarted` from `GameServer` instead. That mistake made the first
   published item silent on `server` for a whole day.
4. **Prompts the client.** At the main menu it names the pack mods you are
   missing, opens their Workshop page on click, and can enable the ones you
   already have but have switched off.

It adds no items, recipes, maps or UI of its own. Adding it to a world is inert
apart from the ordering and the log line.

## What the client prompt can and cannot do

| It can | It cannot |
| --- | --- |
| List missing and disabled pack mods by Mod ID | Subscribe or download an item |
| Open an item's Workshop page (`activateSteamOverlayToWorkshopItem`) | Enable a mod that is not downloaded |
| Enable installed mods in `mods.txt` (`setModActive` + `saveModsFile`) | Apply that change without a restart |
| Copy the missing list with Steam links to the clipboard | Add itself to a save's mod list |

`SteamWorkshop.SubscribeItem` and `DownloadItem` are Java-only; no Lua global
reaches them. The one automatic download path is the in-game server-join flow,
which the server's own `WorkshopItems=` already drives — so multiplayer clients
are handled by the game, and this prompt is for single-player and local testing.

The prompt shows once per distinct problem: the counts are stored in
`~/Zomboid/Lua/pzpackweb_<pack>.cfg` when you close it, and again in memory per
session. Install something and it reappears with the new numbers.

## Generate the upload tree

```console
$ nix run .#pz-pack-web -- --pack viewpoint
pz-pack-web: wrote /home/you/Zomboid/Workshop/PZPackWeb-viewpoint
  mod id: PZPackWebViewpoint   linked mods: 480
  workshop.txt: visibility=private, new item (no id)
  client prompt: 478/480 pack mods have a Workshop link
  preview.png is a generated placeholder - replace it with a real 512x512 PNG
```

The default target is `~/Zomboid/Workshop/PZPackWeb-<pack>`, which is where the
in-game uploader looks. The layout is the B42 one:

```text
PZPackWeb-viewpoint/
  workshop.txt
  preview.png
  Contents/mods/PZPackWebViewpoint/42/
    mod.info
    media/lua/shared/PZPackWeb/
      manifest.lua          the pack's Mod IDs
      workshop.lua          Mod ID -> Workshop id (for the prompt)
      state.lua             pure diff helpers, no UI
    media/lua/server/PZPackWeb/audit.lua
    media/lua/client/PZPackWeb/prompt.lua
```

`workshop.lua` is built by scanning an installed Workshop tree, because a
Workshop id and a Mod ID are different namespaces and only `mod.info` connects
them. The default root is `$PZ_WORKSHOP_DIR`, then the first Steam library that
has `steamapps/workshop/content/108600`. A pack mod with no resolvable id is
still listed by the prompt; it just has no page to open.

Useful flags:

| Flag | Meaning |
| --- | --- |
| `--out-dir PATH` | Write somewhere other than the default. |
| `--workshop-id ID` | Update an existing Workshop item; omit to create one. |
| `--visibility NAME` | `private` (default), `friendsOnly`, `unlisted`, `public`. |
| `--preview PNG` | Replace the generated placeholder (must be a PNG, ≤512×512). |
| `--workshop-root DIR` | Installed Workshop root for `workshop.lua` (default: `$PZ_WORKSHOP_DIR`, then auto-detect). |
| `--mod-id ID` | Override the generated `PZPackWeb<Pack>` id. |
| `--force` | Replace an existing staging folder. |

The command refuses to overwrite an existing folder without `--force`, because
the preview and description you edit there are the ones the uploader sends.

## Before uploading

1. **Replace `preview.png`.** The generated one is a deliberate placeholder:
   a 512×512 8-bit PNG. The uploader rejects a missing preview and anything
   larger; it does not reject an ugly one.
2. **Review `workshop.txt`.** `title`, `description=` lines and `tags` are what
   the Workshop page will show. `visibility=private` is the safe default for a
   first run; change it in the file (or pass `--visibility`) before publishing.
3. **Check the linked count.** It should equal the pack's `mods` list. If it is
   zero, the pack has no Mod IDs and the catalogue check would already have
   failed.
4. **Check the Workshop links.** `client prompt: N/M pack mods have a Workshop
   link` — any gap is a pack mod that is not in the installed tree, usually
   because it was added to the catalogue and not downloaded yet. The prompt still
   lists it; only the button is missing.

## Upload

1. Start Project Zomboid.
2. **Main Menu → Workshop → Create/Update**.
3. Select the item folder (`PZPackWeb-viewpoint`).
4. Review the page, set the visibility, and **Upload**.
5. Copy the new Workshop id from the item URL.

`workshop.txt` carries no `id` for a new item on purpose; adding one makes the
uploader update that item instead. Steam has no public write API, so this step
is manual by design.

## Test it before publishing

In this build the client also enumerates a **staged** item: on 2026-11-14 the
connector loaded from `~/Zomboid/Workshop/PZPackWeb-viewpoint/Contents/mods`
with no copy under `~/Zomboid/mods` and no Steam subscription (`loading
PZPackWebViewpoint` / `overrides .` in `~/Zomboid/Logs`). That makes the staging
tree usable for a smoke test, and it is **not** distribution — no other machine
sees anything until the item is published and subscribed.

Copying is still the reliable route if the staged copy is not picked up:

```console
$ mkdir -p ~/Zomboid/mods
$ cp -r ~/Zomboid/Workshop/PZPackWeb-viewpoint/Contents/mods/PZPackWebViewpoint \
        ~/Zomboid/mods/
```

Then Mods → enable **PZ Pack Web - viewpoint**. The same copy works for a local
server (`localMods` symlinks into `Zomboid/mods`).

The prompt only appears when the pack is incomplete, so on a machine with every
pack mod active it stays silent by design. Disable a pack mod, or start
single-player with just the connector enabled, to see the panel. The copy is a
snapshot — re-copy it after regenerating.

Publishing is what makes it downloadable: a staged or copied folder is not, and
the prompt cannot install itself. Until a client subscribes (Workshop page, a
collection, or the server-join prompt driven by `WorkshopItems=`), it has
nothing to run.


## After publishing

Add the item to the pack so the dedicated install downloads it and clients are
prompted for it:

```nix
# modpacks/viewpoint.nix
workshopMods = [
  # …
  { id = "<new-id>"; title = "PZ Pack Web - viewpoint"; } # PZPackWebViewpoint
];

mods = [
  # …
  "PZPackWebViewpoint"
];
```

Then verify the declaration against the installed tree:

```console
$ nix run .#pz-pack-doctor -- --pack viewpoint \
    --workshop-root /path/to/steamapps/workshop/content/108600 \
    --game-version "$(cut -d' ' -f1 ~/Zomboid/version.txt)" --strict
```

The connector excludes its own id from `loadModAfter` and from the manifest, so
adding it to the pack does not make it depend on or audit itself.

### Version gates

`--game-version` is worth passing: PZ refuses a mod whose `versionMin` is above
the running build or whose `versionMax` is below it (`ChooseGameInfo$Mod`), then
removes it from `ServerMods`. The only log line is
`ZomboidFileSystem.loadModAndRequired> required mod "<id>" not found`, which
names the mod but not the reason. Without `--game-version` the doctor still
warns that a declared `versionMax` exists, because such a mod loads today and
disappears on the next game update.

### Verify before the download lands

The doctor reports the new item and `PZPackWebViewpoint` as missing until
steamcmd or a subscription fetches it — correct, but it hides whether the
declared id and the mod id actually agree. Check that separately by building a
root that contains every installed item plus the staged one:

```console
$ R=~/SteamLibrary/steamapps/workshop/content/108600
$ T=$(mktemp -d)
$ for d in "$R"/*/; do ln -s "${d%/}" "$T/$(basename "$d")"; done
$ mkdir -p "$T/<new-id>/mods"
$ cp -r ~/Zomboid/Workshop/PZPackWeb-<pack>/Contents/mods/<ModId> "$T/<new-id>/mods/"
$ nix run .#pz-pack-doctor -- --pack <pack> --workshop-root "$T"
```

Copy, not symlink, for the new item: the doctor's walk does not descend into a
symlinked mod folder. If the only errors left are the ones that predate the
change, the wiring is correct and the real run will pass once the item is
downloaded.

## Updating it

Regenerate into the same folder with the existing id, replace the preview if
needed, and re-upload:

```console
$ nix run .#pz-pack-web -- --pack viewpoint --workshop-id <id> --force
```

Regenerate after any change to the pack's `mods` list; the manifest and the
`loadModAfter` line are snapshots of that list.

## What it deliberately does not do

It does not download or subscribe. `SteamWorkshop.SubscribeItem` is not
Lua-exposed, so the prompt opens the Workshop page and Steam asks the user; the
only automatic download path is the in-game server-join flow driven by
`WorkshopItems=`.

It does not patch another mod's files *by default*. A file override at the same
`42/media/…` relative path is the mechanism — the connector's `loadModAfter`
line is what makes it win — and it is a maintenance cost, not a technical
limit: a stale override silently shadows the upstream fix it was written
against. See [the plan](plans/pack-web.md) §3.2.
