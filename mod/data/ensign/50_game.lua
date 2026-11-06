-- 50_game.lua: in-flight controls.
--
-- Panels (bumpers cycle them, focus_toggle jumps between the ships):
--   ship     room mode over your rooms; A on a room opens DETAIL mode
--   enemy    the enemy's rooms (forced while a weapon / power is aimed)
--   power    the reactor's system boxes
--   weapons  weapon and drone slots (empty slots are skipped) + autofire
--   crew     the crew portraits on the left
--   top      FTL button, ship / store / options buttons
--
-- Detail mode walks the units and doors of the ship one by one: inside a room
-- the d-pad moves between its units; leaving the room goes to the door on that
-- wall first and then into the next room. A toggles a unit in the selection
-- (selection persists across rooms) or opens/closes a door; B returns to room
-- mode, where A on a room sends the selected units there.
local E = ENSIGN
local G = {}
E.game = G
local I, C, N

G.panel = "ship"
G.hits = {}
G.panelHits = {}
G.detail = false            -- detail mode active
G.target = nil              -- current detail target: crew / door / anchor
G.targets = {}
G.drag = nil                -- "select" or "alt" while a button is held for a drag
G.targeting = nil           -- "weapon" | "beam" | "bomb" | "teleport" | "hack" | "mind" | nil
G.beamStage = 0
G.hint = {}
G.lastPanel = nil
G.prevFocus = nil

local PANEL_ORDER = { "ship", "enemy", "power", "weapons", "crew", "top" }
local PANEL_LABEL = { ship = "YOUR SHIP", enemy = "ENEMY SHIP", power = "POWER", weapons = "WEAPONS & DRONES",
                      crew = "CREW", top = "CONTROLS" }
local PREFERRED = { ship = "room", enemy = "room", power = "sysbox", weapons = "armament", crew = "crewbox", top = "ftl" }
local SYS = { shields = 0, engines = 1, oxygen = 2, weapons = 3, drones = 4, medbay = 5, pilot = 6,
              sensors = 7, doors = 8, teleporter = 9, cloaking = 10, artillery = 11, battery = 12,
              clonebay = 13, mind = 14, hacking = 15 }
-- screen layout: moving past the edge of a panel crosses into its neighbour
local NEIGHBOR = {
    ship    = { down = "weapons", up = "top", left = "crew", right = "enemy" },
    enemy   = { left = "ship", down = "weapons", up = "top" },
    weapons = { up = "ship", left = "power", right = "power" },   -- subsystems sit right of the weapons
    power   = { right = "weapons", left = "weapons", up = "crew" },
    crew    = { right = "ship", down = "power", up = "top" },
    top     = { down = "ship" },
}
local DRAG_LEFT = { armament = true }
local DRAG_RIGHT = { crewbox = true }

local function hasSystem(id)
    local ok, v = pcall(function() return E.playerShip():HasSystem(id) end)
    return ok and v or false
end

local function kindFilter(panel)
    if panel == "ship" then return function(h) return h.kind == "room" and h.extra == 0 end
    elseif panel == "enemy" then return function(h) return h.kind == "room" and h.extra == 1 end
    elseif panel == "power" then return function(h) return h.kind == "sysbox" end
    elseif panel == "weapons" then
        local w, d = hasSystem(SYS.weapons), hasSystem(SYS.drones)
        return function(h)
            if h.kind == "autofire" then return w end
            if h.kind ~= "armament" or h.label == "" then return false end   -- empty slots are skipped
            return (h.extra == 3 and w) or (h.extra == 4 and d)
        end
    elseif panel == "crew" then return function(h) return h.kind == "crewbox" or (h.kind == "button" and (h.id == 600 or h.id == 601)) end
    elseif panel == "top" then return function(h) return h.kind == "ftl" or h.kind == "topbar" end end
    return function() return false end
end

