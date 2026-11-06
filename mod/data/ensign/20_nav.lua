-- 20_nav.lua: spatial navigation over rectangles ("hits" from the native side
-- or synthesized by the game module).
local E = ENSIGN
local N = {}
E.nav = N

-- Pick the best candidate in a direction from the focused rect.
-- Standard "beam" scoring: distance along the axis plus a penalty for off-axis offset.
function N.pick(from, candidates, dir, filter, strict)
    if not from then return candidates[1] end
    local fx, fy = E.center(from)
    local best, bestScore = nil, math.huge
    for _, h in ipairs(candidates) do
        if (not filter or filter(h)) and not E.sameHit(h, from) then
            local cx, cy = E.center(h)
            local dx, dy = cx - fx, cy - fy
            local along, across
            if dir == "up" then along, across = -dy, math.abs(dx)
            elseif dir == "down" then along, across = dy, math.abs(dx)
            elseif dir == "left" then along, across = -dx, math.abs(dy)
            else along, across = dx, math.abs(dy) end
            -- overlapping extents count as "aligned": reduce the across penalty
            local overlap
            if dir == "up" or dir == "down" then
                overlap = math.min(from.x + from.w, h.x + h.w) - math.max(from.x, h.x)
            else
                overlap = math.min(from.y + from.h, h.y + h.h) - math.max(from.y, h.y)
            end
            if along > 1 and (not strict or across <= along * 1.1) then
                local penalty = overlap > 0 and across * 0.6 or across * 2.2
                local score = along + penalty
                if score < bestScore then best, bestScore = h, score end
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
