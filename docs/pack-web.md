# Pack web: publishing the connector mod

The connector is a small, per-pack Workshop item that ties a pack's mod list
together. It is **our own code and data only** — no other author's files are
copied, modified or redistributed — which is what makes it publishable.

It does three things:

1. **Loads last.** `loadModAfter=` every Mod ID in the pack. `require=` is
   deliberately absent: a missing or mature-gated item must not stop the
   connector from loading, because that is exactly when its audit matters.
2. **Carries the manifest.** A generated Lua table of every Mod ID the pack
   declares, in the pack's order.
3. **Audits at server start.** On `Events.OnGameStart`, it compares the active
   mod list to the manifest and logs missing and extra mods by name. It writes
   nothing, changes nothing, and makes no network calls.

It adds no items, recipes, maps or UI. Adding it to a world is inert apart from
the ordering and the log line.

## Generate the upload tree

```console
$ nix run .#pz-pack-web -- --pack viewpoint
pz-pack-web: wrote /home/you/Zomboid/Workshop/PZPackWeb-viewpoint
  mod id: PZPackWebViewpoint   linked mods: 480
  workshop.txt: visibility=private, new item (no id)
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
    media/lua/shared/PZPackWeb/manifest.lua
    media/lua/server/PZPackWeb/audit.lua
```

Useful flags:

| Flag | Meaning |
| --- | --- |
| `--out-dir PATH` | Write somewhere other than the default. |
| `--workshop-id ID` | Update an existing Workshop item; omit to create one. |
| `--visibility NAME` | `private` (default), `friendsOnly`, `unlisted`, `public`. |
| `--preview PNG` | Replace the generated placeholder (must be a PNG, ≤512×512). |
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

It does not patch another mod's files. A file override at the same
`42/media/…` relative path is the mechanism, but it is a licensing decision and
a maintenance cost — see [the plan](plans/pack-web.md) §3.2. If a patch is ever
needed, it belongs in this connector's `media/` tree, loaded after its target,
with the target's permission documented.
