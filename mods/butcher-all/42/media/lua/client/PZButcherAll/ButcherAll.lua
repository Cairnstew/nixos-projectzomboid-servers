-- PZButcherAll/ButcherAll.lua
--
-- "Butcher All Nearby" for Zombie Butchery (Workshop 3787607014, Mod ID
-- ZombieButchery).
--
-- This is an ADDITIVE hook. It registers one world-context-menu action and
-- drives Zombie Butchery's own ISButcherZombieCorpse / ISBreakZombieSkeleton
-- timed actions. It copies, overrides and reimplements nothing, so an upstream
-- update cannot leave a stale shadow behind and there is no licensing question.
--
-- One corpse at a time, not the whole list queued up front: the mod validates
-- adjacency server-side (ZB.validateButcher / ZB.validateSkeleton), the tool
-- can dull, and a corpse can disappear while the chain runs. Re-checking the
-- next target after every action is what makes those failures recoverable.

require "ISUI/ISWorldObjectContextMenu"
require "TimedActions/ISButcherZombieCorpse"
require "TimedActions/ISBreakZombieSkeleton"
require "PZButcherAll/scan"

PZButcherAll = PZButcherAll or {}
local BA = PZButcherAll

BA.VERSION = "1.0.0"

-- Same radius the batch-butcher mods in the Workshop default to. Euclidean,
-- same floor, nearest first. The cap keeps one context click from becoming a
-- ten-minute chain in a kill zone; the remainder stays for the next click.
BA.RADIUS = 6
BA.MAX_CORPSES = 60

-- Ticks between a finished action and the next target. The action queue is the
-- real synchronisation; this only covers the frame where an action has
-- completed but its world change has not replicated yet.
BA.CHAIN_DELAY = 3
BA.SKELETON_SETTLE = 60

local state = nil

local function log(message)
    print("[PZButcherAll] " .. tostring(message))
end

local function halo(player, text, good)
    local ok = pcall(function()
        if good then
            HaloTextHelper.addGoodText(player, text)
        else
            HaloTextHelper.addBadText(player, text)
        end
    end)
    if not ok then
        log(text)
    end
end

local function text(key, count)
    local value = getText(key)
    if count ~= nil then
        value = value .. " (" .. tostring(count) .. ")"
    end
    return value
end

-- Zombie Butchery owns all four globals used here. Fail closed: if the mod is
-- absent or changed its public surface, the menu entry simply does not appear.
local function ready()
    return ZombieButchery ~= nil
        and type(ZombieButchery.findSharpButcherTool) == "function"
        and type(ZombieButchery.isCorpseOnSquare) == "function"
        and type(ZombieButchery.isAdjacentToCorpse) == "function"
        and ISButcherZombieCorpse ~= nil
        and ISBreakZombieSkeleton ~= nil
        and luautils ~= nil
        and type(luautils.walkAdj) == "function"
end

local function scan(player, skeletons)
    local square = player:getCurrentSquare()
    local cell = getCell()
    if not square or not cell then
        return { }
    end
    return BA.scan.collect(cell, square:getX(), square:getY(), square:getZ(), BA.RADIUS, skeletons)
end

local function tooDark(player)
    return type(ZombieButchery.isTooDark) == "function" and ZombieButchery.isTooDark(player)
end

local function active(player)
    return state ~= nil and state.player == player and state.active
end

local function stop(player, silent)
    if not active(player) then
        return
    end
    state.active = false
    state = nil
    if not silent then
        halo(player, getText("ContextMenu_PZButcherAll_Stopped"), true)
    end
end

