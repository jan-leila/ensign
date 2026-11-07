-- 40_menus.lua: controller handling for every non-combat screen (main menu, hangar,
-- options, events, store, ship screens, star map, dialogs). The native side
-- enumerates the clickable rectangles; this module navigates and clicks them.
--
-- Star map: only the beacons you can actually jump to are targets, plus the map's own
-- buttons. The d-pad steps between them. The stick points: while it is held, the beacon
-- in that direction from the frame is highlighted; letting the stick snap back (a flick)
-- moves the frame there, so the next flick carries on from the new beacon, while easing
-- it back slowly just drops the highlight. The sector list works the same way.
-- A jumps, X waits, Y toggles the distress beacon, B closes the map.
local E = ENSIGN
local M = {}
E.menus = M
local I, C, N = nil, nil, nil

M.hits = {}
M.screen = "none"
M.lastScreen = "none"
M.hint = {}
M.stickHeld = false
M.stickCandidate = nil     -- the beacon the stick points at (committed by a flick)
local stickAnchor = nil    -- where the pointing started from
local stickHighT = -100    -- last time the stick was fully deflected
local FLICK_SECONDS = 0.15 -- a return to centre faster than this commits

local function kinds(...)
    local t = {}
    for _, k in ipairs({ ... }) do t[k] = true end
    return t
end

-- Which hits are navigable on each screen (nil = all)
local navigable = {
    starmap = kinds("location", "sector", "button", "close"),
}
-- Preferred kinds to land on when a screen (or a tab) opens
local preferred = {
    shipscreens = { "upgrade", "crewequip", "equip" },
    store = { "store", "equip" },
    starmap = { "location" },
    options = { "choice" },
    event = { "choice" },
    shipbuilder = { "button" },
}
local function preferredHit(screen, hits)
    for _, k in ipairs(preferred[screen] or {}) do
        for _, h in ipairs(hits) do if h.kind == k and h.enabled ~= false then return h end end
    end
    return nil
end
local lastTab = nil
local function currentTab(hits)
    for _, h in ipairs(hits) do if h.kind == "tab" and h.id < 10 then return h.extra end end
    return nil
end

-- kinds that are picked up with A and dropped with A again (inventory / crew screens)
local PICKABLE = { equip = true, crewequip = true }
M.carry = nil

local function playerCrewCount()
    local ok, n = pcall(function()
        local list, n = E.playerShip().vCrewList, 0
        for i = 0, list:size() - 1 do local c = list[i]; if c and c.iShipId == 0 and not c.bDead then n = n + 1 end end
        return n
    end)
    return ok and n or 0
end

-- equipment slots: hide the weapon/drone rows the game does not show, and skip empty
-- slots unless something is being carried (then they are drop targets)
local function equipVisible(h, crewCount)
    if h.kind == "crewequip" then
        -- the manifest fills its boxes in crew order, so the first `crewCount` are occupied
        return h.id < crewCount or M.carry ~= nil
    end
    if h.kind == "button" and h.id >= 300 and h.id < 500 then return h.id % 100 < crewCount end   -- dismiss / rename
    if h.kind ~= "equip" then return true end
    local ok, hidden = pcall(function()
        local ship = E.playerShip()
        local ws, ds = ship.myBlueprint.weaponSlots, ship.myBlueprint.droneSlots
        if h.id < ws and not ship:HasSystem(3) then return true end
        if h.id >= ws and h.id < ws + ds and not ship:HasSystem(4) then return true end
        return false
    end)
    if ok and hidden then return false end
    if h.label == "empty" and not M.carry then return false end
    return true
end

local function clickFocus(button, opts)
    if C.mode == "free" or not C.focus then
        C.click(button, opts)
    else
        C.snapTo(C.focus)
        C.click(button, opts)
    end
end

local function findHit(kind, id)
    for _, h in ipairs(M.hits) do if h.kind == kind and (id == nil or h.id == id) then return h end end
    return nil
end

