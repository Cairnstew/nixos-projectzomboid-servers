# Area Tasks Container Routing (`PZAreaTasksContainerRouting`)

An additive Project Zomboid Build 42 client adapter that makes
[Area Tasks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163745)
(`AreaTasks`) follow
[Manage Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2650547917)
(`manageContainers`) rules when a route's destination is a **set of containers**.

Without it the two mods never meet. Area Tasks picks, per item, the first
destination container with room and delivers every pickup there; Manage
Containers says what each container is *for* (inventory categories plus per-type
include/exclude lists). So a route drops axes into the container configured for
food simply because it came first in the destination list.

## What it changes

Every Area Tasks route whose destination is a container area, and whose item
choice therefore runs through `AreaTasks.VehicleStorage.reserve`:

| Route | Effect |
| --- | --- |
| Move Items → **Containers (Area)** | each item is collected (and later delivered) only to a container whose Manage Containers rule accepts it |
| Move Items → **Vehicles (Area)**, and vehicle storage destinations | same rule per vehicle part container |
| Move **ground** items → either of the above | the pickup decision is the same code path; an item with no accepting destination is never picked up |

Every item is routed independently, so a mixed load is split cleanly: food goes
to the pantry, axes to the tool crate, and neither ends up in the other.

**Fails cleanly.** An item that no selected destination container accepts (or
that cannot fit anywhere) stays where it is; the route continues with the rest
and one line names the item (`Area Tasks: no configured container accepts
<item>`, once per item type per 15 s). Nothing is dropped into an arbitrary
container and the job does not stop with items in hand. Capacity failures keep
upstream's own message, because the notice fires only when the item would
otherwise have fitted.

Not touched, deliberately:

- **single-container, bag and ground destinations** — there is one destination,
  chosen by the player, so there is nothing to sort; preset violations there are
  the player's call, not the route's,
- non-item routes (corpses, furniture, barricades, farming, animals),
- Manage Containers' own actions (`Put in assigned containers`, Shift+Transfer
  All) — they keep their behaviour,
- anything about Area Tasks' targets, paths, tools or timing.

## How

It wraps one function, `AreaTasks.VehicleStorage.reserve(playerObj, containers,
item, reservations)` — the single place that answers "can this item go into one
of these containers, and which one?" and is used by both the collection
pre-check (given the whole destination list) and the delivery loop (given one
container). The wrapper asks the rule for each container and delegates to the
original `reserve` one container at a time, so capacity maths and the
per-container reservation weights stay upstream's; only the *choice* gains the
preset test.

The rule itself is `Routing` (`shared/PZAreaTasksContainerRouting/routing.lua`),
which mirrors Manage Containers' own acceptance test:

```
(category listed AND type not excluded) OR type explicitly included
```

It reads the config through `ISConfigureContainerWindow.getContainerData` and
the shared `MCContainerDataKey` modData entry, cached per container object and
invalidated when Manage Containers writes a new config table. A container with
an empty rule (renamed but never given filters), or one whose parent exposes no
container index, accepts everything — a routing adapter must never turn a
container into a black hole. Legacy per-player configs are read read-only
(`getStoredUUID(..., false)`), never created.

## Failing closed

- No `AreaTasks`, no API version 1, or no `VehicleStorage.reserve`: the adapter
  logs why and installs nothing.
- No `manageContainers` (or its config reader changed shape): every container
  reads as unconfigured, i.e. upstream behaviour.
- A destination container changed mid-route (presets edited while walking):
  leftovers are re-checked on arrival, so the worst case is "left behind with a
  message", never a wrong-container drop.

Installation is idempotent and re-runs on `OnGameStart`, because Area Tasks (and
this file, after a Lua reload) can be rebuilt between sessions.

Requires Area Tasks (`require=AreaTasks`, `loadModAfter=AreaTasks;manageContainers`).
Manage Containers is optional at runtime.
