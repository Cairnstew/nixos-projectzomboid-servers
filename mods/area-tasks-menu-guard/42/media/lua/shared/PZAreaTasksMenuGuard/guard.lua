-- PZAreaTasksMenuGuard/guard.lua
--
-- The one piece of logic worth testing on its own: turn a registry call into a
-- call that cannot throw, and hand the error to a fallback that supplies the
-- values the caller needs to keep going. Node of Area Tasks' context menu is
-- protected by itself, so this is the seam the hook installs.
PZAreaTasksMenuGuard = PZAreaTasksMenuGuard or { }
if PZAreaTasksMenuGuard.Guard then return end

local Guard = { }
PZAreaTasksMenuGuard.Guard = Guard

--- Wrap `run` so it never raises. Returns at most two values, which is all the
--- Area Tasks registry seams use (`choices, reason`, `available, reason`).
---
--- On failure `onError(message, ...)` is called with the error text *and the
--- original arguments*, so the caller can name the task that broke, and its
--- return values are passed through unchanged.
function Guard.protect(run, onError)
    return function(...)
        local ok, first, second = pcall(run, ...)
        if ok then
            return first, second
        end
        return onError(first, ...)
    end
end
