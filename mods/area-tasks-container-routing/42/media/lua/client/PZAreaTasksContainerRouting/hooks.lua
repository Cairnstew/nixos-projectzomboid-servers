-- PZAreaTasksContainerRouting/hooks.lua
--
-- Makes Area Tasks' container destinations follow Manage Containers presets.
--
-- The route that matters is "Move Items -> Containers (Area)" (and the same in
-- Vehicles (Area)): Area Tasks picks, per item, the first destination container
-- with room, and delivers every pickup to the container it chose. Manage
-- Containers, on the other hand, says what each container is *for* (categories
-- and per-type include/exclude lists). Without this adapter the two never meet:
-- a route drops axes into the container configured for food simply because it
-- came first.
--
-- Why wrapping one function is enough:
--   * `AreaTasks.VehicleStorage.reserve(playerObj, containers, item,
--     reservations)` is the single place that answers "can this item go into
--     one of these containers, and which one?". It is used by the collection
--     pre-check (with the whole destination list, deciding whether an item is
--     picked up at all), by the area delivery loop (one container at a time),
--     and by vehicle-storage delivery. Searching a list in order, first fit,
--     recording the reservation weight.
--   * Delegating to it per single container keeps its capacity and reservation
--     bookkeeping untouched; only the *choice* of container gains the preset
--     test. So capacity failures still behave exactly as upstream.
--
-- Failure shape: an item no destination container accepts is simply never
-- picked up (collection) or left behind (delivery), and the player gets one
-- line naming it - the route continues with the rest instead of stopping with
-- items in hand or dropping them somewhere wrong. Capacity-only stops keep
-- upstream's own message, which is why the notice is emitted only when the
-- item would otherwise have fitted.
--
-- Everything is guarded: no Area Tasks, a different API version, a missing
-- `reserve`, or no Manage Containers at all, and this file does nothing.

require "PZAreaTasksContainerRouting/routing"

PZAreaTasksContainerRouting = PZAreaTasksContainerRouting or { }
local Routing = PZAreaTasksContainerRouting.Routing

-- The file can be re-executed (Lua reload between sessions, or a second world
-- load). Reuse the persisted state instead of stacking a wrapper on our own.
local Hooks = PZAreaTasksContainerRouting.Hooks
if Hooks and Hooks.wrapped and type(AreaTasks) == "table" and
        type(AreaTasks.VehicleStorage) == "table" and
        AreaTasks.VehicleStorage.reserve == Hooks.wrapped then
    return
end
Hooks = Hooks or { installed = false, original = nil }
PZAreaTasksContainerRouting.Hooks = Hooks

local NOTICE_INTERVAL_MS = 15000

local function log(message)
    print("[PZAreaTasksContainerRouting] " .. tostring(message))
end

-- Manage Containers exposes the config reader and the shared modData key. If
-- either is absent the mod simply is not installed (or changed shape), and
-- every container is unconfigured.
local function manageContainers()
    if type(ISConfigureContainerWindow) ~= "table" then return nil end
    if type(ISConfigureContainerWindow.getContainerData) ~= "function" then return nil end
    if type(MCContainerDataKey) ~= "string" or MCContainerDataKey == "" then return nil end
    return ISConfigureContainerWindow
end

-- Rule cache. `getContainerData` fills missing keys with defaults, so it must
-- not be called per item; the cache is keyed by the parent IsoObject and
-- invalidated when Manage Containers writes a new config table (the configure
-- window replaces the table on save, so identity is a reliable revision mark).
local cache = setmetatable({ }, { __mode = "k" })

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

local function ruleFor(container, playerObj)
    local window = manageContainers()
    if not window then return nil end
    local parent = container and container:getParent()
    if not parent then return nil end
    local okIndex, index = pcall(parent.getContainerIndex, parent, container)
    if not okIndex or type(index) ~= "number" or index < 0 then return nil end
    -- A vehicle part container's parent is not always an IsoObject with
    -- modData; probe instead of assuming, so a vehicle destination degrades to
    -- "unconfigured" rather than erroring inside Area Tasks.
    local okMeta, meta = pcall(parent.getModData, parent)
    if not okMeta or type(meta) ~= "table" then return nil end
    local raw = meta[MCContainerDataKey]
    if not raw then return nil end

    local entry = cache[parent]
    if not entry or entry.raw ~= raw then
        entry = { raw = raw, rules = { }, done = { } }
        cache[parent] = entry
    end

    local slot = index + 1
    if not entry.done[slot] then
        local okData, data = pcall(window.getContainerData, parent, slot, legacyUUID(playerObj))
        if okData and type(data) == "table" then
            entry.rules[slot] = Routing.rule(data.containersFilters, data.exclusiveSelection, slot)
        end
        entry.done[slot] = true
    end
    return entry.rules[slot]
end

local function itemFields(item)
    local okCategory, category = pcall(function()
        return item:getDisplayCategory() or item:getCategory()
    end)
    local okType, fullType = pcall(function() return item:getFullType() end)
    return okCategory and category or nil, okType and fullType or nil
end

local notices = { }

local function notice(playerObj, item, fullType)
    local now = getTimestampMs and getTimestampMs() or 0
    local key = fullType or "?"
    if notices[key] and now - notices[key] < NOTICE_INTERVAL_MS then return end
    notices[key] = now

    local okName, name = pcall(function() return item:getName() end)
    local text = "Area Tasks: no configured container accepts " ..
        tostring(okName and name or "that item")
    log(text .. " (" .. tostring(key) .. ")")
    if HaloTextHelper and HaloTextHelper.addText then
        pcall(HaloTextHelper.addText, playerObj, text, 1.0, 0.55, 0.2)
    end
end

-- `reserve` with presets. Shape is upstream's: returns the container that took
-- the item and the reservation, or nil.
local function wrapped(playerObj, containers, item, reservations)
    local original = Hooks.original
    if type(containers) ~= "table" or #containers == 0 or not item or not manageContainers() then
        return original(playerObj, containers, item, reservations)
    end

    local category, fullType = itemFields(item)
    local rejectedByPreset = false
    for index = 1, #containers do
        local container = containers[index]
        if Routing.accepts(ruleFor(container, playerObj), category, fullType) then
            local taken = original(playerObj, { container }, item, reservations)
            if taken then return taken end
        else
            rejectedByPreset = true
        end
    end

    -- Distinguish "your presets say no" from "everything is full": only the
    -- former is this adapter's doing, and only when the item would have fitted
    -- somewhere. The throwaway reservations table is not the caller's.
    if rejectedByPreset and original(playerObj, containers, item, { }) then
        notice(playerObj, item, fullType)
    end
    return nil
end

Hooks.wrapped = wrapped

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
    if storage.reserve == wrapped then
        Hooks.installed = true
        return true
    end
    Hooks.original = storage.reserve
    storage.reserve = wrapped
    Hooks.installed = true
    log("installed: container destinations follow Manage Containers presets")
    return true
end

Hooks.install()
-- Area Tasks (and this file, after a Lua reload) can be rebuilt between
-- sessions; reinstalling is idempotent and refuses a changed API.
if Events and Events.OnGameStart then Events.OnGameStart.Add(Hooks.install) end
