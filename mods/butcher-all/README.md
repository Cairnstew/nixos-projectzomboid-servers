# Butcher All Nearby (`PZButcherAll`)

A small, additive Project Zomboid Build 42 client mod that adds a **Butcher All
Nearby** world-context-menu action for
[Zombie Butchery](https://steamcommunity.com/sharedfiles/filedetails/?id=3787607014)
(`ZombieButchery`).

It scans a 6-tile radius on the player's floor, nearest first, walks to each
zombie corpse and drives Zombie Butchery's own
`ISButcherZombieCorpse` action, then breaks the skeletons those actions leave
behind with `ISBreakZombieSkeleton`. It processes at most 60 corpses per click;
run it again for the rest. The action is cancellable from the same menu while it
runs.

## Why an add-on and not a patch

This repository's connector is deliberately content-free, and the design notes
in `docs/plans/pack-web.md` §3.2 reject wholesale overrides: they are a derived
copy of another author's code, they rot on every upstream update, and they fail
silently if the target file is renamed. This mod instead depends only on Zombie
Butchery's public globals:

- `ZombieButchery.findSharpButcherTool`
- `ZombieButchery.isCorpseOnSquare`
- `ZombieButchery.isAdjacentToCorpse`
- `ISButcherZombieCorpse` / `ISBreakZombieSkeleton`

If any of them disappears, the menu entry does not appear. Nothing of the
upstream mod is copied, overridden or redistributed.

## Layout

```text
mods/butcher-all/
  README.md
  42/mod.info
  42/media/lua/
    client/PZButcherAll/ButcherAll.lua   context menu + one-at-a-time chain
    shared/PZButcherAll/scan.lua         pure radius scan (unit-tested)
    shared/Translate/EN/ContextMenu.json
```

`scan.lua` takes the `IsoCell` as an argument, so `checks/default.nix` exercises
it with a fake grid without a running game.

## Delivery

The published **PZ Pack Web - viewpoint** Workshop item carries this mod as a
sibling mod root next to the connector, because a pack opts in with
`bundledMods = [ "PZButcherAll" ]` in `modpacks/<pack>.nix`. The id must also be
in the pack's `mods` list, or the game would download it and never load it.

After changing this mod:

```console
$ nix run .#pz-pack-web -- --pack viewpoint --workshop-id 3839932016 \
    --preview ~/Zomboid/Workshop/PZPackWeb-viewpoint/preview.png --force
```

The `--preview` keeps the real 512×512 preview; without it `--force` replaces it
with the generated placeholder.

Then re-upload from the in-game Workshop menu. A dedicated server does not
re-fetch a changed item on its own — remove its directory and restart the
install unit, as documented in `docs/pack-web.md`.

If it ever needs its own Workshop page, generate a separate upload tree with
`pz-pack-web --mod-id PZButcherAll` conventions or a dedicated staging script,
and move the id from `bundledMods` to `workshopMods`.
