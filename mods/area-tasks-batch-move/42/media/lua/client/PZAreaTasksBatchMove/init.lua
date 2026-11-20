-- PZAreaTasksBatchMove/init.lua
--
-- Requires the module explicitly so load order does not depend on the engine's
-- alphabetical walk, then installs the wrappers. `OnGameStart` retries because
-- a registry that is rebuilt at session start must be wrapped again; the
-- `Hooks.wrapped[task]` table makes that idempotent.

require "PZAreaTasksBatchMove/batching"
require "PZAreaTasksBatchMove/hooks"

PZAreaTasksBatchMove = PZAreaTasksBatchMove or { }
if PZAreaTasksBatchMove.ready then return end
PZAreaTasksBatchMove.ready = true

PZAreaTasksBatchMove.Hooks.install()

Events.OnGameStart.Add(function()
    PZAreaTasksBatchMove.Hooks.install()
end)
