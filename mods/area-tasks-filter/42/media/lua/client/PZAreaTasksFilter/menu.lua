-- PZAreaTasksFilter/Menu.lua
--
-- World- and inventory-context-menu entry. The submenu shows the current mode
-- and count, opens the editor, clears the filter, and (when one item was
-- right-clicked) offers the two one-click forms of "select a specific item":
-- only this type, or exclude this type.
--
-- It only appears when Area Tasks is loaded; the editor is reachable but the
-- status says "unsupported" when the task hooks could not be installed, so a
-- future Area Tasks change is visible instead of silently doing nothing.

require "ISUI/ISContextMenu"
require "PZAreaTasksFilter/state"
require "PZAreaTasksFilter/hooks"
require "PZAreaTasksFilter/ui"
require "PZAreaTasksFilter/i18n"

PZAreaTasksFilter = PZAreaTasksFilter or { }
if PZAreaTasksFilter.Menu then return end

local T = PZAreaTasksFilter.I18n.text
local State = PZAreaTasksFilter.State
local Hooks = PZAreaTasksFilter.Hooks
local Filter = PZAreaTasksFilter.Filter
local UI = PZAreaTasksFilter.UI
local Menu = { }
PZAreaTasksFilter.Menu = Menu

local function statusLabel()
    local state = State.get()
    local count = Filter.count(state)
    if state.mode == "off" then
        return T("UI_AreaTasksFilter_StatusOff", "Filter: off")
    elseif state.mode == "only" then
        return T("UI_AreaTasksFilter_StatusOnly", "Filter: only listed") .. " (" .. count .. ")"
    end
    return T("UI_AreaTasksFilter_StatusExcept", "Filter: exclude listed") .. " (" .. count .. ")"
end

local function itemFullType(item)
    if not item then return nil end
    local fullType = nil
    local ok = pcall(function() fullType = item:getFullType() end)
    if ok and type(fullType) == "string" and fullType ~= "" then return fullType end
    return nil
end

local function itemLabel(item, fullType)
    local name = nil
    pcall(function() name = item:getName() end)
    if type(name) ~= "string" or name == "" then
        pcall(function() name = getItemNameFromFullType(fullType) end)
    end
    if type(name) ~= "string" or name == "" or name == fullType then return fullType end
    return name
end

-- The inventory tab label for a category (`Weapon` -> "Weapons"), falling back
-- to the raw key when the translation is missing.
local function categoryName(category)
    local text = nil
    pcall(function() text = getText("IGUI_ItemCat_" .. category) end)
    if type(text) ~= "string" or text == "" or text == "IGUI_ItemCat_" .. category then
        return category
    end
    return text
end

local function addFilters(playerNum, context, item)
    if type(_G.AreaTasks) ~= "table" then return end

    local option = context:addOption(T("UI_AreaTasksFilter_Menu", "Area Tasks Filter"))
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)

    local status = sub:addOption(statusLabel(), nil, nil)
    status.notAvailable = true

    if not Hooks.ready then
        local warning = sub:addOption(
            T("UI_AreaTasksFilter_Unsupported", "Unsupported Area Tasks version: filter inert"), nil, nil)
        warning.notAvailable = true
    end

    sub:addOption(T("UI_AreaTasksFilter_Edit", "Edit filter..."), playerNum, UI.open)
    sub:addOption(T("UI_AreaTasksFilter_Clear", "Clear filter"), nil, function()
        State.clear()
    end)

    local fullType = itemFullType(item)
    if fullType then
        local label = itemLabel(item, fullType)
        sub:addOption(T("UI_AreaTasksFilter_OnlyItem", "Only this item type") .. ": " .. label,
            nil, function() State.onlyType(fullType) end)
        sub:addOption(T("UI_AreaTasksFilter_ExceptItem", "Exclude this item type") .. ": " .. label,
            nil, function() State.excludeType(fullType) end)
    end

    -- The coarser shortcut: one entry covers every item in the same inventory
    -- category, which is what "filter out the weapons" actually means.
    local category = State.itemCategory(item)
    if category then
        local label = categoryName(category)
        sub:addOption(T("UI_AreaTasksFilter_OnlyCategory", "Only this category") .. ": " .. label,
            nil, function() State.onlyCategory(category) end)
        sub:addOption(T("UI_AreaTasksFilter_ExceptCategory", "Exclude this category") .. ": " .. label,
            nil, function() State.excludeCategory(category) end)
    end
end

local function worldItem(worldobjects)
    for _, object in ipairs(worldobjects or { }) do
        -- The list holds every world object under the cursor, not just the
        -- placed-item wrapper: walls, doors and water pipes have no getItem().
        if object and object.getItem ~= nil then
            local item = nil
            pcall(function() item = object:getItem() end)
            if item then return item end
        end
    end
    return nil
end

local function inventoryItem(items)
    for _, entry in ipairs(items or { }) do
        -- Vanilla passes either InventoryItem objects or { items = {...} }
        -- groups, and the first entry is a duplicate selector row.
        if type(entry) == "table" and entry.items then
            if entry.items[1] then return entry.items[1] end
        elseif itemFullType(entry) then
            return entry
        end
    end
    return nil
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    if test then return end
    addFilters(playerNum, context, worldItem(worldobjects))
end)

Events.OnFillInventoryObjectContextMenu.Add(function(playerNum, context, items)
    addFilters(playerNum, context, inventoryItem(items))
end)
