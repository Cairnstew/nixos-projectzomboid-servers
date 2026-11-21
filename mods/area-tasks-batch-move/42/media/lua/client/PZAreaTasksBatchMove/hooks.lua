-- PZAreaTasksBatchMove/Hooks.lua
--
-- Batches Area Tasks' area-source item routes (`Move Items > Containers (Area)`
-- or `Vehicles (Area) > <destination>`): collect from several source containers,
-- filling carried inventory, then walk to the destination once, instead of
-- delivering after every source.
--
-- How, without touching Area Tasks files:
--   * `collectTargets` for an area source returns one target PER container.
--     They are merged into one target that keeps `carried`, and that keeps the
--     `sources` records of every container visited so far.
--   * `queueTarget` is wrapped. When the built-in code has drained every
--     known container and carried inventory still has room, the wrapper starts
--     the next container's discovery phase, keeping the carried items and the
--     previous containers' records (including items deferred for lack of
--     destination space). Only a full inventory (or no container left) lets the
--     built-in delivery run, which is what recycles the deferred items.
--   * `sources` is a union because the built-in discovery replaces the list and
--     its delivery step only recycles leftovers that are still in it.
--
-- The guard is narrow: only area sources (containers, vehicles) whose
-- destination actually needs a trip, only when there is more than one
-- endpoint, and only when the player still has carried capacity. Missing
-- API/fields leaves the route exactly as upstream.

require "PZAreaTasksBatchMove/batching"

PZAreaTasksBatchMove = PZAreaTasksBatchMove or { }
if PZAreaTasksBatchMove.Hooks then return end

local Batching = PZAreaTasksBatchMove.Batching
local Hooks = { ready = false, wrapped = { } }
PZAreaTasksBatchMove.Hooks = Hooks

local function log(message)
    print("[PZAreaTasksBatchMove] " .. tostring(message))
end

-- Move the aggregate on to another container. `target.sources` is kept: it is
-- the union of every container discovered so far, and the built-in collector
-- must still be able to reach leftovers from a container it already visited.
-- Only the per-endpoint discovery state is reset.
local function beginEndpoint(target, endpoint)
    target.endpoint = endpoint
    target.x, target.y, target.z = endpoint.x, endpoint.y, endpoint.z
    target.phase = "discover"
    target.source = nil
    target.sourceReady = nil
    target.discoveryPending = nil
    target.discoveryDeadline = nil
    target.floorReady = nil
    target.active = { }
    target.sources = target.sources or { }
    target.total = 1
    target.remaining = 1
    target.guardLogged = nil
end

local function nextEndpoint(playerObj, target, Sources)
    if not target.endpoints then return nil end
    while target.nextEndpoint <= #target.endpoints do
        local endpoint = target.endpoints[target.nextEndpoint]
        target.nextEndpoint = target.nextEndpoint + 1
        -- Skip containers that were removed since the rectangle was drawn.
        if Sources.containers(playerObj, endpoint, false) then return endpoint end
    end
    return nil
end

