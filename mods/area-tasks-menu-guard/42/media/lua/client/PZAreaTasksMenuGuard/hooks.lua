-- PZAreaTasksMenuGuard/hooks.lua
--
-- Keeps Area Tasks' context menu whole when one task's dynamic choices fail.
--
-- How the menu is built (Area Tasks 1.2.0):
--
--     Events.OnFillWorldObjectContextMenu -> ContextMenu.onFill
--         -> addCategory (one per registered category, ordered by `order`)
--             -> addTaskOption
--                 -> Registry.getChoices(task, playerObj)
--                 -> Registry.getAvailability(task, playerObj)   (per choice)
--
-- Nothing in that chain is protected, and it all runs inside a single event
-- handler at the end of `ISWorldObjectContextMenu.createMenu`. One task that
-- throws therefore aborts the handler, and every category that has not been
-- added yet disappears. The order makes that expensive: `animals` is 220 and
-- `moveItems` is 310, so a failure while building the trap-baiting choices
-- removes **Items** - Move Items, Move Items -> Containers (Area), and every
-- other item route - from the submenu. The log shows only a Kahlua interop NPE
-- ("Cannot assign field \"callFrame\" ..." at ReturnValues.put), which is the
-- error Java reports when a Lua callback raises across the Java boundary; the
-- actual Lua message is swallowed.
--
-- This adapter wraps the two registry calls `addTaskOption` makes:
--   * `getChoices` -> on error: no choices plus a reason, so the option is
--     added disabled with the reason in its tooltip instead of throwing;
--   * `getAvailability` -> on error: unavailable plus a reason, for the same
--     effect on the per-choice loop.
-- The real Lua error is printed once per task and message, so the next run
-- says what actually failed instead of just the interop NPE.
--
-- Nothing changes when a task works, no Area Tasks file is overridden, and the
-- guard is inert without AreaTasks API 1.

require "PZAreaTasksMenuGuard/guard"

PZAreaTasksMenuGuard = PZAreaTasksMenuGuard or { }
local Guard = PZAreaTasksMenuGuard.Guard

local Hooks = PZAreaTasksMenuGuard.Hooks
if Hooks and Hooks.installed and type(AreaTasks) == "table" and
        type(AreaTasks.Registry) == "table" and
        AreaTasks.Registry.getChoices == Hooks.getChoices and
        AreaTasks.Registry.getAvailability == Hooks.getAvailability then
    return
end

Hooks = Hooks or { installed = false, getChoices = nil, getAvailability = nil }
PZAreaTasksMenuGuard.Hooks = Hooks

local reported = { }

local function log(message)
    print("[PZAreaTasksMenuGuard] " .. tostring(message))
end

-- Task ids are stable; titles are localised and can themselves be missing.
local function describe(task)
    local ok, title = pcall(function()
        return AreaTasks.Registry.getTitle(task)
    end)
    if ok and type(title) == "string" and title ~= "" then return title end
    return "task"
end

local function report(task, seam, message)
    local id = type(task) == "table" and tostring(task.id) or "?"
    local key = id .. "|" .. seam .. "|" .. tostring(message)
    if reported[key] then return end
    reported[key] = true
    log("task '" .. id .. "' (" .. describe(task) .. ") " .. seam ..
        " failed: " .. tostring(message))
end

local function reason(task)
    return "Area Tasks: " .. describe(task) ..
        " could not build its menu; see the console log."
end

function Hooks.install()
    if type(AreaTasks) ~= "table" then
        log("Area Tasks is absent; guard inert")
        return false
    end
    if AreaTasks.API_VERSION ~= 1 then
        log("unsupported Area Tasks API " .. tostring(AreaTasks.API_VERSION) ..
            "; guard inert")
        return false
    end
    local registry = AreaTasks.Registry
    if type(registry) ~= "table" or type(registry.getChoices) ~= "function" then
        log("Area Tasks Registry.getChoices is missing; guard inert")
        return false
    end
    if registry.getChoices == Hooks.getChoices and
            registry.getAvailability == Hooks.getAvailability then
        Hooks.installed = true
        return true
    end

    if registry.getChoices ~= Hooks.getChoices then
        local original = registry.getChoices
        Hooks.getChoices = Guard.protect(original, function(message, task)
            report(task, "getChoices", message)
            return { }, reason(task)
        end)
        registry.getChoices = Hooks.getChoices
    end

    if type(registry.getAvailability) == "function" and
            registry.getAvailability ~= Hooks.getAvailability then
        local original = registry.getAvailability
        Hooks.getAvailability = Guard.protect(original, function(message, task)
            report(task, "getAvailability", message)
            return false, reason(task)
        end)
        registry.getAvailability = Hooks.getAvailability
    end

    Hooks.installed = true
    log("installed: a failing task degrades to a disabled menu option")
    return true
end

Hooks.install()
-- Area Tasks (and this file, after a Lua reload) can be rebuilt between
-- sessions; reinstalling is idempotent and refuses a changed API.
if Events and Events.OnGameStart then Events.OnGameStart.Add(Hooks.install) end
