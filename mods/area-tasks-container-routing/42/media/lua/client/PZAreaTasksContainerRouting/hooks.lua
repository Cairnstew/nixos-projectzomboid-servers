-- PZAreaTasksContainerRouting/hooks.lua
--
-- Makes Area Tasks follow Manage Containers presets, for every destination that
-- has a filter: a container area, a vehicle (area), and now a single container
-- too.
--
-- Why wrapping three functions is enough:
--   * `collectTargets` for a GROUND source builds the per-square item records
--     itself (it does not go through `ItemSources.records`).
--   * `ItemSources.records` is the one place every container/vehicle source
--     record is built.
--   Both are pruned: an item no selected destination container accepts is never
--   part of the job, so the route does not pick it up, carry it to the
--   destination and leave it behind (or dump it on the floor when the
--   destination is full).
--   * `VehicleStorage.reserve(playerObj, containers, item, reservations)` is
--     the single "which of these containers takes this item?" answer used by
--     the collection pre-check, the area delivery loop and vehicle-storage
--     delivery. Wrapping it keeps the preset *choice* per destination while
--     capacity and reservation bookkeeping stay upstream's.
--
-- Failure shape: filtered items are left where they are with a log line naming
-- the type and the category the preset test compared. A single-container job
-- whose whole selection is filtered reports "no targets" (Area Tasks' own
-- notice) after one summary line, rather than silently doing nothing. An item
-- that a preset rejects at delivery time (presets edited mid-route) is left in
-- inventory; it is never dropped into the wrong container.
--
-- Everything is guarded: no Area Tasks, a different API version, a missing
-- seam, or no Manage Containers at all, and this file does nothing.

require "PZAreaTasksContainerRouting/routing"

PZAreaTasksContainerRouting = PZAreaTasksContainerRouting or { }
local Routing = PZAreaTasksContainerRouting.Routing

local Hooks = PZAreaTasksContainerRouting.Hooks or {
    installed = false, collectWrapped = setmetatable({ }, { __mode = "k" }),
    jobWrapped = setmetatable({ }, { __mode = "k" }),
}
PZAreaTasksContainerRouting.Hooks = Hooks

local NOTICE_INTERVAL_MS = 15000
local LOG_INTERVAL_MS = 5000

local function log(message)
    print("[PZAreaTasksContainerRouting] " .. tostring(message))
end

local logged = { }
local function logEvery(key, message, interval)
    local now = getTimestampMs and getTimestampMs() or nil
    if now and logged[key] and now - logged[key] < (interval or LOG_INTERVAL_MS) then return end
    if now then logged[key] = now end
    log(message)
end

-- Manage Containers exposes the config reader and the shared modData key. If
-- either is absent the mod is not installed (or changed shape), and every
-- container is unconfigured.
local function manageContainers()
    if type(ISConfigureContainerWindow) ~= "table" then return nil end
    if type(ISConfigureContainerWindow.getContainerData) ~= "function" then return nil end
    if type(MCContainerDataKey) ~= "string" or MCContainerDataKey == "" then return nil end
    return ISConfigureContainerWindow
end

-- Legacy configs were stored per player UUID; newer Manage Containers writes
-- the shared key only. Read the UUID read-only (`createOnNil = false`): a
-- routing check must not create data. Cached per player, since it reads an ini.
local legacyUUIDs = setmetatable({ }, { __mode = "k" })

local function legacyUUID(playerObj)
    local window = manageContainers()
    if not window or type(window.getStoredUUID) ~= "function" then return nil end
    local cached = legacyUUIDs[playerObj]
    if cached ~= nil then return cached or nil end
    local ok, uuid = pcall(function()
        return window:getStoredUUID(playerObj, "playerContainerID", false)
    end)
    legacyUUIDs[playerObj] = (ok and type(uuid) == "string") and uuid or false
    return (ok and type(uuid) == "string") and uuid or nil
end

-- The config table for an object, shared key first, legacy per-player second.
local function storedConfig(parent, playerObj)
    local okMeta, modData = pcall(parent.getModData, parent)
    if not okMeta or type(modData) ~= "table" then return nil end
    local shared = modData[MCContainerDataKey]
    if shared ~= nil then return shared end
    local uuid = legacyUUID(playerObj)
    if uuid and type(MCContainerDataPrefix) == "string" then
        return modData[MCContainerDataPrefix .. uuid]
    end
    return nil
end

-- Rule cache. `getContainerData` fills missing keys with defaults, so it must
-- not be called per item, and it must not be called for a slot that was never
-- configured (that writes defaults into modData and makes Manage Containers
-- treat the container as configured). The cache is keyed by the config table
-- and invalidated by the slot's own sub-table identity: Manage Containers
-- replaces `containersFilters[slot]` / `exclusiveSelection[slot]` on save, while
-- the parent table stays the same object.
local cache = setmetatable({ }, { __mode = "k" })

