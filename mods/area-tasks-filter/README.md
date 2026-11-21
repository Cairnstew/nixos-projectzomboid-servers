# Area Tasks Item Filter (`PZAreaTasksFilter`)

A small, additive Project Zomboid Build 42 client mod that adds a persistent
**whitelist / blacklist** to
[Area Tasks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163745)
(`AreaTasks`) item routes. Filtering is by **item full type** (`Base.Bandage`)
or by **inventory category** (`Weapon`, `Food`, `Clothing`, …), so one entry can
cover every modded and vanilla item in a family.

It is a separate adapter, not a patch: it overrides no Area Tasks file and
copies none of its code. Area Tasks' permissions block altering the mod, and
its own API guide says a separate compatibility mod that `require`s both mods
is the supported shape.

## What it filters

Every Area Tasks route whose source is items:

| Route family | Hook |
| --- | --- |
| Move Items from **ground** (`MoveGroundItems`, its storage/vehicle/bag variants) | wraps each registered ground task's `collectTargets` and prunes `sources[].items` |
| Move Items from **containers, container areas, vehicles, vehicle areas** | wraps `AreaTasks.ItemSources.eligible`, the predicate every container record is built with |
| Bag destinations | same as their source route |

Destination selection is not filtered — only what is picked up/moved. Corpses,
furniture pickup, barricades and the other non-item tasks are untouched.

Both hooks fail closed: if Area Tasks is absent, its API version is not 1, or
the expected task fields disappear, the wrapper is not installed and the menu
says `Unsupported Area Tasks version: filter inert`. The editor still opens, so
the failure is visible rather than silent.

## Using it

1. Right-click the world (or an item in a container) → **Area Tasks Filter**.
   The submenu shows the current mode and how many types are listed, plus
   **Edit filter...** and **Clear filter**.
2. In the editor choose **Off**, **Only listed** (whitelist) or **Exclude
   listed** (blacklist). Type to search; click a row to toggle it. **Categories**
   appear at the top of the list (tinted, `[category]`) and cover every item in
   that inventory category, so `Weapon` is one row instead of hundreds.
   **Select results** / **Clear results** bulk-toggle the current search.
3. With an empty search the list shows what you have listed (categories first),
   so reviewing or removing entries is one click each.
4. For a single item, right-click it and use **Only this item type** /
   **Exclude this item type**, or the coarser **Only this category** /
   **Exclude this category**; that is the one-click "only pick up weapons" path.

The filter is per client and persists in `Zomboid/Lua/PZAreaTasksFilter.txt`
(survives restarts, single-player and multiplayer). It is applied when an Area
Tasks job starts; changing it mid-job affects the next job, not the current one.
The server-side Distance/Area options are unrelated and stay in the sandbox.

## Layout

```text
mods/area-tasks-filter/
  README.md
  42/mod.info
  42/media/lua/
    shared/PZAreaTasksFilter/filter.lua   pure state/matcher/serialiser (unit-tested)
    shared/PZAreaTasksFilter/i18n.lua     fallback-aware key lookup
    shared/Translate/EN/UI.json
    client/PZAreaTasksFilter/state.lua    file persistence + InventoryItem predicate
    client/PZAreaTasksFilter/hooks.lua    the two Area Tasks wrappers
    client/PZAreaTasksFilter/ui.lua       ISUI editor panel
    client/PZAreaTasksFilter/menu.lua     world/inventory context-menu entry
    client/PZAreaTasksFilter/init.lua     wiring + start confirmation
```

`filter.lua` has no PZ globals, so `checks/default.nix` exercises the matcher
and file format with plain Lua 5.1. The hooks and panel are client-Lua only and
follow the stock `ISPanel`/`ISButton`/`ITextEntryBox`/`ISScrollingListBox`
patterns; they are exercised in-game, not by the check.

```console
$ nix build --no-link .#checks.x86_64-linux.area-tasks-filter
```

## Delivery

The published **PZ Pack Web - viewpoint** Workshop item carries this mod as a
sibling mod root next to the connector, because `viewpoint.nix` opts in with
`bundledMods = [ "PZButcherAll" "PZAreaTasksFilter" ]`. The id must also be in
the pack's `mods` list, or the game would download it and never load it.

After changing this mod:

```console
$ nix run .#pz-pack-web -- --pack viewpoint --workshop-id 3839932016 \
    --visibility public --force
```

`--workshop-id` and `--visibility` are not optional on a re-run: without the id
the tool now refuses, and without the visibility it would write `private`.

Then re-upload from the in-game Workshop menu. A dedicated server does not
re-fetch a changed item on its own — remove its directory and restart the
install unit, as documented in `docs/pack-web.md`.
