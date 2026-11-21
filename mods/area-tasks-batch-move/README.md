# Area Tasks Batched Container Pickup (`PZAreaTasksBatchMove`)

An additive Project Zomboid Build 42 client patch for
[Area Tasks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163745)
(`AreaTasks`).

It changes one route: **Move Items → Containers (Area) → Container (Single)**.
Upstream builds one target per source container, so the character delivers to
the destination after every container. This patch merges those targets so the
character fills carried inventory from several containers, then walks to the
destination once; if inventory fills mid-way it delivers, then continues with
the containers that are left.

## Why the behaviour differs upstream

`collectTargets` for an area container source returns one target per endpoint
(`MoveItems.lua`), each with its own `sources`, and `queueCollection` delivers
when the current target runs out of sources. The ground source already returns
one target with many `sources`, which is why ground pickups batch and container
areas do not.

## What this patch does

- Wraps `collectTargets` for every **area source** whose destination needs a
  trip (`Containers (Area)` / `Vehicles (Area)` → container(s), vehicle(s) or
  ground), merging the per-container targets into one target whose endpoints are
  sorted nearest-first. `Bag` destinations are not wrapped: they deposit
  straight into the worn container, so there is no trip to save.
- Wraps `queueTarget`. When the current endpoint is exhausted and carried
  inventory still has room, it points `target.endpoint` at the next container
  and re-enters Area Tasks' own `discover` phase, keeping `carried`.
- Keeps the `sources` records of every container already visited. Upstream
  replaces that list on each discovery and only recycles leftover items that are
  still in it, so this union is what lets the character leave a container it has
  not fully emptied (for example because the destination had no room) without
  stranding those items.
- If the built-in discovery completes early (an empty container), the wrapper
  starts the next endpoint and returns `defer` instead of retiring the job.

No Area Tasks file is copied, read or overridden. The wrapper is guarded on
`AreaTasks.API_VERSION == 1`, `ItemSources`, `Core.getGroundItemCarryLimit` and
`Registry.getAll`; if any is missing the route stays exactly as upstream.

## Log lines to verify it from a client log

```
[PZAreaTasksBatchMove] hooks installed: area sources batched for moveItems.containers.container, …
[PZAreaTasksBatchMove] collectTargets moveItems.containers.container: 3 container(s)
[PZAreaTasksBatchMove] batching 3 containers into one trip
[PZAreaTasksBatchMove] endpoint drained: carried=4 deferred=0 weight=14.20 limit=27.00 next=3/3 switched=true
```

`switched=false` means the character delivered at that point: the inventory was
within the carry buffer (`min(2, limit*0.05)`) of its limit.

## Scope and limits

- **Area sources only** (`sourceMode == "containers"` or `"vehicles"`), for
  every destination that needs a walk (container, container area, vehicle,
  vehicle area, ground). `Bag` destinations are left alone: they deposit
  straight into the worn container on pickup, so there is no trip to save.
- The progress count is recomputed from the whole trip (undelivered items in
  every visited container plus what is being carried) instead of per container.
- The route is batched unconditionally. There is no setting; remove the mod from
  the pack to restore upstream behaviour.
- Leftovers are only retried while their chunk is loaded. Area Tasks itself
  dereferences `endpoint.object:getSquare()` without a nil check, so a container
  that unloads while the character is at the destination can still make the
  built-in collector fail; that upstream behaviour is unchanged here.

## Upstream behaviour this works around

1. `collectTargets` returns **one target per source container** for area
   sources, so the built-in worker delivers after every container
   (`Tasks/MoveItems.lua:43-55`).
2. `queueCollection` moves an item that does not fit the **destination** into
   `source.deferred` (`:457-469`), and `queueDelivery` only recycles deferred
   items on delivery (`:637-648`). A nearly full destination therefore produces
   one destination trip per container even with empty pockets — the reason the
   first revision of this patch still looked per-container.
3. `ItemSources.containers` assumes the endpoint's chunk is loaded
   (`endpoint.object:getSquare()`, `ItemSources.lua:102-105`), so any route that
   returns to a container it visited earlier can fail with
   `Object tried to call nil` rather than reporting an unavailable source.

## Layout

```text
mods/area-tasks-batch-move/
  42/mod.info
  42/media/lua/
    shared/PZAreaTasksBatchMove/batching.lua  pure ordering/deferred helpers
    client/PZAreaTasksBatchMove/hooks.lua     the two route wrappers
    client/PZAreaTasksBatchMove/init.lua      wiring + retry on game start
```

## Delivery

Bundled in the **PZ Pack Web - viewpoint** connector item
(`bundledMods`), so it is still a single Workshop item to upload/update.

```console
$ nix build --no-link .#checks.x86_64-linux.area-tasks-batch-move
$ nix run .#pz-pack-web -- --pack viewpoint --workshop-id 3839932016 \
    --preview ~/Zomboid/Workshop/PZPackWeb-viewpoint/preview.png --force
```
