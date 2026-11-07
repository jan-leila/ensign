-- 20_nav.lua: spatial navigation over rectangles ("hits" from the native side
-- or synthesized by the game module).
local E = ENSIGN
local N = {}
E.nav = N

-- Pick the best candidate in a direction from the focused rect.
-- Two tiers, like a desktop focus search: anything whose extent overlaps the focused
-- rect across the axis of travel (the same row or column) wins over everything else,
-- nearest first. Failing that, candidates inside a 45-degree cone in that direction
-- (90 degrees wide), the most aligned one first: a sideways offset costs four times
-- what the same distance along the axis does. Anything outside the cone is not "in that direction": the caller then
-- crosses into the neighbouring group instead of lurching diagonally.
function N.pick(from, candidates, dir, filter, strict)
    if not from then return candidates[1] end
    local fx, fy = E.center(from)
    local best, bestScore, bestTier = nil, math.huge, 3
    for _, h in ipairs(candidates) do
        if (not filter or filter(h)) and not E.sameHit(h, from) then
            local cx, cy = E.center(h)
            local dx, dy = cx - fx, cy - fy
            local along, across
            if dir == "up" then along, across = -dy, math.abs(dx)
            elseif dir == "down" then along, across = dy, math.abs(dx)
            elseif dir == "left" then along, across = -dx, math.abs(dy)
            else along, across = dx, math.abs(dy) end
            local overlap, gap   -- extent shared across the axis; free space between the two rects along it
            if dir == "up" or dir == "down" then
                overlap = math.min(from.x + from.w, h.x + h.w) - math.max(from.x, h.x)
                gap = (dir == "up") and (from.y - (h.y + h.h)) or (h.y - (from.y + from.h))
            else
                overlap = math.min(from.y + from.h, h.y + h.h) - math.max(from.y, h.y)
                gap = (dir == "left") and (from.x - (h.x + h.w)) or (h.x - (from.x + from.w))
            end
            -- a rect the frame already overlaps along the axis is not "further that way"
            if along > 1 and gap >= -10 then
                local tier, score
                if overlap > 0 then tier, score = 1, along + across * 0.3
                elseif across <= along * (strict and 1.1 or 1.0) then tier, score = 2, along + across * 4 end   -- the most aligned wins over the nearest
                if tier and (tier < bestTier or (tier == bestTier and score < bestScore)) then
                    best, bestScore, bestTier = h, score, tier
                end
            end
        end
    end
    return best
end

-- Candidate whose bearing from (x, y) is closest to the stick angle (radians, 0 = right,
-- counter-clockwise, y up on screen). Rejects anything more than `maxDiff` off.
function N.pickAngle(x, y, candidates, angle, maxDiff, filter)
    local best, bestScore = nil, math.huge
    for _, h in ipairs(candidates) do
        if not filter or filter(h) then
            local cx, cy = E.center(h)
            local dx, dy = cx - x, y - cy
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > 1 then
                local diff = math.abs(math.atan(dy, dx) - angle)
                if diff > math.pi then diff = 2 * math.pi - diff end
                if diff <= maxDiff then
                    local score = diff * 200 + dist * 0.15   -- bearing first, then distance
                    if score < bestScore then best, bestScore = h, score end
                end
            end
        end
    end
    return best
end

-- Nearest candidate to a point (used when switching panels or leaving free-cursor mode).
function N.nearest(x, y, candidates, filter)
    local best, bestD = nil, math.huge
    for _, h in ipairs(candidates) do
        if not filter or filter(h) then
            if E.contains(h, x, y) then return h end
            local cx, cy = E.center(h)
            local d = (cx - x) ^ 2 + (cy - y) ^ 2
            if d < bestD then best, bestD = h, d end
        end
    end
    return best
end

-- Re-find the equivalent of `focus` in a fresh hit list (geometry may move).
function N.refresh(focus, candidates)
    if not focus then return nil end
    for _, h in ipairs(candidates) do if E.sameHit(h, focus) then return h end end
    return nil
end

function N.filterKind(hits, kinds)
    local out = {}
    for _, h in ipairs(hits) do if kinds[h.kind] then out[#out + 1] = h end end
    return out
end
