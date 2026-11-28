# Filibuster Trunk Access Fix (`PZFRTrunkAccess`)

An additive Project Zomboid Build 42 patch for
[Filibuster Rhymes' Certified Used Cars](https://steamcommunity.com/sharedfiles/filedetails/?id=3683878228)
(`B42FRUsedCarsAnimAlpha`). It fixes one function so a Filibuster trailer or
pickup bed can be opened.

No Filibuster file is copied or overridden. The patch is a wrapper on one public
global, `Vehicles.ContainerAccess.FR_VisualTruckBedFiller`, and it does nothing
if Filibuster is absent or renames that function.

## The bug

`BaseVehicle.canAccessContainer(int partIndex, IsoGameCharacter chr)` is Java,
but it asks the vehicle part's container `test` function to decide whether the
player may open it. A Lua `test` must return a boolean; a nil value at that
Lua-to-Java boundary throws

```
java.lang.NullPointerException: Cannot assign field "callFrame" because "a" is null
	at ReturnValues.put(ReturnValues.java:61)
	at LuaJavaInvoker.call(...)
```

with the Lua frame `canAccessContainer`, called from
`ISInventoryPage:refreshBackpacks`. The exception aborts the whole container
loop, so **no** box/trunk/bed button is created for that vehicle and its items
cannot be reached. The same signature appears in the game's own B42 bug reports
as "inaccessible car trunks".

Filibuster's test has a missing final return:

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

When the character stands in the truck-bed area and the part has no door object,
execution falls through. Vanilla's equivalent
(`Vehicles.ContainerAccess.TruckBed`, `media/lua/server/Vehicles/Vehicles.lua`)
ends with `return true` at exactly that point. The old, commented-out revision
of the Filibuster function also returned true.

Observed on the `viewpoint` server (B42 42.22.2) while one player stood at an
open-bed Filibuster trailer:

```
ERROR: General ... Lua((MOD:Unnamed Mod)).canAccessContainer> Exception thrown
	java.lang.NullPointerException: Cannot assign field "callFrame" because "a" is null
	Lua(...).canAccessContainer(MinidoracatVehicleManager_ClientGuards.lua:310)
	Lua(Vanilla).refreshBackpacks(ISInventoryPage.lua:1765)
```

Vehicle Manager only appears because it wraps the same method; it is not the
cause, and removing it does not help.

## What this patch does

- Wraps `Vehicles.ContainerAccess.FR_VisualTruckBedFiller` and calls the
  original in `pcall`.
- Returns the upstream boolean unchanged when it is one.
- Coerces the fall-through `nil` to **true**, matching vanilla
  `ContainerAccess.TruckBed`: there is no door object to block the bed.
- Returns **false** when the original raises, so a broken test fails closed
  instead of granting access.
- Logs one install line and one line the first time a `nil` is coerced.

It is installed at load and retried on `OnGameStart` / `OnServerStarted`, because
the function lives in Filibuster's `media/lua/server` tree, which is loaded on
both the client and a dedicated server. The patch therefore also fixes the
server-side access check used by `BaseCraftingLogic.isContainersAccessible`.

## Scope and limits

- Only `FR_VisualTruckBedFiller` is wrapped. Filibuster's other
  `ContainerAccess.*` predicates all end with an explicit `return true` or
  `return false`; this is the only one that can fall through.
- Non-boolean truthy results are treated as false (`allowed == true`). Only the
  literal `true` grants access.
- If Filibuster updates and returns a boolean itself, the wrapper passes it
  through unchanged.
- If Filibuster is removed, `install()` finds no function and leaves the game
  alone.

## Log lines

```
[PZFRTrunkAccess] wrapped Vehicles.ContainerAccess.FR_VisualTruckBedFiller
[PZFRTrunkAccess] bed access test returned nil; treating the unblocked bed as accessible
```

## Layout

```text
mods/fr-trunk-access/
  42/mod.info
  42/media/lua/shared/PZFRTrunkAccess/hooks.lua   wrapper + deferred install
```

`checks/default.nix` loads the file against a fake `Vehicles` table and proves
the nil / false / true / error / absent-original cases without the game.

## Immediate local workaround

Until the connector item is re-uploaded with this mod, the same fix can be added
to the Workshop copy by inserting `return true` before the closing `end` of
`FR_VisualTruckBedFiller` (`FR_Vehicles.lua:361`). Steam may overwrite it on the
next validation; the bundled mod is the durable form.

## Delivery

Bundled in the **PZ Pack Web - viewpoint** connector item (`bundledMods`), so it
is still a single Workshop item to upload/update.

```console
$ nix build --no-link .#checks.x86_64-linux.fr-trunk-access
$ nix run .#pz-pack-web -- --pack viewpoint --workshop-id 3839932016 \
    --preview ~/Zomboid/Workshop/PZPackWeb-viewpoint/preview.png --force
```
