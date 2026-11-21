-- PZAreaTasksFilter/UI.lua
--
-- One clean editor panel: mode buttons, a search box, a scrollable type list
-- with checkboxes, and bulk select/clear for the current results. It is built
-- from stock ISUI elements only, so it follows the game's font and layout scale.
--
-- The catalogue is every item script the running mod set defines, sorted by
-- display name. The search is a plain substring match on the name and the full
-- type, and results are capped (MAX_RESULTS) so a 400-mod pack stays responsive.
-- With an empty search the list shows the types you already listed, which is the
-- useful view when you open the panel to review or remove entries.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "PZAreaTasksFilter/state"
require "PZAreaTasksFilter/i18n"

PZAreaTasksFilter = PZAreaTasksFilter or { }
if PZAreaTasksFilter.UI then return end

local T = PZAreaTasksFilter.I18n.text
local State = PZAreaTasksFilter.State
local Filter = PZAreaTasksFilter.Filter
local UI = { panels = { } }
PZAreaTasksFilter.UI = UI

local PAD = 12
local ROW_H = 22
local MAX_RESULTS = 250

local function addCategory(categories, seen, category)
    if type(category) ~= "string" or category == "" or seen[category] then return end
    seen[category] = true
    local name = nil
    pcall(function() name = getText("IGUI_ItemCat_" .. category) end)
    if type(name) ~= "string" or name == "" or name == "IGUI_ItemCat_" .. category then
        name = category
    end
    categories[#categories + 1] = {
        kind = "category",
        category = category,
        name = name,
        nameLower = name:lower(),
        keyLower = category:lower(),
    }
end

local function buildCatalog()
    local catalog, categories = { }, { }
    local seenCategories = { }
    local ok = pcall(function()
        local scripts = nil
        pcall(function() scripts = getScriptManager():getAllItems() end)
        if not scripts then pcall(function() scripts = getAllItems() end) end
        if not scripts then error("no item list") end
        for index = 0, scripts:size() - 1 do
            local script = scripts:get(index)
            local fullType = nil
            pcall(function() fullType = script:getFullName() end)
            if type(fullType) == "string" and fullType ~= "" then
                local name = nil
                pcall(function() name = getItemNameFromFullType(fullType) end)
                if type(name) ~= "string" or name == "" or name == fullType then
                    pcall(function() name = script:getName() end)
                end
                if type(name) ~= "string" or name == "" then name = fullType end
                catalog[#catalog + 1] = {
                    kind = "item",
                    fullType = fullType,
                    name = name,
                    nameLower = name:lower(),
                    fullTypeLower = fullType:lower(),
                }
                -- Categories come from the scripts for the same reason the game
                -- does it that way: no instance has to be created.
                local category = State.textOf(script, "getDisplayCategory")
                    or State.textOf(script, "getCategory")
                addCategory(categories, seenCategories, category)
            end
        end
    end)
    if not ok then return { items = { }, categories = { } } end
    table.sort(catalog, function(a, b)
        if a.nameLower == b.nameLower then return a.fullTypeLower < b.fullTypeLower end
        return a.nameLower < b.nameLower
    end)
    table.sort(categories, function(a, b) return a.nameLower < b.nameLower end)
    return { items = catalog, categories = categories }
end

local Panel = ISPanel:derive("PZAreaTasksFilterPanel")

function Panel:new(x, y, width, height, playerNum)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.background = true
    o.backgroundColor = { r = 0.05, g = 0.055, b = 0.065, a = 0.94 }
    o.borderColor = { r = 0.34, g = 0.37, b = 0.41, a = 1 }
    o.moveWithMouse = true
    return o
end

local function makeButton(panel, x, y, width, height, label, onclick)
    local button = ISButton:new(x, y, width, height, label, panel, onclick)
    button.anchorTop = true
    button:initialise()
    button:instantiate()
    panel:addChild(button)
    return button
end

