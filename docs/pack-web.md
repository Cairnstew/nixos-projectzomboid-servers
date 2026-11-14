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
3. **Audits at server start.** On `Events.OnGameStart`, it compares the active
   mod list to the manifest and logs missing and extra mods by name. It writes
   nothing, changes nothing, and makes no network calls.
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
    --workshop-root /path/to/steamapps/workshop/content/108600 --strict
```

The connector excludes its own id from `loadModAfter` and from the manifest, so
adding it to the pack does not make it depend on or audit itself.

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
