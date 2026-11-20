-- PZAreaTasksFilter/Hooks.lua
--
-- The two extension points that cover every Area Tasks item route:
--
--   1. `AreaTasks.ItemSources.eligible(playerObj, item)` is consulted for every
--      container/vehicle source record, so wrapping it filters Move Items from
--      containers and vehicle storage (and the execution-time re-check).
--   2. `collectTargets` on each registered task with `sourceMode == "ground"`
--      returns the already-collected ground records. Those are pruned after the
--      call; nothing is re-collected or re-queued, so the built-in worker keeps
--      its own pathing, transfer and capacity logic.
--
-- Area Tasks documents registry/worker internals as *not* an extension API, so
-- this installs defensively: a missing global, API version or task field leaves
-- the route untouched and `Hooks.ready` false. The editor then says the filter
-- is unsupported instead of pretending it works. No Area Tasks file is read,
-- copied or overridden.

require "PZAreaTasksFilter/state"

PZAreaTasksFilter = PZAreaTasksFilter or { }
if PZAreaTasksFilter.Hooks then return end

local State = PZAreaTasksFilter.State
local Hooks = { ready = false }
PZAreaTasksFilter.Hooks = Hooks

Hooks.wrappedTasks = { }
Hooks.wrappedEligible = false

local function log(message)
    print("[PZAreaTasksFilter] " .. tostring(message))
end

local function wrapEligible(AreaTasks)
    local Sources = AreaTasks.ItemSources
    if type(Sources) ~= "table" or type(Sources.eligible) ~= "function" then
        return false
    end
    if Hooks.wrappedEligible then return true end

    local native = Sources.eligible
    Sources.eligible = function(playerObj, item)
        local eligible = native(playerObj, item)
        if not eligible then return false end
        return State.matchesItem(item)
    end
    Hooks.wrappedEligible = true
    return true
end

local function wrapGroundTasks(AreaTasks)
    local Registry = AreaTasks.Registry
    if type(Registry) ~= "table" or type(Registry.getAll) ~= "function" then
        return false
    end

    local wrapped = false
    for _, task in ipairs(Registry.getAll()) do
        if task.sourceMode == "ground" and type(task.collectTargets) == "function"
                and not Hooks.wrappedTasks[task] then
            local native = task.collectTargets
            task.collectTargets = function(...)
                return State.filterTargets(native(...))
            end
            Hooks.wrappedTasks[task] = true
            wrapped = true
        end
    end
    return wrapped
end

local function wrappedGroundCount()
    local count = 0
    for _ in pairs(Hooks.wrappedTasks) do count = count + 1 end
    return count
end

function Hooks.install()
    local ok = pcall(require, "AreaTasks/API")
    if not ok then
        Hooks.ready = false
        log("Area Tasks is not loaded; filter inactive")
        return false, "Area Tasks is not loaded"
    end

    local AreaTasks = _G.AreaTasks
    if type(AreaTasks) ~= "table" or AreaTasks.API_VERSION ~= 1 then
        Hooks.ready = false
        log("Area Tasks API 1 is not available (API_VERSION="
            .. tostring(type(AreaTasks) == "table" and AreaTasks.API_VERSION or nil)
            .. "); filter inactive")
        return false, "Area Tasks API 1 is not available"
    end

    local eligible = wrapEligible(AreaTasks)
    local ground = wrapGroundTasks(AreaTasks)
    Hooks.ready = eligible or ground

    if not Hooks.ready then
        log("no supported item route found; the filter editor is available but inert")
        return false, "no supported Area Tasks item routes"
    end
    -- Positive evidence for a log-only verification: which routes are attached.
    log(string.format("hooks installed: container sources %s, %d ground task(s)",
        tostring(eligible), wrappedGroundCount()))
    return true
end
