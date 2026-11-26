# Area Tasks Container Routing (`PZAreaTasksContainerRouting`)

An additive Project Zomboid Build 42 client adapter that makes
[Area Tasks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163745)
(`AreaTasks`) follow
[Manage Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2650547917)
(`manageContainers`) rules for every destination the player has filtered: a
container area, a vehicle area, vehicle storage, **or a single container**.

Without it the two mods never meet. Area Tasks moves whatever the source square
or container holds; Manage Containers says what each container is *for*
(inventory categories plus per-type include/exclude lists). So a route picks up
a whole mixed pile and fills the pantry with axes, or picks up items the target
container will never accept and carries them around for nothing.

## What it changes

| Route | Effect |
| --- | --- |
| Move Items → **Container (Single)** | only items that container's Manage Containers rule accepts are picked up |
| Move Items → **Containers (Area)** | an item is picked up only if some selected destination accepts it; each item is then delivered to a container that accepts it |
| Move Items → **Vehicles (Area)**, and vehicle storage destinations | same rule per vehicle part container |
| Move **ground** items → any of the above | the pickup decision is the same code path; an item with no accepting destination is never picked up |
| container/vehicle source → any of the above | same; the destination rule is applied when each item is chosen, so the source's deferred bookkeeping stays upstream's |

Every item is routed independently, so a mixed load is split cleanly: food goes
to the pantry, axes to the tool crate, and neither ends up in the other. Items
no selected destination accepts are **left where they are**. A single-container
job whose entire selection is rejected starts with Area Tasks' own "no targets"
message after one summary line, instead of silently doing nothing.

**Fails cleanly.** An item that no selected destination accepts stays where it
is; the route continues with the rest. The log names the full type and the
category the preset test compared
(`Base.Dress (ClothBody)`, `Base.Axe (ToolC)`), which is the useful part: it says
which Manage Containers category is missing. Nothing is dropped into an
arbitrary container and the job does not stop with items in hand. Capacity
failures keep upstream's own message.

**Categories are matched by display *and* base category.** Better Sort
(`BetterSortCC`) rewrites `DisplayCategory`, so vanilla `Clothing` becomes
`ClothBody` / `ClothLeg` / `ClothFeet` / `ClothAcc` / `ClothBack` / `ClothBag`,
tools become `ToolC` / `ToolM`, and so on. The ItemType category behind the item
does not change. The adapter accepts an item when **either** its display
category **or** its base category is listed, so a container configured with the
vanilla `Clothing` keeps accepting Better Sort clothing instead of leaving the
whole family behind. (Manage Containers' own "Put in assigned containers" only
compares the display category, which is why this adapter needs the extra term.)
A container configured with only the `Cloth*` subcategories still accepts just
those.

Not touched, deliberately:

- **bag and ground destinations** — there is no Manage Containers preset on a
  worn bag or on the floor, so everything is accepted,
- containers that were renamed but never given categories/include/exclude (they
  keep accepting everything; a routing adapter must never turn one into a black
  hole),
- non-item routes (corpses, furniture, barricades, farming, animals),
- Manage Containers' own actions (`Put in assigned containers`, Shift+Transfer
  All) — they keep their behaviour,
- anything about Area Tasks' targets, paths, tools or timing.

## How

Three seams, no Area Tasks file copied or overridden:

1. `AreaTasks.Tasks.MoveItems[*][*].collectTargets` is wrapped and the ground
   source's `sources[].items` are pruned of items no destination accepts. Area
   Tasks builds ground records there itself, so a ground sweep never starts with
   items that have nowhere to go.
2. `AreaTasks.GroundItemDestinations.canFit(playerObj, container, item,
   reserved)` is wrapped. It is the choice seam for a **single-container** (and
   bag) destination. Refusing an item here leaves it in the source record, which
   Area Tasks defers, so it is never picked up.
3. `AreaTasks.VehicleStorage.reserve(playerObj, containers, item, reservations)`
   is wrapped. It is the choice seam for **area/vehicle** destinations
   (collection pre-check, area delivery and vehicle-storage delivery). The
   wrapper asks each container's rule first and then delegates to the original
   `reserve` one container at a time, so capacity maths and the per-container
   reservation weights stay upstream's; only the *choice* gains the preset test.

Container and vehicle source records are deliberately **not** pruned at
discovery. Area Tasks treats a discovery that returns zero items as
`completed`, and the batching patch has already switched to that endpoint, so
pruning there ended a trip with the accepted load still carried and the target
untouched. Filtering at the choice seam keeps upstream's phase accounting
intact.

The rule itself is `Routing`
(`shared/PZAreaTasksContainerRouting/routing.lua`), which mirrors Manage
Containers' own acceptance test:

```
(category listed AND type not excluded) OR type explicitly included
```

It reads the config through `ISConfigureContainerWindow.getContainerData` and
the shared `MCContainerDataKey` modData entry. A container with an empty rule
(renamed but never given filters), or one whose parent exposes no container
index, accepts everything. Legacy per-player configs are read read-only
(`getStoredUUID(..., false)`), never created.

The rule cache is invalidated by the slot's own sub-table identity: Manage
Containers replaces `containersFilters[slot]` / `exclusiveSelection[slot]` on
save while the parent table stays the same object, so editing a container and
using it in the same session takes effect. A slot that was never configured is
not passed to `getContainerData` at all, because that call writes default tables
into modData and would make Manage Containers treat the container as configured.

## Logging

Every line is prefixed `[PZAreaTasksContainerRouting]`. Installation states
whether Manage Containers was detected and which seams were wrapped; each
compiled container rule prints once per config revision; and each job logs what
the presets did:

```
[PZAreaTasksContainerRouting] Manage Containers: detected, shared key 'manageContainerData'
[PZAreaTasksContainerRouting] installed: reserve+canFit; collectTargets wrapped on 25 route(s)
[PZAreaTasksContainerRouting] crate#2 slot 2: categories=[Food,Medical] include=0 exclude=0
[PZAreaTasksContainerRouting] moveItems.ground.container: 3 destination container(s), filtered: crate#2, fridge#1
[PZAreaTasksContainerRouting] moveItems.ground.container: left Base.Axe (ToolC/Weapon) in place; no destination preset accepts it
[PZAreaTasksContainerRouting] moveItems.ground.container: 12 of 40 source item(s) not accepted by the destination presets
[PZAreaTasksContainerRouting] Base.Bandage (Medical) -> crate#2
```

Per-item placement/rejection is throttled per item type, so a 40-item sweep adds
one line per type, not one per item.

## Failing closed

- No `AreaTasks`, no API version 1, or no `VehicleStorage.reserve` /
  `GroundItemDestinations.canFit`: the adapter logs why and installs nothing.
- No `manageContainers` (or its config reader changed shape): every container
  reads as unconfigured, i.e. upstream behaviour; the installation line says so.
- The destination no longer resolves when an item is chosen (a vehicle door was
  closed, a container unloaded): the item is left where it is rather than
  dropped somewhere arbitrary.
- Presets edited mid-route: area/vehicle delivery re-checks on arrival, so the
  worst case is "left behind with a message", never a wrong-container drop. A
  single-container job applies the preset when it picks each item up; a load
  accepted before the edit keeps upstream's overflow behaviour if the container
  has since stopped accepting it.

Installation is idempotent and re-runs on `OnGameStart`, because Area Tasks (and
this file, after a Lua reload) can be rebuilt between sessions.

Requires Area Tasks (`require=AreaTasks`, `loadModAfter=AreaTasks;manageContainers`).
Manage Containers is optional at runtime.
