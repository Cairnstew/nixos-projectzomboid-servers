-- PZBandageGuard/guard.lua
--
-- Additive fix for two bandaging bugs that a dedicated server hits and that
-- nothing in the pack guards against. This file is SHARED on purpose: the
-- damage is done by complete(), which the server runs.
--
-- 1. ISApplyBandage:complete() indexes self.item unconditionally
--    (media/lua/shared/TimedActions/ISApplyBandage.lua:112):
--
--        local bandageLife = ZombRandFloat(..) + self.item:getBandagePower();
--
--    On a client, start() re-looks the item up by id and assigns nil when the
--    id no longer resolves:
--
--        if isClient() and self.item then
--            self.item = self.character:getInventory():getItemById(self.item:getID())
--        end
--
--    but isValid() on a client only reports `itemWasPresent` - "the item was
--    non-nil when the action was built" - so the action is not dropped. It runs
--    to 100 per cent and the server's complete() throws:
--
--        attempted index: getBandagePower of non-table: null
--        Lua(Vanilla).complete(ISApplyBandage.lua:112)
--        Lua((MOD:Extended Burn Treatment)).complete(EBT_ApplyBandage.lua:28)
--
--    Nothing is applied, the wound keeps bleeding, and the player retries. This
--    module drops the action the moment start() loses the item, and fails
--    closed in complete() if a broken action still reaches the server.
--
-- 2. Vanilla "bandages" by overwriting: applying a fresh covering destroys the
--    old one. Replace Dirty Bandages (3782220648) added an entry for this, but
--    its action put the old bandage back inside perform(), which only runs on
--    the client (see WaterPipes ActionWatch.lua:147-148 for the same rule).
--    The item then existed only locally, and using that local copy later is
--    one way to reach bug 1 on the server. The Replace Bandage entry in
--    menu.lua queues the same vanilla action with the old bandage type
--    carried in a plain string field - a networked action's fields are sent to
--    the server, functions are not - and hands the old bandage back through
--    sendAddItemToContainer() on the server, which is where the removal runs.
--
-- Everything below is a wrapper on public ISApplyBandage methods. No vanilla or
-- third-party file is copied, overridden or replaced, and if a wrapped method
-- is missing the guard simply does not install.

PZBandageGuard = PZBandageGuard or { }
local Guard = PZBandageGuard

-- Instance fields. Both are plain values (a boolean and a full item type), so
-- they survive the trip to the server with the rest of the action.
local LOST_ITEM = "pzBandageGuardLostItem"
Guard.REPLACE_FIELD = "pzBandageGuardReplaceType"

--- Could this action ever apply a bandage?
---
--- `doIt` false is "remove bandage", which is valid with no item. `doIt` true
--- without an item is the crash: complete() dereferences self.item.
---
--- Pure, so checks/default.nix drives it without the game.
function Guard.cannotApply(action)
    if type(action) ~= "table" then
        return false
    end
    return action.doIt and action.item == nil
end

local function report(message)
    print("[PZBandageGuard] " .. message)
end

--- Install the wrappers. Idempotent; returns false when ISApplyBandage is not
--- there yet, which the event hooks below retry.
function Guard.install()
    if Guard.installed then
        return true
    end
    if not ISApplyBandage
        or not ISApplyBandage.start
        or not ISApplyBandage.isValid
        or not ISApplyBandage.complete then
        return false
    end

    local vanillaStart = ISApplyBandage.start
    function ISApplyBandage:start()
        vanillaStart(self)
        -- start() has just re-resolved the item by id. If a client-side action
        -- lost it there, remember that: isValid() cannot tell on its own.
        if self.doIt and self.item == nil then
            self[LOST_ITEM] = true
            report("bandage item gone at start; the action will be dropped")
        end
    end

    local vanillaIsValid = ISApplyBandage.isValid
    function ISApplyBandage:isValid()
        if self[LOST_ITEM] then
            return false
        end
        return vanillaIsValid(self)
    end

    local vanillaComplete = ISApplyBandage.complete
    function ISApplyBandage:complete()
        if Guard.cannotApply(self) then
            -- Never let vanilla reach line 112 with a nil item. Returning
            -- false is the same "this action did not happen" result vanilla
            -- uses for a body part another player is manipulating.
            report("bandage item missing at completion; the action failed without applying")
            return false
        end

        -- Read before vanillaComplete: it overwrites the bandage type.
        local replaceType = self[Guard.REPLACE_FIELD]

        local result = vanillaComplete(self)
        if result == false then
            return result
        end

        if replaceType and replaceType ~= "" then
            -- Same shape as vanilla's own remove-bandage branch: a fresh
            -- instance of the recorded type, added authoritatively on the
            -- server and pushed to clients.
            local old = instanceItem(replaceType)
            if old then
                local inventory = self.character:getInventory()
                inventory:AddItem(old)
                if isServer() then
                    sendAddItemToContainer(inventory, old)
                end
            end
        end

        return result
    end

    Guard.installed = true
    report("installed (bandage crash guard + Replace Bandage)")
    return true
end

Guard.install()

-- A dedicated server never raises OnGameStart, and a missing ISApplyBandage at
-- file-load time is possible if another mod reorders the shared scripts.
if Events then
    if Events.OnGameStart then
        Events.OnGameStart.Add(Guard.install)
    end
    if Events.OnServerStarted then
        Events.OnServerStarted.Add(Guard.install)
    end
end
