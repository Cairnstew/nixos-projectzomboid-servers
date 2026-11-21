-- PZBandageGuard/menu.lua
--
-- The Replace Bandage entry in the health panel's body-part context menu.
--
-- Vanilla offers Remove Bandage and Bandage. Applying a new covering over an
-- old one overwrites it, so the old bandage is destroyed rather than returned.
-- This entry queues exactly the action vanilla's Bandage option would queue,
-- plus the old bandage type in `PZBandageGuard.REPLACE_FIELD`; guard.lua reads
-- that field in complete() and gives the old bandage back on the server.
--
-- Client-only: the menu is UI. The field it sets is a string, and functions
-- must never be attached to a networked action's instance - see the comment in
-- WaterPipes ActionWatch.lua:126-129.

PZBandageGuard = PZBandageGuard or { }
local Guard = PZBandageGuard

local MENU_TEXT = "IGUI_PZBandageGuard_ReplaceBandage"
local HOOKED = "_pzBandageGuardMenuHooked"

-- guard.lua is shared and therefore loads first, but keep the literal here too:
-- if the shared file were ever missing, queueing a replacement must not be the
-- thing that throws.
local REPLACE_FIELD = Guard.REPLACE_FIELD or "pzBandageGuardReplaceType"

-- How deep a worn bag may nest before the scan stops. Vanilla covers a
-- bandage from any container the player can reach; three levels is every bag
-- inside a backpack inside a vest.
local MAX_DEPTH = 3

--- Add one representative of each usable clean covering in `container`.
---
--- Usable is the game's own test: the item can bandage (isCanBandage) and it
--- has bandage power. Nested containers are walked so a covering in a first
--- aid kit is offered too.
---
--- Takes a container-shaped object, so checks/default.nix can drive it with a
--- stub list instead of a running game.
function Guard.collectCoverings(container, found, seen, depth)
    found = found or { }
    seen = seen or { }
    depth = depth or 0
    if not container or depth > MAX_DEPTH then
        return found
    end

    local items = container:getItems()
    if not items then
        return found
    end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            if item:isCanBandage() and item:getBandagePower() > 0 then
                local fullType = item:getFullType()
                if fullType and not seen[fullType] then
                    seen[fullType] = true
                    found[#found + 1] = item
                end
            end
            if item:IsInventoryContainer() then
                local inner = item:getItemContainer()
                if inner then
                    Guard.collectCoverings(inner, found, seen, depth + 1)
                end
            end
        end
    end

    return found
end

--- Queue the replacement. Mirrors HApplyBandage:perform: move the covering into
--- the main inventory first, then queue the action behind that transfer.
function Guard.replace(panel, bodyPart, item)
    local player = panel and panel.character
    if not player or not bodyPart or not item then
        return
    end
    if not bodyPart:bandaged() or not bodyPart:isBandageDirty() then
        return
    end
    if not item:isCanBandage() or item:getBandagePower() <= 0 then
        return
    end

    local oldType = bodyPart:getBandageType()
    if not oldType or oldType == "" then
        return
    end

    panel:toPlayerInventory(player, item, bodyPart)

    local action = ISApplyBandage:new(player, player, item, bodyPart, true)
    action[REPLACE_FIELD] = oldType
    ISTimedActionQueue.addAfter(nil, action)
end

--- Append the submenu to the context menu the health panel just built.
--- Self-treatment only: on another player the old bandage would have to be
--- handed to the patient, not to the doctor holding the fresh one.
function Guard.addReplaceMenu(panel, bodyPart)
    if not panel or not bodyPart then
        return
    end
    local player = panel.character
    if not player or (panel.otherPlayer and panel.otherPlayer ~= player) then
        return
    end
    if not bodyPart:bandaged() or not bodyPart:isBandageDirty() then
        return
    end

    local coverings = Guard.collectCoverings(player:getInventory())
    if #coverings == 0 then
        return
    end

    local context = getPlayerContextMenu(player:getPlayerNum())
    if not context then
        return
    end

    local option = context:addOption(getText(MENU_TEXT), nil, nil)
    local submenu = ISContextMenu:getNew(context)
    context:addSubMenu(option, submenu)

    for _, item in ipairs(coverings) do
        submenu:addOption(item:getName(), panel, Guard.replace, bodyPart, item)
    end
end

function Guard.installMenuHook()
    if not ISHealthPanel or not ISHealthPanel.doBodyPartContextMenu then
        return false
    end
    if ISHealthPanel[HOOKED] then
        return true
    end

    local vanilla = ISHealthPanel.doBodyPartContextMenu
    ISHealthPanel.doBodyPartContextMenu = function(self, bodyPart, x, y)
        vanilla(self, bodyPart, x, y)
        -- A menu entry must never be able to break the panel's own menu.
        local ok, err = pcall(Guard.addReplaceMenu, self, bodyPart)
        if not ok then
            print("[PZBandageGuard] replace menu failed: " .. tostring(err))
        end
    end
    ISHealthPanel[HOOKED] = true
    return true
end

--- Replace Dirty Bandages was in this pack until 2026-11-21 and is no longer
--- declared. A client that still has it enabled from an older sync would show
--- a second Replace Bandage entry whose action returns the old bandage
--- client-side only. Its menu predicate is public and is looked up on the
--- table at call time, so switching it off keeps one entry and cannot fail.
local function disableSupersededMod()
    local other = _G.DirtyBandageReplacement
    if type(other) == "table" and other.canReplace then
        other.canReplace = function()
            return false
        end
        print("[PZBandageGuard] Replace Dirty Bandages superseded; its menu entry is off")
    end
end

Guard.installMenuHook()
disableSupersededMod()

Events.OnGameStart.Add(function()
    Guard.installMenuHook()
    disableSupersededMod()
end)
Events.OnCreateUI.Add(Guard.installMenuHook)
