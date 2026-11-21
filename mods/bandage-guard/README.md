# Bandage Guard (`PZBandageGuard`)

An additive Project Zomboid Build 42 mod that fixes two bandaging bugs on a
multiplayer server: an action that throws on the server and silently applies
nothing, and a way to replace a dirty bandage that actually returns the old one.

No vanilla file is copied, overridden or replaced, and it declares no
dependency: every fix is a wrapper on `ISApplyBandage`'s public methods and it
fails closed (does not install) if one of them is missing.

## Bug 1 — bandaging throws on the server and applies nothing

`ISApplyBandage:complete()` dereferences the bandage item without checking it
(`media/lua/shared/TimedActions/ISApplyBandage.lua:112`):

```lua
local bandageLife = ZombRandFloat(...) + self.item:getBandagePower();
```

On a client, `start()` re-resolves the item by id and assigns `nil` when the id
is gone:

```lua
if isClient() and self.item then
    self.item = self.character:getInventory():getItemById(self.item:getID())
end
```

but `isValid()` on a client only returns `itemWasPresent` — "the item was
non-nil when the action was built". The action is therefore not dropped: it runs
to 100 per cent on the client and the server's `complete()` throws.

Observed on the `viewpoint` server (B42 42.22.2), three times in twenty seconds
while one player was re-dressing wounds:

```
[21-11-26 00:32:27.619] ERROR: General ... KahluaThread.flushErrorMessage > -------------------------------------------------------------
attempted index: getBandagePower of non-table: null.
STACK TRACE
	Lua(Vanilla).complete(ISApplyBandage.lua:112)
	Lua((MOD:Extended Burn Treatment)).complete(EBT_ApplyBandage.lua:28)
	Lua((MOD:Water Pipes)).wrapper(ActionWatch.lua:139)
	Lua((MOD:This Is Me - More Character Traits)).complete(TIMMed.lua:15)
[21-11-26 00:32:27.622] ERROR: Action ... NetTimedAction.perform> Exception thrown
```

The result is a bandage that is never applied, a wound that keeps bleeding, and
a stack trace per attempt. The same failure is described from the other side in
`AutoAll_Medicine.lua:498-504`.

The guard drops the action as soon as `start()` loses the item (`isValid()`
returns false, so the queue stops it the way it stops any other invalid action)
and returns `false` from `complete()` if a broken action still reaches the
server — the same "this action did not happen" result vanilla itself uses for a
body part another player is manipulating.

## Bug 2 — replacing a dirty bandage

Vanilla replaces a covering by overwriting it, so the old bandage is destroyed.
The pack used **Replace Dirty Bandages** (`3782220648`) for this. Its action put
the old bandage back inside `perform()`, which only runs on the client — see
`WaterPipes/.../ActionWatch.lua:147-148`, "complete() is where B42 actions change
the world (server and single player); perform() runs on the client". The
returned item therefore existed only in the client's inventory, and using that
local copy later is one of the ways to reach bug 1.

This mod offers the same entry in the health panel's body-part context menu
(right-click an injured part → **Replace Bandage**), for dirty bandages and
self-treatment only. It queues vanilla's `ISApplyBandage` with the old bandage
type in a plain string field:

```lua
action.pzBandageGuardReplaceType = bodyPart:getBandageType()
```

A networked action's fields are sent to the server; a function among them is
not, which is exactly why the old implementation broke. `complete()` then hands
the dirty bandage back where the removal runs, using the same shape as vanilla's
own remove-bandage branch:

```lua
local old = instanceItem(replaceType)
inventory:AddItem(old)
if isServer() then sendAddItemToContainer(inventory, old) end
```

If a client still has Replace Dirty Bandages enabled from an older sync, its
public `canReplace` predicate is switched off so only one entry is shown.

## Layout

```text
mods/bandage-guard/
  README.md
  42/mod.info
  42/media/lua/
    shared/PZBandageGuard/guard.lua             crash guard + old-bandage return
    client/PZBandageGuard/menu.lua              Replace Bandage context entry
    shared/Translate/EN/IG_UI.json
```

`guard.lua` is shared on purpose: the crash happens in `complete()`, which the
server runs. `menu.lua` is client-only.

`Guard.cannotApply` and `Guard.collectCoverings` take plain arguments, so
`checks/default.nix` exercises them (and the three `ISApplyBandage` wrappers
against a fake action class) without a running game.

## Delivery

The published **PZ Pack Web - viewpoint** Workshop item carries this mod as a
sibling mod root next to the connector, because the pack opts in with
`bundledMods = [ "PZBandageGuard" ]` in `modpacks/<pack>.nix`. The id must also
be in the pack's `mods` list, or the game would download it and never load it.

After changing this mod:

```console
$ nix run .#pz-pack-web -- --pack viewpoint --workshop-id 3839932016 \
    --preview ~/Zomboid/Workshop/PZPackWeb-viewpoint/preview.png --force
```

Then re-upload from the in-game Workshop menu. A dedicated server does not
re-fetch a changed item on its own — remove its directory and restart the
install unit, as documented in `docs/pack-web.md`.
