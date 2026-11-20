-- PZAreaTasksBatchMove/Batching.lua
--
-- Pure helpers for the batched area-container route. No PZ globals, so
-- checks/default.nix can exercise them under plain Lua 5.1.

PZAreaTasksBatchMove = PZAreaTasksBatchMove or { }
if PZAreaTasksBatchMove.Batching then return end

local Batching = { }
PZAreaTasksBatchMove.Batching = Batching

function Batching.distanceSquared(playerX, playerY, endpoint)
    local dx = (endpoint.x + 0.5) - playerX
    local dy = (endpoint.y + 0.5) - playerY
    return dx * dx + dy * dy
end

-- Area Tasks collects endpoints in row-major scan order, while its worker
-- visits separate targets nearest-first. One aggregate target has to do that
-- ordering itself or the character zig-zags across the rectangle.
function Batching.sortNearest(playerX, playerY, endpoints)
    local sorted = { }
    for index, endpoint in ipairs(endpoints) do sorted[index] = endpoint end
    table.sort(sorted, function(left, right)
        return Batching.distanceSquared(playerX, playerY, left)
            < Batching.distanceSquared(playerX, playerY, right)
    end)
    return sorted
end

-- A source with items left is one the character has not finished yet.
function Batching.hasRemainingSources(sources)
    for _, source in ipairs(sources or { }) do
        if source.next <= #(source.items or { }) then return true end
    end
    return false
end

-- Deferred items are the ones a native transfer batch left behind because the
-- player was at capacity. The built-in route recycles them only on delivery, so
-- the batcher must not leave the endpoint while any exist: switching endpoints
-- would strand them in the container.
function Batching.hasDeferred(sources)
    for _, source in ipairs(sources or { }) do
        if #(source.deferred or { }) > 0 then return true end
    end
    return false
end
