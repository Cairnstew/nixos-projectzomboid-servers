-- PZAreaTasksBatchMove/Hooks.lua
--
-- Batches the built-in `Move Items > Containers (Area) > Container (Single)`
-- route: collect from several source containers, filling carried inventory,
-- then walk to the destination once, instead of delivering after every source.
--
-- How, without touching Area Tasks files:
--   * `collectTargets` for that route returns one target PER container, each
--     with its own `phase`/`sources`. We merge them into one target that keeps
--     `carried` across endpoints.
--   * `queueTarget` is wrapped. Just before the built-in code would deliver an
--     exhausted endpoint, we switch `target.endpoint` to the next container and
--     re-enter its own "discover" phase, keeping the carried items.
--   * If the built-in code completes while endpoints remain (an empty container),
--     the wrapper starts the next endpoint and returns "defer".
--
-- The guard is deliberately narrow: only `sourceMode == "containers"` to
-- `toMode == "container"`, only when there is more than one endpoint, and never
-- while a source still has deferred items (the built-in recycler only restores
-- those on delivery). Missing API/fields leaves the route exactly as upstream.

require "PZAreaTasksBatchMove/batching"

PZAreaTasksBatchMove = PZAreaTasksBatchMove or { }
if PZAreaTasksBatchMove.Hooks then return end

local Batching = PZAreaTasksBatchMove.Batching
local Hooks = { ready = false, wrapped = { } }
PZAreaTasksBatchMove.Hooks = Hooks

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
    target.sources = { }
    target.total = 1
    target.remaining = 1
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
    return { target }
end

local function wrap(task, Sources, Core)
    local nativeCollect = task.collectTargets
    local nativeQueue = task.queueTarget

    task.collectTargets = function(playerObj, bounds, destination, selectedTask)
        return aggregate(playerObj, nativeCollect(playerObj, bounds, destination, selectedTask))
    end

    task.queueTarget = function(job, target, resolved)
        if not target.endpoints then return nativeQueue(job, target, resolved) end

        -- Leave the finished endpoint only when the next one can be reached and
        -- there is room left; otherwise let the built-in code deliver, which is
        -- what frees capacity and recycles deferred items.
        if target.phase == "collect" and #target.carried > 0
                and not Batching.hasRemainingSources(target.sources)
                and not Batching.hasDeferred(target.sources) then
            local limit = Core.getGroundItemCarryLimit(job.playerObj)
            local weight = job.playerObj:getInventory():getCapacityWeight()
            local buffer = math.min(2, limit * 0.05)
            if weight < limit - buffer then
                local endpoint = nextEndpoint(job.playerObj, target, Sources)
                if endpoint then beginEndpoint(target, endpoint) end
            end
        end

        local queued, status, message, count = nativeQueue(job, target, resolved)

        -- An empty container makes the built-in code complete a one-endpoint
        -- target. Keep the aggregate alive and move to the next endpoint.
        if status == "completed" then
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

function Hooks.install()
    local ok = pcall(require, "AreaTasks/API")
    if not ok then
        Hooks.ready = false
        return false
    end

    local AreaTasks = _G.AreaTasks
    if type(AreaTasks) ~= "table" or AreaTasks.API_VERSION ~= 1 then
        Hooks.ready = false
        return false
    end

    local Sources = AreaTasks.ItemSources
    local Core = AreaTasks.Core
    local Registry = AreaTasks.Registry
    if type(Sources) ~= "table" or type(Sources.containers) ~= "function"
            or type(Core) ~= "table" or type(Core.getGroundItemCarryLimit) ~= "function"
            or type(Registry) ~= "table" or type(Registry.getAll) ~= "function" then
        Hooks.ready = false
        return false
    end

    local installed = false
    for _, task in ipairs(Registry.getAll()) do
        if task.sourceMode == "containers" and task.toMode == "container"
                and type(task.collectTargets) == "function"
                and type(task.queueTarget) == "function"
                and not Hooks.wrapped[task] then
            installed = wrap(task, Sources, Core) or installed
        end
    end

    Hooks.ready = installed
    return installed
end