local function mergeNearest(fleshed, skeletons)
    local all = { }
    for _, entry in ipairs(fleshed) do
        all[#all + 1] = { body = entry.body, dist = entry.dist, skeleton = false }
    end
    for _, entry in ipairs(skeletons) do
        all[#all + 1] = { body = entry.body, dist = entry.dist, skeleton = true }
    end
    table.sort(all, function(a, b)
        return a.dist < b.dist
    end)

    fleshed, skeletons = { }, { }
    for i = 1, math.min(#all, BA.MAX_CORPSES) do
        local entry = all[i]
        if entry.skeleton then
            skeletons[#skeletons + 1] = { body = entry.body, dist = entry.dist }
        else
            fleshed[#fleshed + 1] = { body = entry.body, dist = entry.dist }
        end
    end
    return fleshed, skeletons
end

local function start(player)
    if state ~= nil and state.active then
        return
    end

    local fleshed = scan(player, false)
    local skeletons = scan(player, true)
    local total = #fleshed + #skeletons
    if total == 0 then
        halo(player, getText("ContextMenu_PZButcherAll_None"), false)
        return
    end
    if tooDark(player) then
        halo(player, getText("ContextMenu_PZButcherAll_TooDark"), false)
        return
    end

    -- Bones need no tool; flesh does. A skeleton-only pile is still worth the
    -- menu entry, so only require the tool when there is something to butcher.
    local tool = nil
    if #fleshed > 0 then
        tool = ZombieButchery.findSharpButcherTool(player)
        if not tool then
            halo(player, getText("ContextMenu_PZButcherAll_NoTool"), false)
            return
        end
    end

    local capped = total > BA.MAX_CORPSES
    if capped then
        fleshed, skeletons = mergeNearest(fleshed, skeletons)
        total = BA.MAX_CORPSES
    end

    if tool and ISWorldObjectContextMenu ~= nil and ISWorldObjectContextMenu.equip then
        ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), tool, true)
    end

    local square = player:getCurrentSquare()
    state = {
        player = player,
        active = true,
        origin = { x = square:getX(), y = square:getY(), z = square:getZ() },
        fleshed = fleshed,
        skeletons = skeletons,
        index = 1,
        phase = (#fleshed > 0) and "flesh" or "skeleton",
        delay = BA.CHAIN_DELAY,
        settle = 0,
    }

    local message = text("ContextMenu_PZButcherAll_Started", total)
    if capped then
        message = message .. " " .. getText("ContextMenu_PZButcherAll_Capped")
    end
    halo(player, message, true)
    log("started player=" .. tostring(player:getUsername()) .. " corpses=" .. tostring(total))
end

local function actionsEmpty(player)
    local actions = player:getCharacterActions()
    return actions == nil or actions:isEmpty()
end

-- Skip entries a previous action already removed. `body:getSquare()` going nil
-- is the cheap test; isCorpseOnSquare is the same check the server uses and
-- catches a corpse that was moved off its square.
local function nextBody(list, index)
    while index <= #list do
        local body = list[index].body
        index = index + 1
        if body and body:getSquare() and ZombieButchery.isCorpseOnSquare(body) then
            return body, index
        end
    end
    return nil, index
end

local function walkAndAdd(player, body, action)
    if not ZombieButchery.isAdjacentToCorpse(player, body) then
        if not luautils.walkAdj(player, body:getSquare()) then
            return false
        end
    end
    ISTimedActionQueue.add(action)
    return true
end

local function step()
    local st = state
    if not st or not st.active then
        return
    end

    local player = st.player
    if not player or player:isDead() or player:getVehicle() then
        st.active = false
        state = nil
        return
    end

    -- A queued walk/butcher action owns the player until it completes.
    if not actionsEmpty(player) then
        st.delay = 0
        return
    end
    if st.delay > 0 then
        st.delay = st.delay - 1
        return
    end

    if st.phase == "flesh" then
        if tooDark(player) then
            stop(player)
            halo(player, getText("ContextMenu_PZButcherAll_TooDark"), false)
            return
        end
        local body
        body, st.index = nextBody(st.fleshed, st.index)
        if body then
            local tool = ZombieButchery.findSharpButcherTool(player)
            if not tool then
                stop(player)
                halo(player, getText("ContextMenu_PZButcherAll_NoTool"), false)
                return
            end
            if walkAndAdd(player, body, ISButcherZombieCorpse:new(player, body, tool)) then
                st.delay = BA.CHAIN_DELAY
            end
            return
        end
        -- The last butcher action creates a skeleton server-side; let it
        -- replicate before rescanning for the bone phase (MP).
        st.phase = "settle"
        st.settle = BA.SKELETON_SETTLE
        return
    end

    if st.phase == "settle" then
        if st.settle > 0 then
            st.settle = st.settle - 1
            return
        end
        local found = BA.scan.collect(
            getCell(),
            st.origin.x,
            st.origin.y,
            st.origin.z,
            BA.RADIUS,
            true
        )
        st.skeletons = { }
        for i = 1, math.min(#found, BA.MAX_CORPSES) do
            st.skeletons[i] = found[i]
        end
        st.index = 1
        st.phase = "skeleton"
        return
    end

    local body
    body, st.index = nextBody(st.skeletons, st.index)
    if body then
        if walkAndAdd(player, body, ISBreakZombieSkeleton:new(player, body)) then
            st.delay = BA.CHAIN_DELAY
        end
        return
    end

    stop(player)
    halo(player, getText("ContextMenu_PZButcherAll_Done"), true)
    log("finished player=" .. tostring(player:getUsername()))
end

local function onTick()
    if not state then
        return
    end
    local ok, err = pcall(step)
    if not ok then
        log("chain error: " .. tostring(err))
        state = nil
    end
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then
        return
    end
    local player = getSpecificPlayer(playerNum or 0)
    if not player or player:getVehicle() or not ready() then
        return
    end

    if active(player) then
        context:addOption(getText("ContextMenu_PZButcherAll_Stop"), player, stop)
        return
    end
    if state ~= nil and state.active then
        return
    end

    local fleshed = scan(player, false)
    local skeletons = scan(player, true)
    local total = #fleshed + #skeletons
    if total == 0 or tooDark(player) then
        return
    end
    if #fleshed > 0 and not ZombieButchery.findSharpButcherTool(player) then
        return
    end
    context:addOption(getText("ContextMenu_PZButcherAll") .. " (" .. tostring(total) .. ")", player, start)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
Events.OnTick.Add(onTick)
if Events.OnGameStart then
    Events.OnGameStart.Add(function()
        state = nil
    end)
end
log("loaded v" .. BA.VERSION)