local function collect(panel)
    local f = kindFilter(panel)
    local out = {}
    for _, h in ipairs(G.hits) do if f(h) then out[#out + 1] = h end end
    return out
end
local function panelAvailable(panel) return #collect(panel) > 0 end

local function selectedCrewCount()
    local ok, n = pcall(function() return E.gui().crewControl.selectedCrew:size() end)
    return ok and n or 0
end

local function armedWeapon()
    local ok, w = pcall(function() return E.gui().combatControl.weapControl.armedWeapon end)
    if ok and w then return w end
    return nil
end

local function detectTargeting()
    local gui = E.gui()
    if not gui then return nil end
    local w = armedWeapon()
    if w then
        local ok, n = pcall(function() return w:NumTargetsRequired() end)
        if ok and n == 2 then return "beam" end
        local ok2, tn = pcall(function() return w.blueprint.typeName end)
        if ok2 and tn == "BOMB" then return "bomb" end
        return "weapon"
    end
    local okm, m = pcall(function() return Hyperspace.Mouse end)
    if okm and m then
        if m.iTeleporting and m.iTeleporting ~= 0 then return "teleport" end
        if m.iHacking and m.iHacking ~= 0 then return "hack" end
        if m.iMindControlling and m.iMindControlling ~= 0 then return "mind" end
    end
    return nil
end

-- ---- crew selection (managed through the game's own selection list) ---------
local function rebuildSelection()
    pcall(function()
        local ship = E.playerShip()
        local sel = E.gui().crewControl.selectedCrew
        sel:clear()
        local list = ship.vCrewList
        for i = 0, list:size() - 1 do
            local c = list[i]
            if c and c.selectionState == 1 and not c.bDead then sel:push_back(c) end
        end
    end)
end
local function toggleSelect(crew)
    pcall(function()
        crew.selectionState = (crew.selectionState == 1) and 0 or 1
    end)
    rebuildSelection()
end
-- FTL clears the crew selection on any left click (doors included); remember it and put it back
local function rememberSelection()
    local keep = {}
    pcall(function()
        local list = E.playerShip().vCrewList
        for i = 0, list:size() - 1 do local c = list[i]; if c and c.selectionState == 1 then keep[#keep + 1] = i end end
    end)
    return keep
end
local function restoreSelection(keep)
    pcall(function()
        local list = E.playerShip().vCrewList
        for _, i in ipairs(keep) do local c = list[i]; if c then c.selectionState = 1 end end
    end)
    rebuildSelection()
end

local function clearSelection()
    pcall(function()
        local list = E.playerShip().vCrewList
        for i = 0, list:size() - 1 do local c = list[i]; if c and c.selectionState == 1 then c.selectionState = 0 end end
    end)
    rebuildSelection()
end

-- ---- detail targets ---------------------------------------------------------
function G.allDoors()
    local out = {}
    local ship = E.playerShip()
    if not ship then return out end
    local ox, oy = Ensign.shipOrigins()
    pcall(function()
        local list = ship.ship.vDoorList
        for i = 0, list:size() - 1 do
            local d = list[i]
            if d then
                local w = d.bVertical and 10 or 35
                local h = d.bVertical and 35 or 10
                out[#out + 1] = { kind = "door", id = d.iDoorId, x = ox + d.x - w / 2, y = oy + d.y - h / 2, w = w, h = h,
                                  label = d.iRoom1 .. "," .. d.iRoom2, extra = d.bOpen and 1 or 0, r1 = d.iRoom1, r2 = d.iRoom2, door = d }
            end
        end
    end)
    return out
end

-- units, doors and (for empty rooms) an anchor, for the ship of the current panel
local function buildTargets(shipId)
    local out = {}
    local ship = E.playerShip()
    if not ship then return out end
    local px, py, ex, ey = Ensign.shipOrigins()
    local ox, oy = px, py
    if shipId == 1 then if not ex then return out end ox, oy = ex, ey end
    local occupied = {}
    pcall(function()
        local list = ship.vCrewList
        for i = 0, list:size() - 1 do
            local c = list[i]
            if c and c.currentShipId == shipId and not c.bDead and c:GetControllable() then
                out[#out + 1] = { kind = "crew", id = i, x = ox + c.x - 12, y = oy + c.y - 14, w = 24, h = 28,
                                  roomId = c.iRoomId, crew = c, label = c:GetName() }
                occupied[c.iRoomId] = true
            end
        end
    end)
    for _, h in ipairs(G.hits) do
        if h.kind == "room" and h.extra == shipId and not occupied[h.id] then
            out[#out + 1] = { kind = "anchor", id = h.id, x = h.x + h.w / 2 - 10, y = h.y + h.h / 2 - 10, w = 20, h = 20, roomId = h.id }
        end
    end
    if shipId == 0 then
        for _, d in ipairs(G.allDoors()) do out[#out + 1] = d end
    end
    return out
end

local function sameTarget(a, b)
    return a and b and a.kind == b.kind and a.id == b.id
end
local function refreshTarget(t, targets)
    if not t then return nil end
    for _, x in ipairs(targets) do
        if sameTarget(x, t) then
            if t.kind == "door" then x.roomSide = t.roomSide end
            return x
        end
    end
    return nil
end
local function targetRoom(t)
    if not t then return nil end
    if t.kind == "door" then return t.roomSide or t.r1 end
    return t.roomId
end
local function inRoom(t, roomId)
    if t.kind == "door" then return t.r1 == roomId or t.r2 == roomId end
    return t.roomId == roomId
end
-- a door counts for direction `dir` only if it sits on that wall of the room
local function doorOnWall(door, room, dir)
    if not room then return true end
    local cx, cy = E.center(door)
    if dir == "right" then return cx >= room.x + room.w - 8
    elseif dir == "left" then return cx <= room.x + 8
    elseif dir == "down" then return cy >= room.y + room.h - 8
    else return cy <= room.y + 8 end
end
local function roomHit(roomId, shipId)
    for _, h in ipairs(G.hits) do if h.kind == "room" and h.extra == shipId and h.id == roomId then return h end end
    return nil
end

local function enterDetail(room, shipId)
    G.targets = buildTargets(shipId)
    local best, bestD = nil, math.huge
    local cx, cy = E.center(room)
    for _, t in ipairs(G.targets) do
        if t.kind ~= "door" and t.roomId == room.id then
            local tx, ty = E.center(t)
            local d = (tx - cx) ^ 2 + (ty - cy) ^ 2 - (t.kind == "crew" and 1e6 or 0)   -- prefer units
            if d < bestD then best, bestD = t, d end
        end
    end
    if not best then return false end
    G.detail = true
    G.target = best
    C.moveTo(E.center(best))
    E.feedback.tick()
    return true
end

local function leaveDetail()
    G.detail = false
    G.target = nil
end

-- d-pad in detail mode: same room first, then the door on that wall, then the next room
local function detailNav(dir, shipId)
    local cur = G.target
    if not cur then return end
    local R = targetRoom(cur)
    local function pickFrom(list, extra)
        local cands = {}
        for _, t in ipairs(list) do if not sameTarget(t, cur) and (not extra or extra(t)) then cands[#cands + 1] = t end end
        return N.pick(cur, cands, dir, nil, true)   -- strict cone: only what is really in that direction
    end
    local roomR = roomHit(R, shipId)
    -- 1. inside the current room (units, anchor), then its doors on the wall facing `dir`
    local nxt = pickFrom(G.targets, function(t) return t.kind ~= "door" and inRoom(t, R) end)
    if not nxt then nxt = pickFrom(G.targets, function(t) return t.kind == "door" and inRoom(t, R) and doorOnWall(t, roomR, dir) end) end
    local side = R
    if not nxt and cur.kind == "door" then
        -- 2. through the door into the other room (its units first, then its far doors)
        local other = (cur.r1 == R) and cur.r2 or cur.r1
        if other and other >= 0 then
            local roomO = roomHit(other, shipId)
            nxt = pickFrom(G.targets, function(t) return t.kind ~= "door" and inRoom(t, other) end)
            if not nxt then nxt = pickFrom(G.targets, function(t) return t.kind == "door" and inRoom(t, other) and doorOnWall(t, roomO, dir) end) end
            if not nxt then
                local best, bestD = nil, math.huge
                for _, t in ipairs(G.targets) do
                    if t.kind ~= "door" and t.roomId == other then
                        local d = (t.x - cur.x) ^ 2 + (t.y - cur.y) ^ 2
                        if d < bestD then best, bestD = t, d end
                    end
                end
                nxt = best
            end
            side = other
        end
    end
    if not nxt and roomR then
        -- 3. no door on that wall: move to the next room in that direction (same row/column
        --    preferred, like room mode) and land on its unit nearest to where we were
        local rooms = {}
        for _, h in ipairs(G.hits) do if h.kind == "room" and h.extra == shipId then rooms[#rooms + 1] = h end end
        local nextRoom = N.pick(roomR, rooms, dir)
        if nextRoom then
            local best, bestD = nil, math.huge
            for _, t in ipairs(G.targets) do
                if t.kind ~= "door" and t.roomId == nextRoom.id then
                    local d = (t.x - cur.x) ^ 2 + (t.y - cur.y) ^ 2 - (t.kind == "crew" and 1e6 or 0)
                    if d < bestD then best, bestD = t, d end
                end
            end
            nxt = best
            side = nextRoom.id
        end
    end
    if nxt then
        if nxt.kind == "door" then nxt.roomSide = inRoom(nxt, side) and side or nxt.r1 end
        G.target = nxt
        C.moveTo(E.center(nxt))
        E.feedback.tick()
        return true
    end
    return false
end

-- ---- panels -----------------------------------------------------------------
local function firstHit(panel, hits)
    local pref = PREFERRED[panel]
    local cands = {}
    for _, h in ipairs(hits) do if not pref or h.kind == pref then cands[#cands + 1] = h end end
    if #cands == 0 then cands = hits end
    if panel == "ship" or panel == "enemy" then return N.nearest(C.x, C.y, cands) end
    table.sort(cands, function(a, b) if math.abs(a.y - b.y) > 20 then return a.y < b.y end return a.x < b.x end)
    return cands[1]
end

local function setPanel(panel, keepCursor)
    if G.panel ~= panel then
        G.panel = panel
        leaveDetail()
    end
    G.panelHits = collect(panel)
    if not keepCursor or not C.focus or not N.refresh(C.focus, G.panelHits) then
        C.mode = "snap"
        C.snapTo(firstHit(panel, G.panelHits))
    end
end

local function cyclePanel(dir)
    local idx = 1
    for i, p in ipairs(PANEL_ORDER) do if p == G.panel then idx = i end end
    for _ = 1, #PANEL_ORDER do
        idx = idx + dir
        if idx < 1 then idx = #PANEL_ORDER elseif idx > #PANEL_ORDER then idx = 1 end
        if panelAvailable(PANEL_ORDER[idx]) then
            setPanel(PANEL_ORDER[idx])
            E.feedback.tick()
            return
        end
    end
end

-- cross into the neighbouring panel in that direction, landing nearest to the cursor
local function transition(dir)
    local nb = NEIGHBOR[G.panel] and NEIGHBOR[G.panel][dir]
    if G.panel == "power" and C.focus then
        -- only the cluster facing the weapons crosses over to them
        if (dir == "right" and C.focus.x >= 640) or (dir == "left" and C.focus.x < 640) then nb = nil end
    end
    if nb == "enemy" and not panelAvailable("enemy") then nb = nil end
    if not nb or not panelAvailable(nb) then return false end
    G.panel = nb
    leaveDetail()
    G.panelHits = collect(nb)
    C.mode = "snap"
    -- land on the element that continues the movement, else the nearest one
    local from = { x = C.x - 1, y = C.y - 1, w = 2, h = 2, kind = "_cursor", id = -1 }
    C.snapTo(N.pick(from, G.panelHits, dir) or N.nearest(C.x, C.y, G.panelHits))
    E.feedback.tick()
    return true
end

local function hotkey(name, fallback) C.key(E.hotkey(name, fallback)) end

local function systemHotkeys(sysId)
    if sysId == SYS.cloaking then return "activate_cloak", nil
    elseif sysId == SYS.teleporter then return "send_tele", "ret_tele"
    elseif sysId == SYS.hacking then return "start_hacking", nil
    elseif sysId == SYS.mind then return "mindControl", nil
    elseif sysId == SYS.battery then return "activate_battery", nil
    elseif sysId == SYS.doors then return "open", "close" end
    return nil, nil
end

local function shipIdOfPanel() return G.panel == "enemy" and 1 or 0 end

function G.update()
    I, C, N = E.input, E.cursor, E.nav
    G.hits = Ensign.hitboxes()
    local targeting = detectTargeting()
    local targetingChanged = targeting ~= G.targeting
    G.targeting = targeting
    if targetingChanged then G.beamStage = 0 end

    if targeting == "weapon" or targeting == "beam" or targeting == "hack" or targeting == "mind" or targeting == "teleport" then
        if targetingChanged and panelAvailable("enemy") then setPanel("enemy") end
        if targeting ~= "teleport" and G.panel ~= "enemy" and panelAvailable("enemy") then setPanel("enemy") end
    elseif targeting == "bomb" then
        if targetingChanged then setPanel(panelAvailable("enemy") and "enemy" or "ship") end
    elseif targetingChanged and G.lastPanel then
        setPanel(G.lastPanel)
    end
    if not targeting then G.lastPanel = G.panel end

    if not panelAvailable(G.panel) and panelAvailable("ship") then setPanel("ship") end
    G.panelHits = collect(G.panel)

    if G.detail then
        G.targets = buildTargets(shipIdOfPanel())
        G.target = refreshTarget(G.target, G.targets)
        if not G.target then leaveDetail() end
    end
    if G.detail then
        local r = roomHit(targetRoom(G.target), shipIdOfPanel())
        C.focus = r or C.focus
        C.x, C.y = E.center(G.target)   -- keep the pointer on the target without re-snapping
        C.sync()
    else
        C.focus = N.refresh(C.focus, G.panelHits) or (C.mode == "snap" and firstHit(G.panel, G.panelHits) or nil)
        if C.mode == "snap" and C.focus and not E.sameHit(C.focus, G.prevFocus) then C.snapTo(C.focus) end
    end
    G.prevFocus = C.focus
    local focus = C.focus

    if G.restore and E.frame >= G.restore.at then restoreSelection(G.restore.keep); G.restore = nil end

    -- release a held drag button
    if G.drag == "select" and I.released("select") then C.release(1); G.drag = nil end
    if G.drag == "alt" and I.released("alt") then C.release(3); G.drag = nil end

    if I.pressed("panel_prev") then cyclePanel(-1) end
    if I.pressed("panel_next") then cyclePanel(1) end
    if I.pressed("focus_toggle") then
        if G.panel == "enemy" then setPanel("ship") elseif panelAvailable("enemy") then setPanel("enemy") end
    end

    if C.updateFree() then leaveDetail() end

    local dir = I.navDirection()
    if dir then
        if G.detail then
            if not detailNav(dir, shipIdOfPanel()) then transition(dir) end
        elseif G.targeting == "beam" and G.beamStage == 1 then
            local step = 17
            local dx = (dir == "left" and -step) or (dir == "right" and step) or 0
            local dy = (dir == "up" and -step) or (dir == "down" and step) or 0
            C.mode = "free"
            C.moveTo(C.x + dx, C.y + dy)
        else
            local from = focus or { x = C.x - 1, y = C.y - 1, w = 2, h = 2, kind = "_cursor", id = -1 }
            -- the power panel has two clusters (systems left, subsystems right) with the
            -- weapons in between: stay inside the cluster, transitions bridge the gap
            local filter = nil
            if G.panel == "power" and focus then
                local leftSide = focus.x < 640
                filter = function(h) return (h.x < 640) == leftSide end
            end
            local nxt = N.pick(from, G.panelHits, dir, filter)
            if nxt then
                C.mode = "snap"
                C.snapTo(nxt)
                E.feedback.tick()
            else
                transition(dir)
            end
        end
    end

    -- select
    if I.pressed("select") or I.pressed("cursor_click") then
        if G.detail and G.target then
            local t = G.target
            if t.kind == "crew" then
                toggleSelect(t.crew)
                E.feedback.pulse("select")
            elseif t.kind == "door" then
                C.moveTo(E.center(t))
                C.click(1)
                G.restore = { keep = rememberSelection(), at = E.frame + 3 }
                E.feedback.pulse("select")
            end
        elseif G.targeting == "beam" then
            C.click(1)
            G.beamStage = G.beamStage == 0 and 1 or 0
            if G.beamStage == 1 then C.mode = "free" end
        elseif focus and focus.kind == "room" and selectedCrewCount() > 0 and not G.targeting then
            C.click(3)                  -- FTL issues move orders with the right button
            E.feedback.pulse("select")
        elseif focus and focus.kind == "room" and not G.targeting then
            if not enterDetail(focus, shipIdOfPanel()) then C.click(1) end
        elseif focus and DRAG_LEFT[focus.kind] and I.pressed("select") then
            C.press(1)                  -- hold to drag a slot, tap to arm
            G.drag = "select"
        else
            C.click(1)
        end
    end
    -- alt / right button
    if I.pressed("alt") or I.pressed("cursor_rclick") then
        if focus and DRAG_RIGHT[focus.kind] and I.pressed("alt") then
            C.press(3)
            G.drag = "alt"
        elseif focus and focus.kind == "sysbox" and focus.id == SYS.teleporter then
            hotkey("ret_tele", nil)
        elseif focus and focus.kind == "sysbox" and focus.id == SYS.doors then
            hotkey("close", 120)
        else
            C.click(3)
        end
    end
    -- back
    if I.pressed("back") then
        if G.detail then
            local r = roomHit(targetRoom(G.target), shipIdOfPanel())
            leaveDetail()
            if r then C.snapTo(r) elseif focus then C.snapTo(focus) end
        elseif G.targeting then
            C.click(3)
        elseif G.panel ~= "ship" then
            setPanel("ship")
        elseif selectedCrewCount() > 0 then
            clearSelection()
        end
    end
    -- info / Y: special systems, autofire
    if I.pressed("info") then
        if focus and focus.kind == "sysbox" then
            local primary = systemHotkeys(focus.id)
            if primary then hotkey(primary, nil) end
        elseif G.panel == "weapons" then
            hotkey("autofire", 118)
        end
    end
    if I.pressed("power_up") and (G.panel == "power" or G.panel == "weapons") then
        if focus then C.snapTo(focus) end
        C.click(1)
    end
    if I.pressed("power_down") and (G.panel == "power" or G.panel == "weapons") then
        if focus then C.snapTo(focus) end
        C.click(3)
    end
    if I.pressed("pause") then hotkey("pause", E.KEY.SPACE) end
    if I.pressed("game_menu") then C.key(E.KEY.ESC) end
    if I.pressed("jump") then hotkey("jump", 106) end
    if I.pressed("autofire") then hotkey("autofire", 118) end
    if I.pressed("crew_all") then hotkey("crew_all", 113) end
    if I.pressed("doors_open") then hotkey("open", 122) end
    if I.pressed("doors_close") then hotkey("close", 120) end
    if I.pressed("saved_positions") then hotkey("loadPositions", nil) end
    if I.pressed("return_positions") then hotkey("savePositions", nil) end

    -- hints
    local nsel = selectedCrewCount()
    local hint = { { "nav_up", "Move" } }
    if G.detail then
        local t = G.target
        if t and t.kind == "crew" then
            hint[#hint + 1] = { "select", (t.crew.selectionState == 1) and "Deselect" or "Select" }
        elseif t and t.kind == "door" then
            hint[#hint + 1] = { "select", "Open / close" }
        end
        hint[#hint + 1] = { "back", nsel > 0 and "Rooms (send)" or "Rooms" }
    elseif G.targeting == "beam" then
        hint[#hint + 1] = { "select", G.beamStage == 0 and "Beam start" or "Beam end" }
        hint[#hint + 1] = { "back", "Cancel" }
    elseif G.targeting then
        hint[#hint + 1] = { "select", "Target" }
        hint[#hint + 1] = { "back", "Cancel" }
        if G.targeting == "bomb" or G.targeting == "teleport" then hint[#hint + 1] = { "focus_toggle", "Other ship" } end
    elseif G.panel == "ship" or G.panel == "enemy" then
        hint[#hint + 1] = { "select", nsel > 0 and ("Send " .. nsel) or "Units & doors" }
        if nsel > 0 then hint[#hint + 1] = { "back", "Deselect all" } end
        hint[#hint + 1] = { "panel_next", "Panel" }
    elseif G.panel == "power" then
        hint[#hint + 1] = { "power_up", "Power +" }; hint[#hint + 1] = { "power_down", "Power -" }
        if focus and systemHotkeys(focus.id) then hint[#hint + 1] = { "info", "Activate" } end
        hint[#hint + 1] = { "panel_next", "Panel" }
    elseif G.panel == "weapons" then
        hint[#hint + 1] = { "select", "Arm / deploy (hold: move)" }
        hint[#hint + 1] = { "alt", "Depower" }
        hint[#hint + 1] = { "info", "Autofire" }
        hint[#hint + 1] = { "panel_next", "Panel" }
    elseif G.panel == "crew" then
        hint[#hint + 1] = { "select", "Select" }; hint[#hint + 1] = { "alt", "Hold: reorder" }
        hint[#hint + 1] = { "panel_next", "Panel" }
    else
        hint[#hint + 1] = { "select", "Select" }; hint[#hint + 1] = { "panel_next", "Panel" }
    end
    hint[#hint + 1] = { "pause", "Pause" }
    G.hint = hint
end

function G.render()
    if G.detail and G.target then
        C.drawFrame(G.target, nil, 2)
        if C.focus then C.drawFrame(C.focus, Graphics.GL_Color(1, 1, 1, 0.35), 3) end
    elseif C.mode == "snap" and C.focus then
        C.drawFrame(C.focus)
    end
end

function G.panelLabel() return PANEL_LABEL[G.panel] or "" end
function G.setPanel(name) I, C, N = E.input, E.cursor, E.nav; leaveDetail(); setPanel(name) end
