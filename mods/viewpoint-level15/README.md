# Viewpoint Level 15 Skills (`PZViewpointLevel15`)

A small, additive Project Zomboid Build 42 client mod that lets
[Project Viewpoint](https://steamcommunity.com/sharedfiles/filedetails/?id=3809306528)'s
Skills tab draw the eleven-to-fifteen slots that
[Beyond Ten](https://steamcommunity.com/sharedfiles/filedetails/?id=3765241705)
(`BeyondTen`) enables.

## Why this exists

Viewpoint replaces the inventory screen, including the Skills tab, with
`ViewpointInvTabSkills`. That tab hard-codes ten slots:

```lua
-- Viewpoint_InvTabSkills.lua
local LEVELS = 10
...
self.square = math.max(6, math.min(math.floor(self.row * 0.62),
    math.floor(room / LEVELS * 0.8)))
self.step = self.square + math.max(2, math.floor(self.square / 4))
```

Beyond Ten raises the cap to 15 and patches the vanilla
`ISSkillProgressBar.getXpForLvl` / `getPreviousXpLvl`, which Viewpoint calls
for the XP maths — so levels 11-15 already train correctly and their progress
numbers are right. What is missing is the geometry: Viewpoint lays 15 pips into
a row sized for 10, so the row runs about half its width past the XP column.

`LEVELS` is a file-local upvalue and cannot be patched. Its result, however, is
computed from fields the tab keeps on itself (`box`, `nameX`, `nameW`, `row`,
`m.pad`), so this mod wraps `ViewpointInvTabSkills.layout`, re-runs Viewpoint's
own formula with 15 as the slot count, and touches nothing else.

## What it does not fix

`T:squares` loops `1 .. LEVELS` for locked slots and skips the in-progress
square once `bar.level >= LEVELS`, again against its own upvalue. So a level
11-14 skill shows its filled pips but no "in progress" square, and levels 11-15
get no locked hint — which is exactly what Viewpoint already does at level 10.
Hovering past 10 shows the level-10 tooltip (`note` clamps the index). Both are
cosmetic; fixing them means forking Viewpoint's renderer, which this repository
does not do.

## Fail-closed behaviour

- No `BeyondTen` table (mod absent or disabled), or `MAX_LEVEL <= 10`: no wrap.
- No `ViewpointInvTabSkills.layout`: no wrap.
- A `layout` call that leaves out a field this needs: geometry untouched.
- A row that already fits 15 pips (upstream ships a wider grid): untouched.
- `refit` runs under `pcall`, so an upstream change leaves Viewpoint's ten-slot
  render in place instead of breaking it.

## Layout

```text
mods/viewpoint-level15/
  README.md
  42/mod.info
  42/media/lua/client/PZViewpointLevel15/install.lua
```

`checks/default.nix` (`viewpoint-level15`) parses the Lua, asserts the hook
targets and the "no hard `require=`" rule, and drives `fitSlots`/`refit`/`apply`
with plain tables — no running game needed.

## Delivery

The published **PZ Pack Web - viewpoint** Workshop item carries this mod as a
sibling mod root next to the connector, because a pack opts in with
`bundledMods = [ "PZViewpointLevel15" ]` in `modpacks/<pack>.nix`. The id must
also be in the pack's `mods` list, or the game would download it and never load
it. A new bundled mod means the connector item must be re-published before any
host activates the pack: `Mods=` names an id the installed connector does not
ship yet, and `failOnMissingMods` refuses the boot.

```console
$ nix run .#pz-pack-web -- --pack viewpoint --workshop-id 3839932016 \
    --preview ~/Zomboid/Workshop/PZPackWeb-viewpoint/preview.png --force
```

Then re-upload from the in-game Workshop menu. A dedicated server does not
re-fetch a changed item on its own — remove its directory and restart the
install unit, as documented in `docs/pack-web.md`.
