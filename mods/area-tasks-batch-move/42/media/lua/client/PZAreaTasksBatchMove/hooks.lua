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

-- Why `Sources.containers` rejected a container endpoint, in the same order its
-- own checks run. Area Tasks collapses all of these into "the selected item
-- source moved, disappeared, or cannot be accessed", which is true of a locked
-- cupboard, an unloaded chunk and a changed object alike - so report which one
-- it actually was. Container endpoints only; a vehicle endpoint has already
-- been described by `VehicleStorage.reportUnavailable`.
local function unavailableReason(playerObj, endpoint)
    if type(endpoint) ~= "table" or endpoint.kind ~= "container" then return nil end
    local container, object = endpoint.container, endpoint.object
    if not container or not object then return "endpoint has no container" end
    local ok, reason = pcall(function()
        if container:getParent() ~= object then return "parent object changed" end
        local square = object:getSquare()
        if not square then return "object square not loaded" end
        if square:getX() ~= endpoint.x or square:getY() ~= endpoint.y
                or square:getZ() ~= endpoint.z then
            return "container moved"
        end
        local Destinations = AreaTasks and AreaTasks.GroundItemDestinations
        if type(Destinations) ~= "table" or type(Destinations.storageAvailable) ~= "function" then
            return "storage lookup unavailable"
        end
        if not Destinations.storageAvailable(playerObj, container) then
            return "storage unavailable (removed, locked, or no loot permission)"
        end
        return "available, but Sources.containers still rejected it"
    end)
    return ok and reason or ("probe failed: " .. tostring(reason))
end

local function nextEndpoint(playerObj, target, Sources)
    if not target.endpoints then return nil end
    while target.nextEndpoint <= #target.endpoints do
        local endpoint = target.endpoints[target.nextEndpoint]
        target.nextEndpoint = target.nextEndpoint + 1
        -- Skip containers that were removed since the rectangle was drawn, and
        -- say so: a jump in the `next=` count is otherwise unattributable.
        if Sources.containers(playerObj, endpoint, false) then return endpoint end
        local reason = unavailableReason(playerObj, endpoint)
        log(string.format("source %d/%d is no longer available; skipped%s",
            target.nextEndpoint - 1, #target.endpoints,
            reason and (" (" .. reason .. ")") or ""))
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

