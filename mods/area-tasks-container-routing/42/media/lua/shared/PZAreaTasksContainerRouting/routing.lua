-- PZAreaTasksContainerRouting/routing.lua
--
-- Pure decision logic for preset-aware Area Tasks deliveries: given Manage
-- Containers' per-container configuration, does a destination container accept
-- an item?  No game objects, no globals beyond this module, so
-- checks/default.nix can exercise it with plain Lua.
--
-- The acceptance test is deliberately the same one Manage Containers' own
-- "Put in assigned containers" action uses
-- (`ISInventoryPaneContextMenu.TransferItems`):
--
--     (category listed AND type not excluded) OR type explicitly included
--
-- Anything the mod does not recognise degrades to "accepts everything", because
-- the alternative is a container that silently swallows a route: a rule set
-- that says nothing (a container that was only renamed, or a config written by
-- a future version) must never behave like a black hole.
PZAreaTasksContainerRouting = PZAreaTasksContainerRouting or { }
if PZAreaTasksContainerRouting.Routing then return end

local Routing = { }
PZAreaTasksContainerRouting.Routing = Routing

--- Build the rule for one container index, or nil when the container is not
--- configured (accepts everything).
---
--- `filters` and `selection` are Manage Containers' `containersFilters` and
--- `exclusiveSelection` tables, keyed by the 1-based container index on the
--- parent IsoObject. A container with an empty filter list and empty
--- include/exclude lists produces nil: that is "unconfigured", not "accepts
--- nothing".
function Routing.rule(filters, selection, index)
    local categories = filters and filters[index]
    local selected = selection and selection[index]
    if type(categories) ~= "table" or type(selected) ~= "table" then return nil end

    local include, exclude = selected.Include, selected.Exclude
    local hasCategories = #categories > 0
    local hasInclude = type(include) == "table" and #include > 0
    local hasExclude = type(exclude) == "table" and #exclude > 0
    if not (hasCategories or hasInclude or hasExclude) then return nil end

    local rule = { categories = { }, include = { }, exclude = { } }
    for _, category in ipairs(categories) do rule.categories[category] = true end
    if hasInclude then
        for _, fullType in ipairs(include) do rule.include[fullType] = true end
    end
    if hasExclude then
        for _, fullType in ipairs(exclude) do rule.exclude[fullType] = true end
    end
    return rule
end

--- Does this rule accept the item?  `nil` rule means unconfigured.
--- `category` and `fullType` may be nil (items with no script); an explicit
--- include still wins in that case, and a category rule simply cannot match.
function Routing.accepts(rule, category, fullType)
    if rule == nil then return true end
    if fullType and rule.include[fullType] then return true end
    if category and rule.categories[category] then
        return not (fullType and rule.exclude[fullType])
    end
    return false
end
