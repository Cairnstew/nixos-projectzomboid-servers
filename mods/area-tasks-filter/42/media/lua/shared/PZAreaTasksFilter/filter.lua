-- PZAreaTasksFilter/Filter.lua
--
-- Pure filter state: mode, the type set, matching, and the on-disk format.
-- Deliberately free of PZ globals so `checks/default.nix` can exercise it with
-- plain Lua 5.1 (the game's Lua) and no running client.
--
-- A filter is `{ mode = "off" | "only" | "except", types = { [fullType] = true } }`.
-- "only" is the whitelist, "except" the blacklist. Full types are the
-- `module.id` strings Area Tasks already keys its item records on
-- (`Base.Bandage`), never display names.

PZAreaTasksFilter = PZAreaTasksFilter or { }
if PZAreaTasksFilter.Filter then return end

local Filter = { }
PZAreaTasksFilter.Filter = Filter

Filter.FILE_VERSION = 1
Filter.MODES = { off = "off", only = "only", except = "except" }

local function isMode(mode)
    return mode == "off" or mode == "only" or mode == "except"
end
Filter.isMode = isMode

function Filter.new()
    return { mode = "off", types = { } }
end

-- Copy only the fields and type entries the rest of the code understands, so a
-- hand-edited or older file cannot put the filter into a mode it never handles.
function Filter.normalize(state)
    local result = Filter.new()
    if type(state) ~= "table" then return result end
    if isMode(state.mode) then result.mode = state.mode end
    if type(state.types) == "table" then
        for fullType, listed in pairs(state.types) do
            if listed and type(fullType) == "string" and fullType ~= "" then
                result.types[fullType] = true
            end
        end
    end
    return result
end

function Filter.isListed(state, fullType)
    return type(fullType) == "string" and state.types[fullType] == true
end

function Filter.count(state)
    local count = 0
    for _ in pairs(state.types) do count = count + 1 end
    return count
end

-- The predicate Area Tasks hook points call. `off` matches everything, a listed
-- type matches in `only` mode, and everything not listed matches in `except`
-- mode. A missing/unknown full type is never allowed through while a filter is
-- active: the source data is not what the player asked for.
function Filter.matches(state, fullType)
    state = state or Filter.new()
    if state.mode == "off" then return true end
    if type(fullType) ~= "string" or fullType == "" then return false end
    local listed = state.types[fullType] == true
    if state.mode == "only" then return listed end
    return not listed
end

function Filter.setMode(state, mode)
    if isMode(mode) then state.mode = mode end
end

function Filter.setListed(state, fullType, listed)
    if type(fullType) ~= "string" or fullType == "" then return end
    if listed then
        state.types[fullType] = true
    else
        state.types[fullType] = nil
    end
end

function Filter.toggle(state, fullType)
    Filter.setListed(state, fullType, not Filter.isListed(state, fullType))
end

function Filter.clear(state)
    state.mode = "off"
    state.types = { }
end

-- The persisted form. One `key=value` per line, `type=` repeated, and a version
-- comment first so a future format can be recognised instead of guessed at.
-- Sorting makes the file stable, which keeps it readable and testable.
function Filter.serialize(state)
    state = Filter.normalize(state)
    local types = { }
    for fullType in pairs(state.types) do types[#types + 1] = fullType end
    table.sort(types)

    local lines = {
        "# PZAreaTasksFilter " .. tostring(Filter.FILE_VERSION),
        "mode=" .. state.mode,
    }
    for _, fullType in ipairs(types) do
        lines[#lines + 1] = "type=" .. fullType
    end
    return table.concat(lines, "\n") .. "\n"
end

function Filter.parse(text)
    local state = Filter.new()
    if type(text) ~= "string" then return state end

    for line in text:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^([%a_]+)%s*=%s*(.-)%s*$")
            if key == "mode" and isMode(value) then
                state.mode = value
            elseif key == "type" and value ~= "" then
                state.types[value] = true
            end
        end
    end
    return state
end
