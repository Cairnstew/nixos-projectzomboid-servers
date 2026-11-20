-- PZAreaTasksFilter/init.lua
--
-- Entry point. Requires the modules explicitly so load order does not depend on
-- the engine's alphabetical file walk, installs the Area Tasks hooks (once, and
-- again after a game start in case the registry was rebuilt), and reports an
-- active filter when a filtered item job actually starts.
--
-- Every module has a `if PZAreaTasksFilter.X then return end` guard, so the
-- engine auto-loading a file that `require` already pulled in is a no-op.

require "PZAreaTasksFilter/i18n"
require "PZAreaTasksFilter/filter"
require "PZAreaTasksFilter/state"
require "PZAreaTasksFilter/hooks"
require "PZAreaTasksFilter/ui"
require "PZAreaTasksFilter/menu"

PZAreaTasksFilter = PZAreaTasksFilter or { }
if PZAreaTasksFilter.ready then return end
PZAreaTasksFilter.ready = true

local T = PZAreaTasksFilter.I18n.text
local State = PZAreaTasksFilter.State
local Hooks = PZAreaTasksFilter.Hooks
local Filter = PZAreaTasksFilter.Filter

Hooks.install()
Events.OnGameStart.Add(function()
    Hooks.install()
end)

-- Confirmation, not a gate: the filter is applied inside the worker, so a short
-- halo line on start is the only feedback that a built-in route is filtered.
-- It names the mode and count, and it is silent for non-item jobs.
local function announce(job)
    if not State.modeActive() or not job or not job.playerObj then return end
    local task = job.task and (job.task.baseTask or job.task) or nil
    if not task or not task.sourceMode then return end

    local count = Filter.count(State.get())
    local text
    if State.get().mode == "only" then
        text = T("UI_AreaTasksFilter_StartOnly", "Area Tasks filter: only listed") .. " (" .. count .. ")"
    else
        text = T("UI_AreaTasksFilter_StartExcept", "Area Tasks filter: excluding") .. " (" .. count .. ")"
    end
    pcall(function() HaloTextHelper.addGoodText(job.playerObj, text) end)
end

if Events.AreaTaskStarted then
    Events.AreaTaskStarted.Add(announce)
end
