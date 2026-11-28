-- PZFRTrunkAccess/hooks.lua
--
-- Filibuster Rhymes' Certified Used Cars ships container-access predicates that
-- Java calls from BaseVehicle.canAccessContainer. One of them,
-- Vehicles.ContainerAccess.FR_VisualTruckBedFiller, has no final return: when
-- the character stands in the truck-bed area and the part has no door object,
-- the function falls off the end and returns nil. Java then throws a
-- ReturnValues.put NullPointerException from ISInventoryPage:refreshBackpacks,
-- which aborts the container loop, so the bed is never listed and its items
-- cannot be opened. Vanilla's Vehicles.ContainerAccess.TruckBed ends with
-- `return true` at the same point.
--
-- The wrapper keeps the upstream decision whenever it is a boolean and coerces
-- only the fall-through: nil becomes true (the bed is not blocked), an error
-- fails closed. If Filibuster is absent, or the function is renamed, nothing is
-- installed and the route stays exactly as upstream.

PZFRTrunkAccess = PZFRTrunkAccess or { }

local function log(message)
    print("[PZFRTrunkAccess] " .. tostring(message))
end

function PZFRTrunkAccess.install()
    local vehicles = _G.Vehicles
    local access = type(vehicles) == "table" and vehicles.ContainerAccess
    if type(access) ~= "table" then return false end

    local original = access.FR_VisualTruckBedFiller
    if type(original) ~= "function" then return false end
    if original == PZFRTrunkAccess.wrapped then return true end

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

    PZFRTrunkAccess.wrapped = wrapped
    access.FR_VisualTruckBedFiller = wrapped
    log("wrapped Vehicles.ContainerAccess.FR_VisualTruckBedFiller")
    return true
end

-- Load order already puts Filibuster first (loadModAfter), but a Lua reload can
-- rebuild its server tree after this file, so retry once the game is running on
-- both sides.
if not PZFRTrunkAccess.eventsInstalled then
    PZFRTrunkAccess.eventsInstalled = true
    if Events then
        if Events.OnGameStart then Events.OnGameStart.Add(PZFRTrunkAccess.install) end
        if Events.OnServerStarted then Events.OnServerStarted.Add(PZFRTrunkAccess.install) end
    end
end

PZFRTrunkAccess.install()
