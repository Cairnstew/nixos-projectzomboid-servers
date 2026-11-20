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

- Wraps `collectTargets` for the `sourceMode == "containers"` →
  `toMode == "container"` route, merging the per-container targets into one
  target with `endpoints` sorted nearest-first.
- Wraps `queueTarget`. When the current endpoint is exhausted and there is
  capacity left, it points `target.endpoint` at the next container and re-enters
  Area Tasks' own `discover` phase, keeping `carried`.
- If the built-in code completes early (for example an empty container), the
  wrapper starts the next endpoint and returns `defer` instead of retiring the
  job.
- It never leaves an endpoint that still has deferred items: the built-in code
  only recycles those on delivery, so leaving would strand them. In that case it
  lets delivery happen, then continues.

No Area Tasks file is copied, read or overridden. The wrapper is guarded on
`AreaTasks.API_VERSION == 1`, `ItemSources`, `Core.getGroundItemCarryLimit` and
`Registry.getAll`; if any is missing the route stays exactly as upstream.

## Scope and limits

- **Single Container destination only** (`toMode == "container"`). Bag
  destinations are carried, so they already avoid the walk; ground, vehicle and
  area destinations are unchanged.
- **Area container sources only** (`sourceMode == "containers"`). Vehicle area
  sources are analogous and can be added by widening the one condition in
  `hooks.lua` once tested.
- The progress count resets to each new container's item count rather than
  accumulating across the whole job; the work is still correct, the number is
  cosmetic.
- The route is batched unconditionally. There is no setting; remove the mod from
  the pack to restore upstream behaviour.

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
