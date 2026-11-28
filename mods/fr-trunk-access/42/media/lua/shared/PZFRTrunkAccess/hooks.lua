-- PZFRTrunkAccess/hooks.lua
--
-- Keeps Filibuster Rhymes' truck and trailer beds usable. Two independent
-- defects hide the bed container; both are handled here, additively, in Lua.
--
-- 1. Filibuster's Vehicles.ContainerAccess.FR_VisualTruckBedFiller has no final
--    return. When the character stands in the bed area, nothing blocks the bed
--    and the part has no door object, it falls off the end and returns nil.
--    Java's BaseVehicle.canAccessContainer expects a boolean. Vanilla
--    ContainerAccess.TruckBed ends with `return true` at the same point, so the
--    wrapper below coerces the fall-through and forwards real booleans.
--
-- 2. Build 42.22's Lua-to-Java bridge throws, intermittently, while a Lua
--    container test makes nested Java calls (:isInArea, :getInventoryItem,
--    VehicleUtils.FillTrunk, ...):
--
--        NullPointerException: Cannot assign field "callFrame" because "a" is
--        null at ReturnValues.put(ReturnValues.java:61)
--
--    ReturnValues.put(a) nulls a pooled object; `a` is null because
--    MethodArguments.put() recycled the call's MethodArguments while it was
--    still in use (both classes hand instances out of static pools). It is an
--    engine defect, not Filibuster's and not Vehicle Manager's: the same trace
--    hits ISBuildIsoEntity:isValidPerSquare, Area Tasks' context menu, AutoAll's
--    collectWet and vanilla building placement. BaseVehicle.canAccessContainer
--    is reached through a Lua seam, so one throw aborts
--    ISInventoryPage:refreshBackpacks (the vehicle's container buttons are never
--    created) and Area Tasks' timed-action validity (the job stops before its
--    first transfer). The seam wrapper tolerates the failed call instead of
--    letting it escape: see fallbackAccess().
--
-- Both wrappers are inert when their target is absent (no Filibuster, or no
-- class metatable), so the mod can ship in a pack unconditionally.

PZFRTrunkAccess = PZFRTrunkAccess or { }

local function log(message)
    print("[PZFRTrunkAccess] " .. tostring(message))
end

-- Calls fn and reports failure as nil instead of raising. The bridge defect
-- above throws from inside the Java call, so every probe in the fallback path
-- has to be protected the same way the container loop now is.
local function try(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return value
end

-- ============================================================ the container test

function PZFRTrunkAccess.installFillerAccess()
    local vehicles = _G.Vehicles
    local access = type(vehicles) == "table" and vehicles.ContainerAccess
    if type(access) ~= "table" then return false end

    local original = access.FR_VisualTruckBedFiller
    if type(original) ~= "function" then return false end
    if original == PZFRTrunkAccess.fillerAccess then return true end

    local wrapped = function(vehicle, part, chr)
        local ok, allowed = pcall(original, vehicle, part, chr)
        if not ok then return false end
        if allowed == nil then
            if not PZFRTrunkAccess.nilLogged then
                PZFRTrunkAccess.nilLogged = true
                log("bed access test returned nil; treating the unblocked bed as accessible")
            end
            return true
        end
        return allowed == true
    end

    PZFRTrunkAccess.fillerAccess = wrapped
    access.FR_VisualTruckBedFiller = wrapped
    log("wrapped Vehicles.ContainerAccess.FR_VisualTruckBedFiller")
    return true
end

-- ============================================================== the Java seam

-- Last resort when the bridge threw and the call authorises nothing concrete:
-- cargo fails open for a character standing on foot inside the part's own
-- interaction area. Seats and the glove box stay closed -- they are passenger
-- surfaces, not cargo, and vanilla also refuses them from outside.
function PZFRTrunkAccess.cargoOnFoot(vehicle, partIndex, chr)
    local part = try(vehicle.getPartByIndex, vehicle, partIndex)
    if not part then return false end
    if not try(part.getItemContainer, part) then return false end
    local seat = try(part.getContainerSeatNumber, part)
    if type(seat) == "number" and seat >= 0 then return false end
    if try(part.getId, part) == "GloveBox" then return false end
    local area = try(part.getArea, part)
    if not area then return false end
    local inside = try(function()
        return chr:getVehicle() == nil and vehicle:isInArea(area, chr) == true
    end)
    return inside == true
end

-- Vehicle Manager owns ownership/rental rules on this seam; when it is loaded,
-- its own check is the authority and we only supply the missing boolean. Its
-- probes can hit the same bridge defect, hence try().
function PZFRTrunkAccess.fallbackAccess(vehicle, partIndex, chr)
    local manager = _G.MVM
    local check = type(manager) == "table" and manager.storageAllowed
    if type(check) == "function" then
        local allowed = try(check, vehicle, partIndex, chr)
        if allowed ~= nil then return allowed == true end
    end
    return PZFRTrunkAccess.cargoOnFoot(vehicle, partIndex, chr)
end

function PZFRTrunkAccess.installVehicleAccess()
    local class = type(_G.BaseVehicle) == "table" and BaseVehicle.class
    local metatables = type(_G.__classmetatables) == "table" and __classmetatables
    local methods = class and metatables and metatables[class]
    methods = type(methods) == "table" and methods.__index
    if type(methods) ~= "table" then return false end

    local previous = methods.canAccessContainer
    if type(previous) ~= "function" then return false end
    if previous == PZFRTrunkAccess.vehicleAccess then return true end

    local wrapped = function(vehicle, partIndex, chr)
        local ok, allowed = pcall(previous, vehicle, partIndex, chr)
        if ok then return allowed == true end
        local failures = (PZFRTrunkAccess.bridgeFailures or 0) + 1
        PZFRTrunkAccess.bridgeFailures = failures
        if failures == 1 or failures % 50 == 0 then
            log("vehicle access bridge failed (" .. failures .. " time(s)); answering in Lua: " ..
                string.sub(tostring(allowed), 1, 120))
        end
        return PZFRTrunkAccess.fallbackAccess(vehicle, partIndex, chr)
    end

    PZFRTrunkAccess.vehicleAccess = wrapped
    methods.canAccessContainer = wrapped
    log("guarded BaseVehicle.canAccessContainer")
    return true
end

-- ===================================================================== install

function PZFRTrunkAccess.install()
    local filler = PZFRTrunkAccess.installFillerAccess()
    local vehicle = PZFRTrunkAccess.installVehicleAccess()
    return filler or vehicle
end

-- Load order already puts Filibuster and Vehicle Manager first from the -server
-- tree and their own load-time wrappers replace the metatable entry, so the seam
-- is claimed once the game is running on both sides. Only the container test is
-- wrapped at load: wrapping the seam here as well would leave two copies of our
-- own wrapper once install() runs at game start.
if not PZFRTrunkAccess.eventsInstalled then
    PZFRTrunkAccess.eventsInstalled = true
    if Events then
        if Events.OnGameStart then Events.OnGameStart.Add(PZFRTrunkAccess.install) end
        if Events.OnServerStarted then Events.OnServerStarted.Add(PZFRTrunkAccess.install) end
    end
end

PZFRTrunkAccess.installFillerAccess()