-- Activate a hit through the game's own handler for that screen (no mouse emulation);
-- returns false when there is no direct route, so the caller clicks instead.
local function activate(screen, h)
    if not h then return false end
    local cx, cy = E.center(h)
    if screen == "event" and h.kind == "choice" then return Ensign.choiceClick(cx, cy) end
    if screen == "starmap" then
        -- the sector list has its own close button; the map's close button closes the map
        if h.kind == "close" then if findHit("sector") then return Ensign.mapClick(cx, cy) end return Ensign.mapClose() end
        if h.kind == "location" or h.kind == "button" or h.kind == "sector" then return Ensign.mapClick(cx, cy) end
    end
    if screen == "store" then
        if h.kind == "store" or (h.kind == "tab" and h.id >= 10) or (h.kind == "close" and h.id == 201) then return Ensign.storeClick(cx, cy) end
        if h.kind == "tab" then return Ensign.tabSet(1, h.id) end
    end
    if screen == "shipscreens" and h.kind == "tab" then return Ensign.tabSet(0, h.id) end
    return false
end
local function activateOrClick(screen, h)
    if not activate(screen, h) then C.snapTo(h); C.click(1) end
end

local function cycleTabs(dir)
    local tabs = N.filterKind(M.hits, kinds("tab"))
    if #tabs == 0 then return false end
    table.sort(tabs, function(a, b) return a.x < b.x end)
    local idx = 1
    for i, t in ipairs(tabs) do if C.focus and E.sameHit(t, C.focus) then idx = i end end
    -- prefer the currently selected tab (extra = currentTab for tabbed windows)
    local cur = tabs[1].extra
    for i, t in ipairs(tabs) do if t.id == cur then idx = i end end
    idx = idx + dir
    if idx < 1 then idx = #tabs elseif idx > #tabs then idx = 1 end
    activateOrClick(M.screen, tabs[idx])
    return true
end

