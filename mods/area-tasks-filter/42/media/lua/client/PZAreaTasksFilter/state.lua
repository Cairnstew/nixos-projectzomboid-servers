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

-- Call an optional method and return a non-empty string, or nil.
--
-- The method is looked up before it is called. A script item has no
-- `getCategory`, and `pcall(function() return script:getCategory() end)` still
-- makes the engine log "Object tried to call nil in pcall" once per call -
-- roughly once per item script each time the editor opened. Probing the field
-- first means a missing method is simply absent instead of an error.
function State.textOf(object, method)
    if object == nil then return nil end
    local ok, fn = pcall(function() return object[method] end)
    if not ok or type(fn) ~= "function" then return nil end
    local called, value = pcall(fn, object)
    if not called or type(value) ~= "string" or value == "" then return nil end
    return value
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

-- The inventory category of a live item (`Weapon`, `Food`, `Clothing`, …), the
-- same grouping the inventory filter tabs use. `getDisplayCategory` is the
-- instance method; a script item does not expose it, so fall back to
-- `getCategory`. Anything unexpected yields nil, which means "item type only".
function State.itemCategory(item)
    if not item then return nil end
    return State.textOf(item, "getDisplayCategory") or State.textOf(item, "getCategory")
end

-- Every category an item answers to, deduplicated: the live instance's
-- `getDisplayCategory()`, the live instance's `getCategory()`, and what the
-- item's script declares for the same two methods. The editor enumerates
-- categories from SCRIPT items, so matching on the live display category alone
-- silently ignored any category the editor offered that only the script
-- declares - a live `except FoodP` rule then never excluded anything. Script
-- lookups are cached per full type; the live halves are read every call because
-- an instance's category can follow its state (perishable food).
State.scriptCategories = State.scriptCategories or { }

local function scriptCategories(fullType)
    local cached = State.scriptCategories[fullType]
    if cached then return cached end
    local out = { }
    local ok, script = pcall(function() return getScriptManager():FindItem(fullType) end)
    if ok and script then
        local category = State.textOf(script, "getDisplayCategory")
        if category then out[#out + 1] = category end
        category = State.textOf(script, "getCategory")
        if category then out[#out + 1] = category end
    end
    State.scriptCategories[fullType] = out
    return out
end

function State.itemCategories(item, fullType)
    local seen, out = { }, { }
    local function add(category)
        if type(category) ~= "string" or category == "" then return end
        if seen[category] then return end
        seen[category] = true
        out[#out + 1] = category
    end
    add(State.textOf(item, "getDisplayCategory"))
    add(State.textOf(item, "getCategory"))
    if type(fullType) == "string" then
        for _, category in ipairs(scriptCategories(fullType)) do add(category) end
    end
    return out
end

function State.matchesItem(item)
    if not item then return false end
    local state = State.get()
    if state.mode == "off" then return true end

    local fullType = nil
    local ok = pcall(function() fullType = item:getFullType() end)
    if not ok then return false end
    local categories = State.itemCategories(item, fullType)
    local matched = Filter.matches(state, fullType, categories)
    if not matched then
        -- Confirmation that the filter actually reached a container source, and
        -- what it classified the item as. Capped: the first few distinct
        -- (type, categories) pairs per session are enough to prove a rule
        -- works, and a long haul would otherwise flood the log.
        State.excludedSeen = State.excludedSeen or { }
        State.excludedLogged = State.excludedLogged or 0
        local key = fullType .. "|" .. table.concat(categories, ",")
        if not State.excludedSeen[key] and State.excludedLogged < 8 then
            State.excludedSeen[key] = true
            State.excludedLogged = State.excludedLogged + 1
            log(string.format("filter excluded %s [%s]",
                fullType, table.concat(categories, ",")))        end
    end
    return matched
end

-- Ground-source targets arrive already collected: one aggregate target whose
-- `sources[].items[]` descriptors carry `.item`. Prune here so the built-in
-- route never queues an excluded item. A descriptor without an item is kept:
-- silently dropping an unknown shape is worse than letting it through.
function State.filterTargets(targets)
    if type(targets) ~= "table" or not State.modeActive() then return targets end

    local keptTargets = { }
    local before, after = 0, 0
    for _, target in ipairs(targets) do
        local sources = target.sources
        if type(sources) ~= "table" then
            keptTargets[#keptTargets + 1] = target
        else
            local total = 0
            for _, source in ipairs(sources) do
                local items = source.items
                if type(items) == "table" then
                    before = before + #items
                    local kept = { }
                    for _, descriptor in ipairs(items) do
                        if descriptor.item == nil or State.matchesItem(descriptor.item) then
                            kept[#kept + 1] = descriptor
                        end
                    end
                    source.items = kept
                    source.next = 1
                    total = total + #kept
                    after = after + #kept
                end
            end
            if total > 0 then
                target.total = total
                target.remaining = total
                keptTargets[#keptTargets + 1] = target
            end
        end
    end
    if before > after then
        -- Confirmation that a built-in route was actually filtered (and by how
        -- much) instead of silently doing nothing.
        log(string.format("filter removed %d of %d collected item(s)", before - after, before))
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

function State.toggleCategory(category)
    Filter.toggleCategory(State.get(), category)
    State.save()
end

function State.clear()
    Filter.clear(State.get())
    State.save()
end

-- Quick actions from the item context menus: "only this ..." replaces the set
-- with one entry; "exclude this ..." keeps the existing set and adds one.
-- Replacing clears the other list, so a stale category cannot widen an
-- "only this type" selection (and vice versa).
function State.onlyType(fullType)
    if type(fullType) ~= "string" or fullType == "" then return end
    local state = State.get()
    state.mode = "only"
    state.types = { [fullType] = true }
    state.categories = { }
    State.save()
end

function State.excludeType(fullType)
    if type(fullType) ~= "string" or fullType == "" then return end
    local state = State.get()
    state.mode = "except"
    state.types[fullType] = true
    State.save()
end

function State.onlyCategory(category)
    if type(category) ~= "string" or category == "" then return end
    local state = State.get()
    state.mode = "only"
    state.types = { }
    state.categories = { [category] = true }
    State.save()
end

function State.excludeCategory(category)
    if type(category) ~= "string" or category == "" then return end
    local state = State.get()
    state.mode = "except"
    state.categories[category] = true
    State.save()
end
