-- PZAreaTasksFilter/I18n.lua
--
-- One fallback-aware key lookup so a missing translation cannot leave a raw
-- `UI_...` key on screen. The mod ships English only; `getText` returns the key
-- itself when it has nothing, which is what the fallback exists for.

PZAreaTasksFilter = PZAreaTasksFilter or { }
if PZAreaTasksFilter.I18n then return end

local I18n = { }
PZAreaTasksFilter.I18n = I18n

function I18n.text(key, fallback)
    local value = getText(key)
    if type(value) ~= "string" or value == "" or value == key then
        return fallback or key
    end
    return value
end