local function containerLabel(container)
    local okType, containerType = pcall(container.getType, container)
    local okParent, parent = pcall(container.getParent, container)
    local index
    if okParent and parent then
        local okIndex, value = pcall(parent.getContainerIndex, parent, container)
        if okIndex and type(value) == "number" then index = value + 1 end
    end
    return string.format("%s#%s", okType and tostring(containerType) or "container", tostring(index or "?"))
end

local function ruleFor(container, playerObj)
    local window = manageContainers()
    if not window then return nil end
    local parent = container and container:getParent()
    if not parent then return nil end
    local okIndex, index = pcall(parent.getContainerIndex, parent, container)
    if not okIndex or type(index) ~= "number" or index < 0 then return nil end
    local slot = index + 1

    local config = storedConfig(parent, playerObj)
    if not config then return nil end
    local filters = config.containersFilters
    local selection = config.exclusiveSelection
    local filterSlot = filters and filters[slot]
    local selectionSlot = selection and selection[slot]
    if filterSlot == nil and selectionSlot == nil then return nil end

    local entry = cache[parent]
    if not entry or entry.config ~= config then
        entry = { config = config, slots = { } }
        cache[parent] = entry
    end
    local cached = entry.slots[slot]
    if cached and cached.filters == filterSlot and cached.selection == selectionSlot then
        return cached.rule
    end

    local okData, data = pcall(window.getContainerData, parent, slot, legacyUUID(playerObj))
    local rule, compiledFilters, compiledSelection
    if okData and type(data) == "table" then
        compiledFilters = data.containersFilters and data.containersFilters[slot]
        compiledSelection = data.exclusiveSelection and data.exclusiveSelection[slot]
        rule = Routing.rule(data.containersFilters, data.exclusiveSelection, slot)
    else
        logEvery("config-error-" .. tostring(slot),
            "could not read Manage Containers data for slot " .. slot .. ": " .. tostring(data))
    end
    entry.slots[slot] = { filters = compiledFilters, selection = compiledSelection, rule = rule }

    log(string.format("%s slot %d: %s", containerLabel(container), slot,
        rule and Routing.describe(rule) or "no preset, accepts everything"))
    return rule
end

local function itemFields(item)
    local okCategory, category = pcall(function()
        return item:getDisplayCategory() or item:getCategory()
    end)
    local okType, fullType = pcall(function() return item:getFullType() end)
    return okCategory and category or nil, okType and fullType or nil
end