local function aggregate(playerObj, targets)
    if #targets < 2 then return targets end

    local endpoints = { }
    for _, target in ipairs(targets) do endpoints[#endpoints + 1] = target.endpoint end
    endpoints = Batching.sortNearest(playerObj:getX(), playerObj:getY(), endpoints)

    local target = targets[1]
    target.endpoint = endpoints[1]
    target.x, target.y, target.z = endpoints[1].x, endpoints[1].y, endpoints[1].z
    target.endpoints = endpoints
    target.nextEndpoint = 2
    -- Start-message count: one per container, as the unbatched route reported.
    target.total = #endpoints
    target.remaining = #endpoints
    -- Positive evidence that the route was batched, and over how many sources.
    log(string.format("batching %d containers into one trip", #endpoints))
    return { target }
end

-- The built-in route replaces `target.sources` with the records of the endpoint
-- it just discovered. Keep every earlier endpoint's records too: the deferred
-- items a full destination or a full pocket left behind live there, and the
-- native delivery path only recycles them from `target.sources`. Without the
-- union, leaving an endpoint would strand its leftovers and the guard below
-- would have to deliver after every container.
local function mergeSources(target)
    target.retained = target.retained or target.sources or { }
    local retained = target.retained
    if target.sources ~= retained then
        for _, source in ipairs(target.sources or { }) do
            local known = false
            for _, existing in ipairs(retained) do
                if existing == source then known = true; break end
            end
            if not known then table.insert(retained, source) end
        end
        target.sources = retained
    end
    return retained
end

local function wrap(task, Sources, Core)
    local nativeCollect = task.collectTargets
    local nativeQueue = task.queueTarget

    task.collectTargets = function(playerObj, bounds, destination, selectedTask)
        local collected = nativeCollect(playerObj, bounds, destination, selectedTask)
        log(string.format("collectTargets %s: %d container(s)", tostring(task.id), #collected))
        return aggregate(playerObj, collected)
    end

    task.queueTarget = function(job, target, resolved)
        if not target.endpoints then return nativeQueue(job, target, resolved) end

        local sources = mergeSources(target)
        -- Progress is the outcome count of the whole trip, not of one container.
        target.remaining = Batching.outstanding(sources, target.carried)

        -- Leave a drained endpoint as soon as carried inventory has room. The
        -- previous version also refused whenever an item had been deferred for
        -- lack of destination space, which forced a destination trip per
        -- container even with empty pockets. Deferred items are safe now: the
        -- union above keeps them reachable and native delivery recycles them.
        if target.phase == "collect" then
            local limit = Core.getGroundItemCarryLimit(job.playerObj)
            local weight = job.playerObj:getInventory():getCapacityWeight()
            local buffer = math.min(2, limit * 0.05)
            local room = weight < limit - buffer
            if not Batching.hasRemainingSources(sources) then
                local endpoint = room and nextEndpoint(job.playerObj, target, Sources) or nil
                if endpoint then beginEndpoint(target, endpoint) end
                if not target.guardLogged then
                    target.guardLogged = true
                    log(string.format(
                        "endpoint drained: carried=%d deferred=%d weight=%.2f limit=%.2f next=%d/%d switched=%s",
                        #target.carried, Batching.deferredCount(sources), weight, limit,
                        target.nextEndpoint or -1, #(target.endpoints or { }), tostring(endpoint ~= nil)))
                end
            end
        end

        local queued, status, message, count = nativeQueue(job, target, resolved)
        mergeSources(target)

        -- An empty container makes the built-in discovery report completion.
        -- Keep the aggregate alive and move to the next endpoint. A completion
        -- from the collection phase is a real one (full destination, nothing
        -- left) and must end the trip.
        if status == "completed" and target.phase == "discover" then
            local endpoint = nextEndpoint(job.playerObj, target, Sources)
            if endpoint then
                beginEndpoint(target, endpoint)
                return false, "defer"
            end
        end
        return queued, status, message, count
    end

    Hooks.wrapped[task] = true
    return true
end

-- Batching only pays off when there is a delivery trip to save. `bag` deposits
-- straight into a worn container on each pickup, and `container` sources have a
-- single square, so neither is wrapped.
local BATCHED_SOURCES = { containers = true, vehicles = true }
local BATCHED_DESTINATIONS = {
    container = true, containers = true, vehicle = true, vehicles = true, ground = true,
}

function Hooks.install()
    local ok = pcall(require, "AreaTasks/API")
    if not ok then
        Hooks.ready = false
        log("Area Tasks is not loaded; batching inactive")
        return false
    end

    local AreaTasks = _G.AreaTasks
    if type(AreaTasks) ~= "table" or AreaTasks.API_VERSION ~= 1 then
        Hooks.ready = false
        log("Area Tasks API 1 is not available; batching inactive")
        return false
    end

    local Sources = AreaTasks.ItemSources
    local Core = AreaTasks.Core
    local Registry = AreaTasks.Registry
    if type(Sources) ~= "table" or type(Sources.containers) ~= "function"
            or type(Core) ~= "table" or type(Core.getGroundItemCarryLimit) ~= "function"
            or type(Registry) ~= "table" or type(Registry.getAll) ~= "function" then
        Hooks.ready = false
        log("Area Tasks item API changed; route left as upstream")
        return false
    end

    local installed, names = false, { }
    for _, task in ipairs(Registry.getAll()) do
        if BATCHED_SOURCES[task.sourceMode] and BATCHED_DESTINATIONS[task.toMode]
                and type(task.collectTargets) == "function"
                and type(task.queueTarget) == "function"
                and not Hooks.wrapped[task] then
            if wrap(task, Sources, Core) then
                installed = true
                names[#names + 1] = tostring(task.id)
            end
        end
    end

    Hooks.ready = installed or Hooks.ready
    if installed then
        table.sort(names)
        log("hooks installed: area sources batched for " .. table.concat(names, ", "))
    end
    return Hooks.ready
end
