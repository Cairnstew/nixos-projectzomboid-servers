-- PZViewpointLevel15/install.lua
--
-- Viewpoint draws its own Skills tab (`ViewpointInvTabSkills`) and that tab
-- hard-codes ten slots:
--
--     local LEVELS = 10
--     ...
--     self.square = math.max(6, math.min(math.floor(self.row * 0.62),
--         math.floor(room / LEVELS * 0.8)))
--     self.step = self.square + math.max(2, math.floor(self.square / 4))
--
-- Beyond Ten (`BeyondTen`) raises the trainable cap to 15 and patches the
-- vanilla `ISSkillProgressBar` helpers, which Viewpoint calls for the XP maths
-- (Viewpoint_InvTabSkills.lua:64-65 -> `ISSkillProgressBar.getXpForLvl` and
-- `getPreviousXpLvl`). So a level-12 perk already has correct progress
-- numbers; what Viewpoint keeps is ten-slot geometry, so it lays out 15 pips
-- with 10-slot spacing and the row overruns into the XP column by half its
-- width.
--
-- `LEVELS` is a file-local upvalue, so it cannot be patched from outside. The
-- layout it feeds is computed from fields `layout` stores on the tab itself
-- (`box`, `nameX`, `nameW`, `row`, `m.pad`), so this add-on wraps `layout`,
-- re-runs the same formula with 15 as the slot count, and leaves every other
-- field alone. Nothing is copied from Viewpoint.
--
-- What this cannot fix: `T:squares` loops `1 .. LEVELS` for the locked slots
-- and skips the in-progress square when `bar.level >= LEVELS`, both against
-- its own upvalue. With 15 slots that means a level 11-14 row shows its filled
-- pips and no progress square, and levels 11-15 never show "locked" hints -
-- the same thing Viewpoint already does at level 10 today. Hovering a pip past
-- 10 reports the level-10 tooltip (`note` clamps to `LEVELS - 1`). Those are
-- cosmetic and cost far less than forking the rendering.
--
-- Fail-closed rules:
--   * no `BeyondTen` table, or MAX_LEVEL <= 10 -> no wrap at all;
--   * no `ViewpointInvTabSkills.layout` -> no wrap;
--   * a layout call that leaves out a field we need -> geometry untouched;
--   * a row that already fits 15 pips (Viewpoint ships a wider grid later) ->
--     geometry untouched, so upstream wins.
-- The hook is pcall-guarded: an upstream change that makes `refit` throw
-- leaves Viewpoint's own ten-slot render in place rather than breaking it.

PZViewpointLevel15 = PZViewpointLevel15 or { }
local M = PZViewpointLevel15

-- Beyond Ten's cap. Kept as a fallback only; the live value is read from
-- BeyondTen.MAX_LEVEL so a future cap change needs no edit here.
M.MAX_LEVEL = 15

--- Slot geometry for `levels` pips in `room` pixels.
---
--- Same arithmetic as Viewpoint's `layout`, with the slot count as an
--- argument. `room` is the width left for the pip row; `row` is the height of
--- one skill line. Returns nil for unusable input rather than guessing.
function M.fitSlots(room, row, levels)
    levels = tonumber(levels) or M.MAX_LEVEL
    room, row = tonumber(room), tonumber(row)
    if not room or not row or room <= 0 or row <= 0 or levels <= 0 then return nil end

    local square = math.max(6, math.min(math.floor(row * 0.62), math.floor(room / levels * 0.8)))
    local step = square + math.max(2, math.floor(square / 4))
    return square, step
end

--- Re-space a tab that `layout` already sized for ten slots.
---
--- Takes the tab itself, so the check can drive it with a plain table. Returns
--- true only when it actually changed the geometry.
function M.refit(view, levels)
    if type(view) ~= "table" then return false end

    local box, m = view.box, view.m
    if type(box) ~= "table" or type(m) ~= "table" then return false end

    local pad, nameX, nameW, row = tonumber(m.pad), tonumber(view.nameX), tonumber(view.nameW), tonumber(view.row)
    if not pad or not nameX or not nameW or not row then return false end

    local room = tonumber(box.w) - nameX - nameW - pad * 3
    local step = tonumber(view.step)
    if not step or step <= 0 then return false end

    -- Viewpoint's formula leaves step at 1.25 * square, so N pips need
    -- N * 1.25 * square. If the row it produced already holds `levels`, this is
    -- not one of ours to change (upstream shipped a wider grid, or a consumer
    -- patched it first).
    if levels * step <= room then return false end

    local square, resized = M.fitSlots(room, row, levels)
    if not square then return false end

    view.square, view.step = square, resized
    return true
end

--- Wrap `ViewpointInvTabSkills.layout` once. Returns false when `levels` is
--- not worth drawing (<= 10) or the tab is not there.
function M.apply(levels)
    levels = tonumber(levels) or M.MAX_LEVEL
    if levels <= 10 then return false end

    local tab = ViewpointInvTabSkills
    if type(tab) ~= "table" or type(tab.layout) ~= "function" then return false end
    if tab._pzLevel15 then return true end

    local original = tab.layout
    tab.layout = function(self, area, m)
        original(self, area, m)
        -- Never throw inside Viewpoint's render: a changed `layout` simply
        -- stops shrinking and ten-slot geometry stays.
        pcall(M.refit, self, levels)
    end
    tab._pzLevel15 = true
    return true
end

local function install()
    local beyond = BeyondTen
    if type(beyond) ~= "table" then return false end
    return M.apply(tonumber(beyond.MAX_LEVEL) or M.MAX_LEVEL)
end

install()

-- The pack's load order puts this mod after Viewpoint and Beyond Ten, but a
-- different consumer may not. Retrying once at game start costs nothing and
-- `apply` is idempotent.
if type(Events) == "table" and type(Events.OnGameStart) == "table" and Events.OnGameStart.Add then
    Events.OnGameStart.Add(install)
end

return M
