# Filibuster Trunk Access Fix (`PZFRTrunkAccess`)

An additive Project Zomboid Build 42 mod that keeps a Filibuster Rhymes'
[Certified Used Cars](https://steamcommunity.com/sharedfiles/filedetails/?id=3683878228)
(`B42FRUsedCarsAnimAlpha`) trailer or pickup bed openable. Two unrelated defects
hide that container; one is Filibuster's, one is the engine's.

No file is copied or overridden. The mod wraps two public Lua seams and is inert
when either target is absent:

- `Vehicles.ContainerAccess.FR_VisualTruckBedFiller` — Filibuster's bed predicate;
- `BaseVehicle.canAccessContainer` on the class metatable — the seam
  `ISInventoryPage:refreshBackpacks` and Area Tasks call through.

## Defect 1 — Filibuster's test has no final return

`BaseVehicle.canAccessContainer(int partIndex, IsoGameCharacter chr)` is Java, but
it asks the part's container `test` function (Lua) whether the player may open it,
and it expects a boolean.

Filibuster's test falls off the end:

`mods/B42FRUsedCarsAnimAlpha/42/media/lua/server/FR_Vehicles.lua:317-361`

```lua
    if bedAttachmentUserdata and vehicle:isInArea(bedAttachmentUserdata:getArea(), chr) then
        local trunkDoor = vehicle:getPartById("TrunkDoor") or vehicle:getPartById("DoorRear")
        if trunkDoor and trunkDoor:getDoor() then
            ...
        end
    else
        return false
    end
    -- DebugLog.log("...: Something went wrong. Shit.")
end   -- ← returns nil
```

When the character stands in the bed area, nothing blocks the bed and the part
has no door object, the function returns nil. Vanilla's equivalent
(`Vehicles.ContainerAccess.TruckBed`, `media/lua/server/Vehicles/Vehicles.lua`)
ends with `return true` at exactly that point, and the old commented-out revision
of Filibuster's function did too.

**This is a real bug, but it is not the source of the crash below.** It is a
latent nil at a boolean boundary; keeping it fixed is still correct and cheap.

## Defect 2 — the engine recycles a call's return-value slot

The observed failure is

```
java.lang.NullPointerException: Cannot assign field "callFrame" because "a" is null
	at ReturnValues.put(ReturnValues.java:61)
	at LuaJavaInvoker.call(LuaJavaInvoker.java:185)
	at KahluaThread.callJava(KahluaThread.java:178)
	Lua(...).canAccessContainer(MinidoracatVehicleManager_ClientGuards.lua:310)
	Lua(Vanilla).refreshBackpacks(ISInventoryPage.java:1765)
```

Read the shipped `projectzomboid.jar` (42.22.2) and it is unambiguous:

- `ReturnValues.put(ReturnValues a)` line 61 is `a.callFrame = null` — so the
  argument itself was **null**.
- The only caller is `LuaJavaInvoker.call`, line 185:
  `ReturnValues.put(methodArguments.getReturnValues())`.
- `LuaJavaInvoker.prepareCall` always sets that field (`setReturnValues(...)`),
  and only `MethodArguments.put(...)` clears it (line 17: `returnValues = null`)
  before pooling the instance.
- Both `ReturnValues` and `MethodArguments` are handed out of **static**
  `ArrayList` pools with no in-use guard.

So a `MethodArguments` instance reached a second frame while the first was still
using it; the second completion nulled the field the first returns through. That
is why it fires intermittently (about twice a second while the seam is hot)
rather than deterministically, and why a nil result from a container `test` is
*not* the cause — a nil boolean would fail differently, inside the method.

The same trace in the same client logs hits unrelated call sites, which is the
signature of an engine defect rather than a mod's:

| Log | Innermost mod frame |
| --- | --- |
| `2026-11-28_19-19` | `canAccessContainer` (Vehicle Manager seam) → `refreshBackpacks` |
| `2026-11-28_08-45` | `ISBuildIsoEntity:isValidPerSquare` → `Barrier.lua`, `DirtFloorPlacementFix` |
| `2026-11-27_17-15` | Area Tasks `bagChoices` → `AreaTasksMenuGuard.onError` |
| `2026-11-23_11-54` | AutoAll `collectWet` → `addCleanMenu` |

The game's own B42 bug reports carry the identical message ("inaccessible car
trunks", "NullPointerException when shutting off vehicle"), including with no mods
loaded.

Consequences on this seam:

- `ISInventoryPage:refreshBackpacks` aborts mid-loop, so **no** container button
  is created for that vehicle — the bed simply is not there.
- Area Tasks' `Storage.containers` reaches the same call from
  `LuaTimedActionNew.valid`; the throw makes the job stop before its first
  transfer (`job 1 finished: stopped completed=0`).

The throw escapes into Lua as a normal error, so a Lua `pcall` can hold it (the
game's own `LuaTimedActionNew.valid` and `UIElement.render` do exactly that and
carry on) — it cannot be prevented from Lua, only tolerated.

## What this mod does

Filler wrapper (`installFillerAccess`):

- returns the upstream boolean unchanged;
- coerces the fall-through nil to **true**, matching vanilla
  `ContainerAccess.TruckBed` (no door object blocks the bed);
- returns **false** if the original raises, so a broken test fails closed;
- logs one install line and one line the first time a nil is coerced.

Seam wrapper (`installVehicleAccess`):

- returns the upstream boolean unchanged;
- if the call throws, answers in Lua instead of letting the error abort the
  caller (logged once, then every 50th, with the error text);
- when Vehicle Manager (`MVM.storageAllowed`) is loaded, its ownership/rental
  answer is the authority — this wrapper only supplies the missing boolean;
- otherwise cargo fails open **only** for a character on foot inside the part's
  own interaction area (`part:getArea()`), which is vanilla
  `TruckBedOpen`/`GasTank` semantics;
- never fails open for a seat (`getContainerSeatNumber() >= 0`) or the
  `GloveBox`, and never for a part without a container;
- installs once per seam, so repeated retries do not stack wrappers.

The seam wrapper is re-claimed on `OnGameStart` / `OnServerStarted` because
Filibuster and Vehicle Manager replace the same metatable entry at mod load.

## Scope and limits

- Only `FR_VisualTruckBedFiller` among Filibuster's predicates is wrapped; the
  rest end with an explicit `return true` / `return false`.
- Only the literal `true` grants access; a truthy non-boolean does not.
- The seam fallback grants cargo access when the engine already failed to answer
  — a broken call cannot lock a legitimate player out, at the cost of a rare
  fail-open for cargo while the bridge is throwing.
- If Filibuster, Vehicle Manager or the class exposer is absent, the relevant
  wrapper is not installed and the game behaves exactly as before.

## Log lines

```
[PZFRTrunkAccess] wrapped Vehicles.ContainerAccess.FR_VisualTruckBedFiller
[PZFRTrunkAccess] guarded BaseVehicle.canAccessContainer
[PZFRTrunkAccess] bed access test returned nil; treating the unblocked bed as accessible
[PZFRTrunkAccess] vehicle access bridge failed (1 time(s)); answering in Lua: ...
```

## Layout

```text
mods/fr-trunk-access/
  42/mod.info
  42/media/lua/shared/PZFRTrunkAccess/hooks.lua   both wrappers + deferred install
```

`checks/default.nix` loads the file against fake `Vehicles`, `BaseVehicle` and
class-metatable tables and proves every branch without the game: nil / false /
true / error / absent original, seam pass-through, bridge failure for cargo,
seat and glove box, Vehicle Manager precedence, and install idempotence.

## Immediate local workaround

The nil in defect 1 can also be patched in place by inserting `return true`
before the closing `end` of `FR_VisualTruckBedFiller`
(`FR_Vehicles.lua:361`). Steam may overwrite it on the next validation, and it
does **not** address defect 2; the bundled mod is the durable form.

## Delivery

Bundled in the **PZ Pack Web - viewpoint** connector item (`bundledMods`), so it
is still a single Workshop item to upload/update.

```console
$ nix build --no-link .#checks.x86_64-linux.fr-trunk-access
$ nix run .#pz-pack-web -- --pack viewpoint --workshop-id 3839932016 \
    --visibility public --preview ~/Zomboid/Workshop/PZPackWeb-viewpoint/preview.png --force
```