-- A source rectangle can contain the destination container. Upstream refuses
-- that job outright ("same item container"), which for an area source is wrong:
-- the other containers are still perfectly movable. Drop just that endpoint
-- before the built-in conflict check, so the route starts and `collectTargets`
-- never offers the destination as a source. The selection object belongs to
-- this job, so the removal is permanent and the task sees the same list.
local function dropDestinationEndpoint(destination, source)
    if type(source) ~= "table" or source.kind ~= "area" or destination == nil then
        return false
    end
    local endpoints = source.endpoints
    if type(endpoints) ~= "table" then return false end

    local removed, kept = false, { }
    for _, endpoint in ipairs(endpoints) do
        if endpoint.kind == "container" and endpoint.container == destination then
            removed = true
        elseif endpoint.kind == "vehicle" and type(endpoint.location) == "table"
                and type(endpoint.location.parts) == "table" then
            -- A vehicle is a group of containers: drop only the offending part.
            local parts = { }
            for _, part in ipairs(endpoint.location.parts) do
                if part.container == destination then
                    removed = true
                else
                    parts[#parts + 1] = part
                end
            end
            if #parts > 0 then
                endpoint.location.parts = parts
                kept[#kept + 1] = endpoint
            end
        else
            kept[#kept + 1] = endpoint
        end
    end
    if not removed then return false end
    source.endpoints = kept
    return true
end

local function wrap(task, AreaTasks)
    local Sources = AreaTasks.ItemSources
    local Core = AreaTasks.Core
    local nativeCollect = task.collectTargets
    local nativeQueue = task.queueTarget

    -- Only the single-container destination refuses an overlap. Area and
    -- vehicle destinations are already filtered by `destinationSelection`.
    if task.toMode == "container" then
        local nativeSelected = task.onSelected
        if type(nativeSelected) == "function" then
            task.onSelected = function(playerObj, bounds, destinationSquare,
                    destinationTarget, sourceTarget)
                if dropDestinationEndpoint(destinationTarget, sourceTarget) then
                    log("destination container removed from the source area")
                end
                return nativeSelected(playerObj, bounds, destinationSquare,
                    destinationTarget, sourceTarget)
            end
        end

        -- And let the player pick it: the built-in predicate hides a container
        -- that is also a source, which is the only reason the overlap could not
        -- be used at all.
        local nativeValid = task.isDestinationValid
        local Destinations = AreaTasks.GroundItemDestinations
        if type(nativeValid) == "function" and type(Destinations) == "table"
                and type(Destinations.storageAvailable) == "function" then
            task.isDestinationValid = function(playerObj, square, bounds, target, source)
                local valid, reason = nativeValid(playerObj, square, bounds, target, source)
                if valid or target == nil or type(source) ~= "table"
                        or type(Sources.contains) ~= "function" then
                    return valid, reason
                end
                if Sources.contains(source, target) then
                    return Destinations.storageAvailable(playerObj, target), reason
                end
                return valid, reason
            end
        end
    end

    task.collectTargets = function(playerObj, bounds, destination, selectedTask)
        local collected = nativeCollect(playerObj, bounds, destination, selectedTask)
        log(string.format("collectTargets %s: %d container(s)", tostring(task.id), #collected))
        return aggregate(playerObj, collected)
    end

    -- A cancelled walk to a source is fatal upstream: the classifier reports
    -- "blocked" with IGUI_AreaTasks_ItemSourceUnavailable ("the selected item
    -- source moved, disappeared, or cannot be accessed"), and the whole job
    -- ends. That is defensible when one target IS one container, but the
    -- aggregate still has containers queued - one unreachable cupboard used to
    -- end a 27-container trip at container four. Drop that endpoint, keep the
    -- trip, and let the next one be walked to instead. Each skip consumes an
    -- endpoint, so this is bounded by the size of the area.
    local nativeClassify = task.classifyCancellation
    if type(nativeClassify) == "function" then
        task.classifyCancellation = function(job, target, action, cancellation)
            local decision, detail, completed =
                nativeClassify(job, target, action, cancellation)
            if decision == "blocked" and target.endpoints
                    and (target.phase == "sourceApproach" or target.phase == "approach") then
                local endpoint = nextEndpoint(job.playerObj, target, Sources)
                if endpoint then
                    log(string.format(
                        "source walk cancelled; continuing with %d/%d: %s",
                        target.nextEndpoint - 1, #target.endpoints, tostring(detail)))
                    beginEndpoint(target, endpoint)
                    return "retry", detail, completed
                end
            end
            return decision, detail, completed
        end
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

        -- The same rule for a source the route could not even resolve: the
        -- native discovery phase reports "blocked" (phase "discover") for an
        -- unreachable square, an unloaded container or a vanished one. With
        -- containers still queued, that is one dud source, not the end of the
        -- trip.
        if status == "blocked" and target.phase == "discover" then
            local endpoint = nextEndpoint(job.playerObj, target, Sources)
            if endpoint then
                log(string.format("source unavailable; continuing with %d/%d: %s",
                    target.nextEndpoint - 1, #target.endpoints, tostring(message)))
                beginEndpoint(target, endpoint)
                return false, "defer"
            end
        end

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

        -- Trip-end diagnostic. Until now this route logged only the switches, so
        -- "it stopped early" and "it finished" produced the same silent log —
        -- there was no way to tell a blocked delivery, a full destination and a
        -- stall apart. One line per job, and only when containers were left.
        if not target.endLogged and (target.nextEndpoint or 1) <= #(target.endpoints or { })
                and (status == "blocked" or status == "completed") then
            target.endLogged = true
            log(string.format(
                "trip ended with %d/%d containers left: status=%s phase=%s carried=%d deferred=%d remaining=%d%s",
                (target.nextEndpoint or 1) - 1, #target.endpoints, tostring(status),
                tostring(target.phase), #target.carried, Batching.deferredCount(sources),
                target.remaining or -1,
                message and (" message=" .. tostring(message)) or ""))
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
            if wrap(task, AreaTasks) then
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
