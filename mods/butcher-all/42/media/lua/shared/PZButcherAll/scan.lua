-- PZButcherAll/scan.lua
--
-- The pure half of the add-on: find zombie corpses on the player's floor
-- inside a Euclidean radius, nearest first. Keeping it here (not in the
-- client file) is what makes it testable without a running game; the client
-- file owns the context menu and the walk/action chain.
--
-- `cell` is passed in instead of read from `getCell()` so a check can supply a
-- fake grid. `instanceof` is PZ's own Java-type test.

PZButcherAll = PZButcherAll or {}
PZButcherAll.scan = PZButcherAll.scan or {}

-- `skeletons == false` returns corpses that still have flesh to butcher;
-- `true` returns the skeletons the vanilla butcher action leaves behind.
-- `isZombie()` is true for both, and `isAnimal()` excludes animal carcasses
-- (which Zombie Butchery does not handle).
function PZButcherAll.scan.collect(cell, x0, y0, z0, radius, skeletons)
    local found = { }
    if not cell then
        return found
    end

    local limit = math.floor(tonumber(radius) or 0)
    if limit < 1 then
        return found
    end

    for dx = -limit, limit do
        for dy = -limit, limit do
            if dx * dx + dy * dy <= limit * limit then
                local square = cell:getGridSquare(x0 + dx, y0 + dy, z0)
                if square then
                    local objects = square:getStaticMovingObjects()
                    if objects then
                        for i = 0, objects:size() - 1 do
                            local body = objects:get(i)
                            if
                                body
                                and instanceof(body, "IsoDeadBody")
                                and body:isZombie()
                                and not body:isAnimal()
                                and body:isSkeleton() == skeletons
                            then
                                found[#found + 1] = {
                                    body = body,
                                    dist = math.sqrt(dx * dx + dy * dy),
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(found, function(a, b)
        return a.dist < b.dist
    end)
    return found
end

return PZButcherAll.scan