-- The destination containers of a job/task definition, in Area Tasks' own
-- resolution order. Returns nil for routes with nothing to filter (bag, ground)
-- or when the destination can no longer be resolved (fail open).
local function destinationContainers(task, playerObj)
    if type(task) ~= "table" then return nil end
    local Sources = AreaTasks and AreaTasks.ItemSources
    if type(Sources) ~= "table" or type(Sources.containers) ~= "function" then return nil end

    local result = { }
    if task.areaDestination then
        if type(task.destinationSelection) ~= "table" then return nil end
        for _, endpoint in ipairs(Sources.endpoints(task.destinationSelection) or { }) do
            for _, container in ipairs(Sources.containers(playerObj, endpoint, false) or { }) do
                result[#result + 1] = container
            end
        end
    elseif task.destinationMode == "vehicle" then
        local Vehicles = AreaTasks.VehicleStorage
        if type(Vehicles) ~= "table" or type(Vehicles.containers) ~= "function" then return nil end
        for _, container in ipairs(Vehicles.containers(playerObj, task.vehicleStorage, false) or { }) do
            result[#result + 1] = container
        end
    elseif task.destinationMode == "storage" and task.destinationContainer then
        local Destinations = AreaTasks.GroundItemDestinations
        if type(Destinations) == "table" and type(Destinations.storageAvailable) == "function"
                and Destinations.storageAvailable(playerObj, task.destinationContainer) then
            result[1] = task.destinationContainer
        end
    else
        return nil
    end
    if #result == 0 then return nil end
    return result
end

-- One rule entry per destination (`false` = unconfigured). nil when nothing is
-- filtered, which also covers "Manage Containers is not installed".
local function destinationRules(task, playerObj)
    local containers = destinationContainers(task, playerObj)
    if not containers then return nil end
    local rules = { }
    for index = 1, #containers do
        rules[index] = ruleFor(containers[index], playerObj) or false
    end
    if not Routing.anyConfigured(rules) then
        logEvery("no-rules-" .. tostring(task.id), string.format(
            "%s: %d destination container(s), none with a Manage Containers filter",
            tostring(task.id), #containers))
        return nil
    end
    local configured = { }
    for index = 1, #rules do
        if rules[index] ~= false then configured[#configured + 1] = containerLabel(containers[index]) end
    end
    logEvery("rules-" .. tostring(task.id), string.format(
        "%s: %d destination container(s), filtered: %s",
        tostring(task.id), #containers, table.concat(configured, ", ")))
    return rules
end

-- Job context. `ItemSources.records` is called from inside the job's queue, but
-- has no job argument; track the per-player job with the lifecycle events, and
-- fall back to wrapping queueTarget on API 1 builds without them.
local jobsByPlayer = { }
local jobTracking = false

local function currentJobFor(playerObj)
    local ok, playerNum = pcall(playerObj.getPlayerNum, playerObj)
    return ok and jobsByPlayer[playerNum] or nil
end

local function installJobTracking(AreaTasks)
    if jobTracking then return end
    jobTracking = true
    if Events and Events.AreaTaskStarted and Events.AreaTaskFinished then
        Events.AreaTaskStarted.Add(function(job)
            if job and job.playerNum then jobsByPlayer[job.playerNum] = job end
        end)
        Events.AreaTaskFinished.Add(function(job)
            if job and jobsByPlayer[job.playerNum] == job then
                jobsByPlayer[job.playerNum] = nil
            end
        end)
        log("job tracking: AreaTaskStarted / AreaTaskFinished")
        return
    end
    local wrapped = 0
    local Registry = AreaTasks.Registry
    for _, task in ipairs(type(Registry) == "table" and Registry.getAll and Registry.getAll() or { }) do
        if type(task.queueTarget) == "function" and not Hooks.jobWrapped[task] then
            local native = task.queueTarget
            task.queueTarget = function(job, target, ...)
                if job and job.playerNum then jobsByPlayer[job.playerNum] = job end
                return native(job, target, ...)
            end
            Hooks.jobWrapped[task] = true
            wrapped = wrapped + 1
        end
    end
    log("job tracking: queueTarget wrappers on " .. wrapped .. " route(s)")
end

local notices = { }

local function notice(playerObj, key, text)
    local now = getTimestampMs and getTimestampMs() or 0
    if notices[key] and now - notices[key] < NOTICE_INTERVAL_MS then return end
    notices[key] = now
    log(text .. " [" .. tostring(key) .. "]")
    if HaloTextHelper and HaloTextHelper.addText then
        pcall(HaloTextHelper.addText, playerObj, text, 1.0, 0.55, 0.2)
    end
end

local function noticeItem(playerObj, item, fullType, category)
    local okName, name = pcall(function() return item:getName() end)
    notice(playerObj, fullType or "?",
        "Area Tasks: no configured container accepts " ..
        tostring(okName and name or "that item") ..
        " (" .. tostring(category or "no category") .. ")")
end

-- Remove items no selected destination accepts. Returns the kept records, the
-- new count, and the number removed.
local function pruneSources(playerObj, label, sources, total, rules)
    local kept, keptCount, types, dropped = { }, 0, { }, 0
    for _, source in ipairs(sources or { }) do
        local items = { }
        for _, descriptor in ipairs(source.items or { }) do
            local category, fullType = itemFields(descriptor.item)
            if Routing.acceptsAny(rules, category, fullType) then
                items[#items + 1] = descriptor
                keptCount = keptCount + 1
            else
                dropped = dropped + 1
                local key = fullType or "?"
                if not types[key] then
                    types[key] = true
                    log(string.format("%s: left %s (%s) in place; no destination preset accepts it",
                        label, key, tostring(category or "no category")))
                end
            end
        end
        source.items = items
        source.next = 1
        if #items > 0 then kept[#kept + 1] = source end
    end
    if dropped > 0 then
        log(string.format("%s: %d of %d source item(s) not accepted by the destination presets",
            label, dropped, total or (dropped + keptCount)))
        notice(playerObj, "left-" .. label, string.format(
            "Area Tasks: %d item(s) left behind - the destination containers' Manage Containers filters do not accept them",
            dropped))
    end
    return kept, keptCount, dropped
end

-- `reserve` with presets. Shape is upstream's: returns the container that took
-- the item and the reservation, or nil.
local routedItems = setmetatable({ }, { __mode = "k" })

local function wrappedReserve(playerObj, containers, item, reservations)
    local original = Hooks.originalReserve
    if type(containers) ~= "table" or #containers == 0 or not item or not manageContainers() then
        return original(playerObj, containers, item, reservations)
    end

    local category, fullType = itemFields(item)
    local rejected = { }
    for index = 1, #containers do
        local container = containers[index]
        if Routing.accepts(ruleFor(container, playerObj), category, fullType) then
            local taken = original(playerObj, { container }, item, reservations)
            if taken then
                local job = currentJobFor(playerObj)
                if job then
                    local seen = routedItems[job]
                    if not seen then seen = { }; routedItems[job] = seen end
                    local key = fullType or "?"
                    if not seen[key] then
                        seen[key] = true
                        log(string.format("%s (%s) -> %s", key, tostring(category or "no category"),
                            containerLabel(container)))
                    end
                end
                return taken
            end
        else
            rejected[#rejected + 1] = index
        end
    end

    -- Distinguish "your presets say no" from "everything is full": only the
    -- former is this adapter's doing, and only when the item would have fitted
    -- somewhere. The throwaway reservations table is not the caller's.
    if #rejected > 0 and original(playerObj, containers, item, { }) then
        noticeItem(playerObj, item, fullType, category)
    end
    return nil
end

local function wrappedRecords(playerObj, endpoint, containers)
    local sources, total = Hooks.originalRecords(playerObj, endpoint, containers)
    local job = currentJobFor(playerObj)
    if not job or type(job.task) ~= "table" or type(sources) ~= "table" then return sources, total end
    local rules = destinationRules(job.task, playerObj)
    if not rules then return sources, total end
    local kept, keptCount = pruneSources(playerObj,
        "job " .. tostring(job.id) .. " " .. tostring(job.task.id), sources, total, rules)
    return kept, keptCount
end

-- Ground sources build their item records inside `collectTargets`, not through
-- `ItemSources.records`; prune there too. Area/vehicle sources have no item
-- records at this point (those are discovered later), so they pass through.
local function wrapCollect(task, native)
    return function(playerObj, bounds, destinationSquare, selectedTask)
        local targets = native(playerObj, bounds, destinationSquare, selectedTask)
        if type(targets) ~= "table" then return targets end
        local rules = destinationRules(selectedTask or task, playerObj)
        if not rules then return targets end

        local filtered = { }
        for _, target in ipairs(targets) do
            local before = 0
            for _, source in ipairs(target.sources or { }) do
                before = before + #(source.items or { })
            end
            if before == 0 then
                filtered[#filtered + 1] = target
            else
                local kept, keptCount = pruneSources(playerObj, tostring((selectedTask or task).id),
                    target.sources, before, rules)
                target.sources = kept
                target.total, target.remaining = keptCount, keptCount
                if keptCount > 0 then filtered[#filtered + 1] = target end
            end
        end
        if #filtered == 0 then
            local taskId = tostring((selectedTask or task).id)
            logEvery("nothing-" .. taskId,
                taskId .. ": every source item was rejected by the destination presets")
            notice(playerObj, "nothing-" .. taskId,
                "Area Tasks: no item in the selection is accepted by the destination containers' Manage Containers filters")
        end
        return filtered
    end
end

function Hooks.install()
    if type(AreaTasks) ~= "table" then
        log("Area Tasks is absent; adapter inert")
        return false
    end
    if AreaTasks.API_VERSION ~= 1 then
        log("unsupported Area Tasks API " .. tostring(AreaTasks.API_VERSION) .. "; adapter inert")
        return false
    end
    local storage = AreaTasks.VehicleStorage
    if type(storage) ~= "table" or type(storage.reserve) ~= "function" then
        log("Area Tasks VehicleStorage.reserve is missing; adapter inert")
        return false
    end
    local sources = AreaTasks.ItemSources
    if type(sources) ~= "table" or type(sources.records) ~= "function" then
        log("Area Tasks ItemSources.records is missing; adapter inert")
        return false
    end

    local installed = { }
    if storage.reserve ~= wrappedReserve then
        Hooks.originalReserve = storage.reserve
        storage.reserve = wrappedReserve
        installed[#installed + 1] = "reserve"
    end
    if sources.records ~= wrappedRecords then
        Hooks.originalRecords = sources.records
        sources.records = wrappedRecords
        installed[#installed + 1] = "records"
    end
    local collected = 0
    local Registry = AreaTasks.Registry
    if type(Registry) == "table" and type(Registry.getAll) == "function" then
        for _, task in ipairs(Registry.getAll()) do
            if type(task.collectTargets) == "function" and not Hooks.collectWrapped[task] then
                task.collectTargets = wrapCollect(task, task.collectTargets)
                Hooks.collectWrapped[task] = true
                collected = collected + 1
            end
        end
    end

    installJobTracking(AreaTasks)

    local window = manageContainers()
    log(string.format("Manage Containers: %s", window
        and ("detected, shared key '" .. MCContainerDataKey .. "'")
        or "not installed or its config reader changed; containers read as unfiltered"))
    log(string.format("installed: %s; collectTargets wrapped on %d route(s)",
        #installed > 0 and table.concat(installed, "+") or "already installed", collected))
    Hooks.installed = true
    return true
end

Hooks.install()
-- Area Tasks (and this file, after a Lua reload) can be rebuilt between
-- sessions; reinstalling is idempotent and refuses a changed API.
if Events and Events.OnGameStart then Events.OnGameStart.Add(Hooks.install) end