-- star map helpers: bit 1 = current beacon, bit 2 = reachable from it
local function isCurrent(h) return h.kind == "location" and h.extra % 2 == 1 end
local function isReachable(h) return h.kind == "location" and (h.extra // 2) % 2 == 1 end
local function currentBeacon(hits)
    for _, h in ipairs(hits) do if isCurrent(h) then return h end end
    return nil
end

function M.update(screen)
    I, C, N = E.input, E.cursor, E.nav
    M.screen = screen
    M.hits = Ensign.hitboxes()
    local filter = navigable[screen]
    local crewCount = playerCrewCount()
    local cands = {}
    for _, h in ipairs(filter and N.filterKind(M.hits, filter) or M.hits) do
        local ok = equipVisible(h, crewCount)
        -- every beacon on the map takes the frame (the game shows its tooltip); only reachable ones jump
        if ok and screen == "starmap" and (h.kind == "button" or h.kind == "close") and h.enabled == false then ok = false end
        if ok then cands[#cands + 1] = h end
    end
    if screen ~= M.lastScreen then
        -- new screen: focus the most sensible default
        C.focus = nil
        M.lastScreen = screen
        M.stickHeld = false
        local def = findHit("confirm_yes") or preferredHit(screen, cands) or findHit("choice", 0) or findHit("button", 0)
        if def and screen ~= "starmap" then C.snapTo(def) end
        lastTab = currentTab(M.hits)
        if screen == "starmap" then
            -- start on the reachable beacon nearest to the one we are at
            local here = currentBeacon(M.hits)
            local hx, hy = here and E.center(here) or C.x, here and select(2, E.center(here)) or C.y
            local first = N.nearest(hx, hy, cands, isReachable) or N.nearest(hx, hy, cands)
            if first then C.mode = "snap"; C.snapTo(first) end
        end
    else
        local tab = currentTab(M.hits)
        if tab ~= lastTab then
            lastTab = tab
            local def = preferredHit(screen, cands)
            if def then C.snapTo(def) end
        end
        C.focus = N.refresh(C.focus, cands)
        if not C.focus and C.mode == "snap" and #cands > 0 then C.snapTo(preferredHit(screen, cands) or N.nearest(C.x, C.y, cands)) end
    end

    -- analog cursor
    C.updateFree()

    -- star map: point with the stick, flick to commit
    local stickDrives = false
    if screen == "starmap" then
        local sx, sy, mag = I.navAxis()
        local now = E.time
        if mag > 0.5 then
            if not M.stickHeld then M.stickHeld = true; stickAnchor = C.focus or currentBeacon(M.hits) end
            stickHighT = now
            local from = stickAnchor
            local fx, fy = from and E.center(from) or C.x, from and select(2, E.center(from)) or C.y
            local pick = N.pickAngle(fx, fy, cands, math.atan(sy, sx), math.rad(55),
                                     function(h) return (h.kind == "location" or h.kind == "sector") and not (from and E.sameHit(h, from)) end)
            if pick and not (M.stickCandidate and E.sameHit(pick, M.stickCandidate)) then E.feedback.tick() end
            M.stickCandidate = pick
            stickDrives = true
        elseif M.stickHeld then
            if mag < 0.2 then
                -- released: a quick return (flick) moves the frame, a slow one just lets go
                if M.stickCandidate and (now - stickHighT) < FLICK_SECONDS then
                    C.mode = "snap"; C.snapTo(M.stickCandidate); E.feedback.tick()
                end
                M.stickHeld = false; M.stickCandidate = nil; stickAnchor = nil
            else
                stickDrives = true
            end
        end
    else
        M.stickHeld = false; M.stickCandidate = nil; stickAnchor = nil
    end

    local dir = I.navDirection()
    if dir and not stickDrives then
        local from = C.focus or { x = C.x - 1, y = C.y - 1, w = 2, h = 2, kind = "_cursor", id = -1 }
        local nxt = N.pick(from, cands, dir, function(h) return h.enabled ~= false end)
        if not nxt and not C.focus then nxt = N.nearest(C.x, C.y, cands) end
        if nxt then
            C.mode = "snap"
            C.snapTo(nxt)
            E.feedback.tick()
        end
    end

    local function dropAt(h)
        if M.carry.direct then Ensign.equipUp(E.center(h)) else C.snapTo(h); C.release(1) end
    end
    if M.carry and screen ~= M.carry.screen then dropAt(M.carry.origin); M.carry = nil end
    if M.carry and I.pressed("menu_drop") then
        dropAt(C.focus or M.carry.origin)   -- drop where the frame is
        M.carry = nil
    elseif not M.carry and C.focus and PICKABLE[C.focus.kind] and I.pressed("menu_pickup") then
        C.snapTo(C.focus)
        local direct = C.focus.kind == "equip" and Ensign.equipClick(E.center(C.focus))
        if not direct then C.press(1) end   -- the crew tab has no direct route: the button stays held while the frame moves
        M.carry = { origin = C.focus, screen = screen, direct = direct }
    elseif not M.carry and (I.pressed("menu_select") or I.pressed("cursor_click")) then
        if screen == "rename" or screen == "input" then
            C.key(E.KEY.RETURN)
        elseif screen == "starmap" and C.focus and C.focus.kind == "location" and not isReachable(C.focus) then -- luacheck: ignore 542
            -- the current beacon or one out of range: nothing to do (the hint says so)
        elseif screen == "starmap" and C.focus and C.focus.kind == "location" and M.lastLocation and E.sameHit(C.focus, M.lastLocation) then
            -- second press on the same beacon: jump
            local jb = findHit("button", 1)
            if jb then activateOrClick(screen, jb); C.snapTo(C.focus) end
        elseif C.focus and C.mode ~= "free" and activate(screen, C.focus) then
            if screen == "starmap" and C.focus.kind == "location" then M.lastLocation = C.focus end
        else
            clickFocus(1)
            if screen == "starmap" and C.focus and C.focus.kind == "location" then M.lastLocation = C.focus end
        end
    end
    if screen == "starmap" then
        if I.pressed("menu_alt") then
            local wait = findHit("button", 2)
            if wait and wait.enabled ~= false then activateOrClick(screen, wait); if C.focus then C.snapTo(C.focus) end end
        end
        if I.pressed("menu_info") then
            local d = findHit("button", 3)
            if d and d.enabled ~= false then activateOrClick(screen, d); if C.focus then C.snapTo(C.focus) end end
        end
        if I.pressed("map_next_sector") then
            local nb = findHit("button", 4)
            if nb and nb.enabled ~= false then activateOrClick(screen, nb) end
        end
        if I.pressed("map_cancel") then
            local cl = findHit("close")
            if cl then activateOrClick(screen, cl) end
        end
    elseif screen == "event" and not M.carry then
        for n = 1, 8 do
            if I.pressed("choice_" .. n) then
                local ch = findHit("choice", n - 1)
                if ch then C.snapTo(ch); activateOrClick(screen, ch) end
            end
        end
    end
    if screen ~= "starmap" and (I.pressed("menu_alt") or I.pressed("cursor_rclick")) then
        clickFocus(3)
    end
    if M.carry and I.pressed("menu_put_back") then
        dropAt(M.carry.origin)     -- put it back
        M.carry = nil
    elseif not M.carry and I.pressed("menu_back") then
        if screen == "confirm" then
            local no = findHit("confirm_no")
            if no then C.snapTo(no); C.click(1) end
        elseif screen == "mainmenu" then -- luacheck: ignore 542
        elseif screen == "credits" then
            C.click(1)
        elseif screen == "shipbuilder" then
            local b = findHit("button", 2)  -- "back" to the main menu
            if b then C.snapTo(b); C.click(1) else C.key(E.KEY.ESC) end
        elseif screen == "starmap" then
            local cl = findHit("close")
            if cl then activateOrClick(screen, cl)
            elseif not Ensign.mapClose() then C.key(E.KEY.ESC) end
        elseif screen == "store" or screen == "shipscreens" then
            local cl = findHit("close", 200) or findHit("close")
            if cl then C.snapTo(cl); C.click(1) else C.key(E.KEY.ESC) end
        else
            C.key(E.KEY.ESC)
        end
    end
    if I.pressed("menu_tab_prev") then cycleTabs(-1) end
    if I.pressed("menu_tab_next") then cycleTabs(1) end
    if I.pressed("menu_escape") then C.key(E.KEY.ESC) end

    -- HUD hints
    local hint = { { "nav_up", "Move cursor" }, { "menu_select", "Select" } }
    if screen == "confirm" then hint[#hint + 1] = { "menu_back", "No" }
    elseif screen == "starmap" then
        if findHit("sector") then
            hint = { { "nav_up", "Pick sector" }, { "menu_select", "Choose" }, { "menu_back", "Cancel" } }
        else
            local f = C.focus
            local sel = "Jump there"
            if f and f.kind == "location" then
                if isCurrent(f) then sel = "You are here" elseif not isReachable(f) then sel = "Out of range" end
            elseif f and (f.kind == "button" or f.kind == "close") then sel = "Select" end
            hint = { { "nav_up", "Pick beacon" }, { "menu_select", sel }, { "menu_alt", "Wait here" },
                     { "menu_info", "Distress beacon" }, { "menu_back", "Close map" } }
        end
    elseif screen == "store" or screen == "shipscreens" then
        if M.carry then hint = { { "nav_up", "Move item" }, { "menu_drop", "Place here" }, { "menu_put_back", "Put back" } }
        else
            if C.focus and PICKABLE[C.focus.kind] then hint[2] = { "menu_pickup", "Pick up" }
            elseif screen == "store" and C.focus and C.focus.kind == "store" then hint[2] = { "menu_select", "Buy" } end
            hint[#hint + 1] = { "menu_tab_next", "Next tab" }; hint[#hint + 1] = { "menu_back", "Close" }
        end
    elseif screen == "options" or screen == "pausemenu" or screen == "scores" then
        hint[#hint + 1] = { "menu_back", "Close" }
    elseif screen == "rename" or screen == "input" then
        hint = { { "menu_select", "Confirm" }, { "menu_back", "Cancel" } }
    elseif screen == "shipbuilder" or screen == "shipselect" then
        hint[#hint + 1] = { "menu_tab_next", "Ship type" }; hint[#hint + 1] = { "menu_back", "Back" }
    elseif screen == "event" then
        hint[2] = { "menu_select", "Choose" }
    end
    M.hint = hint
end

function M.render()
    if C.mode == "snap" and C.focus then
        C.drawFrame(C.focus)
    end
    if M.stickCandidate then C.drawFrame(M.stickCandidate, Graphics.GL_Color(1, 1, 1, 0.5), 2) end
end