function Panel:initialise()
    ISPanel.initialise(self)

    local width = self.width - PAD * 2
    self.modeButtons = { }
    local modes = {
        { id = "off", label = T("UI_AreaTasksFilter_Off", "Off") },
        { id = "only", label = T("UI_AreaTasksFilter_Only", "Only listed") },
        { id = "except", label = T("UI_AreaTasksFilter_Except", "Exclude listed") },
    }
    local buttonWidth = math.floor((width - 8) / 3)
    for index, mode in ipairs(modes) do
        local button = makeButton(self, PAD + (index - 1) * (buttonWidth + 4), 44,
            buttonWidth, 24, mode.label, Panel.onMode)
        button.internal = mode.id
        self.modeButtons[mode.id] = button
    end

    self.search = ISTextEntryBox:new("", PAD, 78, width, 24)
    self.search:initialise()
    self.search:instantiate()
    self.search:setPlaceholderText(T("UI_AreaTasksFilter_Search", "Search item types..."))
    self.search.target = self
    self.search.onTextChangeFunction = Panel.onSearch
    self:addChild(self.search)

    local half = math.floor((width - 4) / 2)
    self.selectResults = makeButton(self, PAD, 110, half, 22,
        T("UI_AreaTasksFilter_SelectResults", "Select results"), Panel.onSelectResults)
    self.deselectResults = makeButton(self, PAD + half + 4, 110, half, 22,
        T("UI_AreaTasksFilter_DeselectResults", "Clear results"), Panel.onDeselectResults)

    self.list = ISScrollingListBox:new(PAD, 140, width, self.height - 140 - 48)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = ROW_H
    self.list.font = UIFont.Small
    self.list.fontHgt = getTextManager():getFontHeight(UIFont.Small)
    self.list.drawBorder = false
    self.list.doDrawItem = Panel.doDrawItem
    self.list.filterState = State.get()
    self.list:setOnMouseDownFunction(self, Panel.onRowClick)
    self:addChild(self.list)

    self.closeButton = makeButton(self, self.width - PAD - 80, self.height - PAD - 24,
        80, 24, T("UI_AreaTasksFilter_Close", "Close"), Panel.onClose)

    self.statusText = ""
    self.shown = 0
    self:updateModeButtons()
end

function Panel:prerender()
    ISPanel.prerender(self)
    self:drawText(T("UI_AreaTasksFilter_Title", "Area Tasks Item Filter"),
        PAD, 12, 0.95, 0.95, 0.95, 1, UIFont.Medium)
    self:drawRect(PAD, 34, self.width - PAD * 2, 1, 0.5, 0.34, 0.37, 0.41)
    self:drawText(self.statusText or "", PAD, self.height - 27,
        0.72, 0.75, 0.8, 1, UIFont.Small)
end

function Panel:doDrawItem(y, item, alt)
    local height = item.height or self.itemheight
    local scroll = self:getYScroll()
    if y + scroll + height < 0 or y + scroll > self.height then
        return y + height
    end

    local entry = item.item
    if not entry then return y + height end

    if alt then
        self:drawRect(0, y, self:getWidth(), height - 1, 0.03, 1, 1, 1)
    end
    if self.mouseoverselected == item.itemindex and self:isMouseOver()
            and not self:isMouseOverScrollBar() then
        self:drawRect(0, y, self:getWidth(), height - 1, 0.06, 1, 1, 1)
    end

    local isCategory = entry.kind == "category"
    local box = 12
    local boxX = 8
    local boxY = y + math.floor((height - box) / 2)
    self:drawRect(boxX, boxY, box, box, 0.5, 0.03, 0.03, 0.03)
    self:drawRectBorder(boxX, boxY, box, box, 0.75, 0.4, 0.42, 0.46)
    local listed = false
    if isCategory then
        listed = Filter.isCategoryListed(self.filterState, entry.category)
    else
        listed = Filter.isListed(self.filterState, entry.fullType)
    end
    if listed then
        self:drawRect(boxX + 3, boxY + 3, box - 6, box - 6, 0.95, 0.88, 0.66, 0.16)
    end

    local textX = boxX + box + 8
    local nameR, nameG, nameB = 0.92, 0.92, 0.92
    if isCategory then
        -- Categories are the coarse entries; a tint keeps them visually apart
        -- from the thousands of item types below them.
        nameR, nameG, nameB = 1.0, 0.87, 0.62
        self:drawText("[category]", textX, y + 4, 0.65, 0.55, 0.35, 1, UIFont.Small)
        textX = textX + getTextManager():MeasureStringX(UIFont.Small, "[category]") + 8
    end
    self:drawText(entry.name, textX, y + 4, nameR, nameG, nameB, 1, UIFont.Small)
    local key = entry.fullType or entry.category
    local keyWidth = entry.typeWidth
    if not keyWidth then
        keyWidth = getTextManager():MeasureStringX(UIFont.Small, key)
        entry.typeWidth = keyWidth
    end
    self:drawText(key, self:getWidth() - keyWidth - 10, y + 4,
        0.5, 0.52, 0.58, 1, UIFont.Small)
    return y + height
end

