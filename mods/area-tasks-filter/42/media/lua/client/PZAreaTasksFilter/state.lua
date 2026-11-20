-- PZAreaTasksFilter/State.lua
--
-- Runtime state: load/save the filter, answer the predicate for an InventoryItem,
-- and prune a ground-source target list that Area Tasks already collected.
--
-- The file lives in Zomboid/Lua/ (getFileReader/getFileWriter are sandboxed
-- there), so it is per-client and survives restarts in SP and MP. Two players on
-- one server each keep their own filter; nothing here is sent to the server.

require "PZAreaTasksFilter/filter"

PZAreaTasksFilter = PZAreaTasksFilter or { }
if PZAreaTasksFilter.State then return end

local Filter = PZAreaTasksFilter.Filter
local State = { }
PZAreaTasksFilter.State = State

State.FILE = "PZAreaTasksFilter.txt"
State.state = nil

local function log(message)
    print("[PZAreaTasksFilter] " .. tostring(message))
end

function State.load()
    local text = nil
    pcall(function()
        local reader = getFileReader(State.FILE, true)
        if not reader then return end
        local lines = { }
        while true do
            local line = reader:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
        reader:close()
        text = table.concat(lines, "\n")
    end)
    if not text then return Filter.new() end
    return Filter.parse(text)
end

function State.get()
    if not State.state then
        State.state = State.load()
    end
    return State.state
end

function State.save()
    local text = Filter.serialize(State.get())
    local ok, err = pcall(function()
        local writer = getFileWriter(State.FILE, true, false)
        if not writer then error("no file writer") end
        writer:write(text)
        writer:close()
    end)
    if not ok then
        -- A read-only/odd install must not break the editor; the in-memory
        -- filter still applies for this session.
        log("could not save " .. State.FILE .. ": " .. tostring(err))
    end
end

function State.modeActive()
    return State.get().mode ~= "off"
end

function State.matchesItem(item)
    if not item then return false end
    local state = State.get()
    if state.mode == "off" then return true end

    local fullType = nil
    local ok = pcall(function() fullType = item:getFullType() end)
    if not ok then return false end
    return Filter.matches(state, fullType)
end

-- Ground-source targets arrive already collected: one aggregate target whose
-- `sources[].items[]` descriptors carry `.item`. Prune here so the built-in
-- route never queues an excluded item. A descriptor without an item is kept:
-- silently dropping an unknown shape is worse than letting it through.
function State.filterTargets(targets)
    if type(targets) ~= "table" or not State.modeActive() then return targets end

    local keptTargets = { }
    for _, target in ipairs(targets) do
        local sources = target.sources
        if type(sources) ~= "table" then
            keptTargets[#keptTargets + 1] = target
        else
            local total = 0
            for _, source in ipairs(sources) do
                local items = source.items
                if type(items) == "table" then
                    local kept = { }
                    for _, descriptor in ipairs(items) do
                        if descriptor.item == nil or State.matchesItem(descriptor.item) then
                            kept[#kept + 1] = descriptor
                        end
                    end
                    source.items = kept
                    source.next = 1
                    total = total + #kept
                end
            end
            if total > 0 then
                target.total = total
                target.remaining = total
                keptTargets[#keptTargets + 1] = target
            end
        end
    end
    return keptTargets
end

function State.setMode(mode)
    Filter.setMode(State.get(), mode)
    State.save()
end

function State.toggle(fullType)
    Filter.toggle(State.get(), fullType)
    State.save()
end

function State.clear()
    Filter.clear(State.get())
    State.save()
end

-- Quick actions from the item context menus: "only this type" replaces the set
-- with one entry; "exclude this type" keeps the existing set and adds one.
function State.onlyType(fullType)
    if type(fullType) ~= "string" or fullType == "" then return end
    local state = State.get()
    state.mode = "only"
    state.types = { [fullType] = true }
    State.save()
end

function State.excludeType(fullType)
    if type(fullType) ~= "string" or fullType == "" then return end
    local state = State.get()
    state.mode = "except"
    state.types[fullType] = true
    State.save()
end