function Panel:refresh(query)
    local list = self.list
    list:clear()
    list:setScrollHeight(0)
    list:setYScroll(0)
    list.smoothScrollTargetY = nil
    list.smoothScrollY = 0

    local state = State.get()
    query = (query or self.search:getText() or ""):lower()
    self.shown = 0

    local categories = self.categories or { }
    local catalog = self.catalog or { }

    if query == "" then
        -- Categories first: a short, stable list that is always worth seeing.
        local listedCategories = { }
        local seenCategory = { }
        for _, entry in ipairs(categories) do
            seenCategory[entry.category] = true
            if state.categories[entry.category] then
                list:addItem(entry.name, entry)
                listedCategories[#listedCategories + 1] = entry.category
                self.shown = self.shown + 1
            end
        end
        -- Categories saved from a previous mod set stay removable.
        local staleCategories = { }
        for category in pairs(state.categories) do
            if not seenCategory[category] then staleCategories[#staleCategories + 1] = category end
        end
        table.sort(staleCategories)
        for _, category in ipairs(staleCategories) do
            list:addItem(category, { kind = "category", category = category, name = category })
            self.shown = self.shown + 1
        end

        local seen = { }
        for _, entry in ipairs(catalog) do
            if state.types[entry.fullType] then
                list:addItem(entry.name, entry)
                seen[entry.fullType] = true
                self.shown = self.shown + 1
            end
        end
        -- Types saved from a previous mod set are not in the catalogue, so show
        -- them by their full type instead of hiding an entry the player cannot
        -- then remove.
        local stale = { }
        for fullType in pairs(state.types) do
            if not seen[fullType] then stale[#stale + 1] = fullType end
        end
        table.sort(stale)
        for _, fullType in ipairs(stale) do
            list:addItem(fullType, { kind = "item", fullType = fullType, name = fullType })
            self.shown = self.shown + 1
        end
    else
        for _, entry in ipairs(categories) do
            if entry.nameLower:find(query, 1, true) or entry.keyLower:find(query, 1, true) then
                list:addItem(entry.name, entry)
                self.shown = self.shown + 1
                if self.shown >= MAX_RESULTS then break end
            end
        end
        if self.shown < MAX_RESULTS then
            for _, entry in ipairs(catalog) do
                if entry.nameLower:find(query, 1, true)
                        or entry.fullTypeLower:find(query, 1, true) then
                    list:addItem(entry.name, entry)
                    self.shown = self.shown + 1
                    if self.shown >= MAX_RESULTS then break end
                end
            end
        end
    end

    list:setScrollHeight(self.shown * ROW_H)
    self.selectResults:setEnable(query ~= "")
    self.deselectResults:setEnable(query ~= "")
    self:updateStatus(query)
end

function Panel:updateStatus(query)
    local state = State.get()
    local count = Filter.count(state)
    local mode = state.mode
    local text
    if mode == "off" then
        text = T("UI_AreaTasksFilter_Off", "Off")
    elseif mode == "only" then
        text = T("UI_AreaTasksFilter_Only", "Only listed") .. ": " .. count
    else
        text = T("UI_AreaTasksFilter_Except", "Exclude listed") .. ": " .. count
    end
    if query and query ~= "" then
        text = text .. "  |  " .. T("UI_AreaTasksFilter_Shown", "shown") .. ": " .. self.shown
    elseif self.shown == 0 then
        text = text .. "  |  " .. T("UI_AreaTasksFilter_Hint", "Type to search and click a type")
    end
    self.statusText = text
end

function Panel:updateModeButtons()
    local activeMode = State.get().mode
    for mode, button in pairs(self.modeButtons) do
        if mode == activeMode then
            button.backgroundColor = { r = 0.46, g = 0.31, b = 0.11, a = 1 }
            button.borderColor = { r = 0.85, g = 0.65, b = 0.3, a = 1 }
        else
            button.backgroundColor = { r = 0.1, g = 0.1, b = 0.11, a = 1 }
            button.borderColor = { r = 0.4, g = 0.4, b = 0.42, a = 1 }
        end
    end
end

function Panel:onMode(button)
    State.setMode(button.internal)
    self:updateModeButtons()
    self:refresh()
end

function Panel:onSearch(entry)
    self:refresh(entry:getText())
end

function Panel:onRowClick(entry)
    if not entry then return end
    if entry.kind == "category" then
        State.toggleCategory(entry.category)
    else
        State.toggle(entry.fullType)
    end
    self:refresh()
end

local function setRowListed(entry, listed)
    if entry.kind == "category" then
        Filter.setCategoryListed(State.get(), entry.category, listed)
    elseif entry.fullType then
        Filter.setListed(State.get(), entry.fullType, listed)
    end
end

function Panel:onSelectResults()
    for _, row in ipairs(self.list.items) do
        setRowListed(row.item, true)
    end
    State.save()
    self:refresh()
end

function Panel:onDeselectResults()
    for _, row in ipairs(self.list.items) do
        setRowListed(row.item, false)
    end
    State.save()
    self:refresh()
end

function Panel:onClose()
    self:setVisible(false)
end

function UI.open(playerNum)
    local panel = UI.panels[playerNum]
    if not panel then
        local width = 520
        local height = math.min(560, getCore():getScreenHeight() - 100)
        local x = math.floor((getCore():getScreenWidth() - width) / 2)
        local y = math.floor((getCore():getScreenHeight() - height) / 2)
        panel = Panel:new(x, y, width, height, playerNum)
        panel.catalog = buildCatalog()
        panel.categories = panel.catalog.categories
        panel.catalog = panel.catalog.items
        panel:initialise()
        panel:addToUIManager()
        UI.panels[playerNum] = panel
    end
    panel.list.filterState = State.get()
    panel:setVisible(true)
    panel:bringToTop()
    panel:refresh()
end
