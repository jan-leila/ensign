-- 50_game.lua: in-flight controls.
--
-- Groups (the bumpers rotate them; group_crew / group_systems / group_weapons /
-- group_drones / group_ship / group_enemy jump directly):
--   crew     the crew portraits on the left
--   systems  the reactor's system boxes (power)
--   weapons  weapon slots (empty ones skipped) + autofire; only with a weapon system
--   drones   drone slots (empty ones skipped); only with a drone system
--   ship     room mode over your rooms; detail mode underneath walks units and doors
--   enemy    the enemy's rooms (joins the rotation when a target is present; forced
--            while a weapon / power is aimed)
--   top      FTL / ship / options buttons (reached with the d-pad above the ship)
--
-- Buttons in flight:
--   A  room: open detail (or send the selected units there)   detail: toggle unit / door
--      system box: power +      slot: toggle      crew portrait: select (adds)
--   B  detail: back to rooms    rooms: deselect all    system box: power -    slot: turn off
--   X  room: open detail (even with units selected)   system box: turn off   slot: re-target
--   Y  FTL jump    Start: ship screens    View: inventory    d-pad: move, crossing group edges
-- With the cursor pointed freely (touchpad / right stick) A over a room still sends the
-- selected units there, or opens that room's detail mode when nothing is selected.
local E = ENSIGN
local G = {}
E.game = G
local I, C, N

G.panel = "ship"
G.hits = {}
G.panelHits = {}
G.detail = false
G.target = nil
G.targets = {}
G.drag = nil
G.targeting = nil
G.beamStage = 0
G.hint = {}
G.lastPanel = nil
G.prevFocus = nil
G.restore = nil

local PANEL_ORDER = { "crew", "systems", "weapons", "drones", "ship", "enemy" }
local PANEL_LABEL = { ship = "YOUR SHIP", enemy = "ENEMY SHIP", systems = "POWER", weapons = "WEAPONS",
                      drones = "DRONES", crew = "CREW", top = "CONTROLS" }
local PREFERRED = { ship = "room", enemy = "room", systems = "sysbox", weapons = "armament", drones = "armament",
                    crew = "crewbox", top = "ftl" }
local SYS = { shields = 0, engines = 1, oxygen = 2, weapons = 3, drones = 4, medbay = 5, pilot = 6,
              sensors = 7, doors = 8, teleporter = 9, cloaking = 10, artillery = 11, battery = 12,
              clonebay = 13, mind = 14, hacking = 15 }
-- screen layout: moving past the edge of a group crosses into its neighbour
-- (a list = whichever of those groups has the nearest target in that direction)
local NEIGHBOR = {
    ship    = { down = { "weapons", "drones", "systems" }, up = "top", left = "crew", right = "enemy" },
    enemy   = { left = "ship", down = { "weapons", "drones", "systems" }, up = "top" },
    systems = { up = "ship", left = { "drones", "crew" }, right = { "weapons", "drones" } },
    weapons = { up = "ship", left = { "systems", "drones" } },
    drones  = { up = "ship", right = { "systems", "weapons" }, down = "systems" },
    crew    = { right = "ship", down = { "drones", "systems" }, up = "top" },
    top     = { down = "ship" },
}



local function hasSystem(id)
    local ok, v = pcall(function() return E.playerShip():HasSystem(id) end)
    return ok and v or false
end

local function kindFilter(panel)
    if panel == "ship" then return function(h) return h.kind == "room" and h.extra == 0 end
    elseif panel == "enemy" then return function(h) return h.kind == "room" and h.extra == 1 end
    elseif panel == "systems" then return function(h) return h.kind == "sysbox" end
    elseif panel == "weapons" then
        local w = hasSystem(SYS.weapons)
        return function(h)
            if not w then return false end
            if h.kind == "autofire" then return true end
            return h.kind == "armament" and h.extra == 3 and h.label ~= ""   -- empty slots are skipped
        end
    elseif panel == "drones" then
        local d = hasSystem(SYS.drones)
        return function(h) return d and h.kind == "armament" and h.extra == 4 and h.label ~= "" end
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
    pcall(function() crew.selectionState = (crew.selectionState == 1) and 0 or 1 end)
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
    local function addList(list, airlock)
        for i = 0, list:size() - 1 do
            local d = list[i]
            if d then
                local w = d.bVertical and 10 or 35
                local h = d.bVertical and 35 or 10
                -- airlocks all report door id -1, so they are keyed by list position instead
                out[#out + 1] = { kind = "door", id = airlock and (1000 + i) or d.iDoorId, x = ox + d.x - w / 2, y = oy + d.y - h / 2, w = w, h = h,
                                  label = d.iRoom1 .. "," .. d.iRoom2, extra = d.bOpen and 1 or 0, r1 = d.iRoom1, r2 = d.iRoom2,
                                  door = d, airlock = airlock }
            end
        end
    end
    pcall(function() addList(ship.ship.vDoorList, false) end)
    pcall(function() addList(ship.ship.vOuterAirlocks, true) end)   -- hull doors live in their own list
    return out
end

-- units, doors and (for empty rooms) the room itself, for the ship of the current group
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
            out[#out + 1] = { kind = "anchor", id = h.id, x = h.x, y = h.y, w = h.w, h = h.h, roomId = h.id }   -- the whole room
        end
    end
    if shipId == 0 then
        for _, d in ipairs(G.allDoors()) do out[#out + 1] = d end
    end
    return out
end

local function sameTarget(a, b) return a and b and a.kind == b.kind and a.id == b.id end
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
    if not cur then return false end
    local R = targetRoom(cur)
    local function pickFrom(list, extra, loose)
        local cands = {}
        for _, t in ipairs(list) do if not sameTarget(t, cur) and (not extra or extra(t)) then cands[#cands + 1] = t end end
        return N.pick(cur, cands, dir, nil, not loose)   -- strict cone: only what is really in that direction
    end
    local roomR = roomHit(R, shipId)
    -- 1. inside the current room (units, anchor), then its doors: from a unit only the
    --    door on the wall facing `dir`; from a door any door of the room in that direction
    local nxt = pickFrom(G.targets, function(t) return t.kind ~= "door" and inRoom(t, R) end)
    -- (a door on the facing wall counts wherever it sits along that wall: airlocks included)
    if not nxt then nxt = pickFrom(G.targets, function(t) return t.kind == "door" and inRoom(t, R) and (cur.kind == "door" or doorOnWall(t, roomR, dir)) end, cur.kind ~= "door") end
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
        -- 3. no door on that wall: move to the next room in that direction and land on
        --    its unit nearest to where we were
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

-- ---- groups -----------------------------------------------------------------
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
    if G.panel == "top" then for i, p in ipairs(PANEL_ORDER) do if p == "ship" then idx = i end end end
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

local function panelOf(h)   -- the group whose filter accepts this hit
    for _, p in ipairs(PANEL_ORDER) do if kindFilter(p)(h) then return p end end
    if kindFilter("top")(h) then return "top" end
    return nil
end

-- cross into the neighbouring group in that direction, landing in the direction of travel
-- (when several groups border this edge, the one with the nearest target wins)
local function transition(dir)
    local nb = NEIGHBOR[G.panel] and NEIGHBOR[G.panel][dir]
    if G.panel == "systems" and dir == "up" and C.focus and C.focus.x < 250 then nb = "crew" end
    if not nb then return false end
    local hits = {}
    for _, p in ipairs(type(nb) == "table" and nb or { nb }) do
        for _, h in ipairs(collect(p)) do hits[#hits + 1] = h end
    end
    if #hits == 0 then return false end
    local from = { x = C.x - 1, y = C.y - 1, w = 2, h = 2, kind = "_cursor", id = -1 }
    local target = N.pick(from, hits, dir) or N.nearest(C.x, C.y, hits)
    G.panel = panelOf(target) or (type(nb) == "table" and nb[1] or nb)
    leaveDetail()
    G.panelHits = collect(G.panel)
    C.mode = "snap"
    C.snapTo(target)
    E.feedback.tick()
    return true
end

local function hotkey(name, fallback) C.key(E.hotkey(name, fallback)) end

local function systemPower(sysId)
    local ok, p = pcall(function() return E.playerShip():GetSystem(sysId).powerState.first end)
    return ok and p or 0
end
local function slotPowered(h)
    local ok, v = pcall(function()
        local ship = E.playerShip()
        if h.extra == 3 then return ship.weaponSystem.weapons[h.id].powered end
        return ship.droneSystem.drones[h.id].powered
    end)
    return ok and v or false
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
        C.x, C.y = E.center(G.target)
        C.sync()
    else
        C.focus = N.refresh(C.focus, G.panelHits) or (C.mode == "snap" and firstHit(G.panel, G.panelHits) or nil)
        if C.mode == "snap" and C.focus and not E.sameHit(C.focus, G.prevFocus) then C.snapTo(C.focus) end
    end
    G.prevFocus = C.focus
    local focus = C.focus
    local onShip = (G.panel == "ship" or G.panel == "enemy") and not G.targeting

    if G.restore and E.frame >= G.restore.at then restoreSelection(G.restore.keep); G.restore = nil end
    if G.drag == "select" and I.released("slot_toggle") then C.release(1); G.drag = nil end
    if G.drag == "alt" and I.released("crew_reorder") then C.release(3); G.drag = nil end

    -- groups
    if I.pressed("group_prev") then cyclePanel(-1) end
    if I.pressed("group_next") then cyclePanel(1) end
    if I.pressed("group_crew") and panelAvailable("crew") then setPanel("crew") end
    if I.pressed("group_systems") and panelAvailable("systems") then setPanel("systems") end
    if I.pressed("group_weapons") and panelAvailable("weapons") then setPanel("weapons") end
    if I.pressed("group_drones") and panelAvailable("drones") then setPanel("drones") end
    if I.pressed("group_ship") and panelAvailable("ship") then setPanel("ship") end
    if I.pressed("group_enemy") then
        if G.panel == "enemy" then setPanel("ship") elseif panelAvailable("enemy") then setPanel("enemy") end
    end

    if C.updateFree() then leaveDetail() end

    -- d-pad
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
            local cands = G.panelHits
            if G.panel == "crew" and (dir == "left" or dir == "right") then cands = N.filterKind(cands, { crewbox = true }) end
            local nxt = N.pick(from, cands, dir)
            if nxt then
                C.mode = "snap"
                C.snapTo(nxt)
                E.feedback.tick()
            else
                transition(dir)
            end
        end
    end

    -- state-specific verbs (each is its own Steam action; several share a button by default)
    local sysFocus = G.panel == "systems" and focus and focus.kind == "sysbox"
    local slotFocus = (G.panel == "weapons" or G.panel == "drones") and focus and focus.kind == "armament"
    -- free cursor (touchpad / stick): the room under the pointer still takes the room verbs
    local roomUnder = nil
    if not focus and not G.detail and not G.targeting then
        for _, h in ipairs(G.hits) do if h.kind == "room" and E.contains(h, C.x, C.y) then roomUnder = h end end
    end
    local function openRoom(room, shipId)
        if not enterDetail(room, shipId) then C.snapTo(room); C.click(1) end
    end
    if G.detail and G.target then
        local t = G.target
        if t.kind == "crew" and I.pressed("detail_toggle_unit") then
            toggleSelect(t.crew)
            E.feedback.pulse("select")
        elseif t.kind == "door" and I.pressed("detail_toggle_door") then
            C.moveTo(E.center(t))
            C.click(1)
            G.restore = { keep = rememberSelection(), at = E.frame + 3 }
            E.feedback.pulse("select")
        end
        if I.pressed("detail_back") then
            local r = roomHit(targetRoom(t), shipIdOfPanel())
            leaveDetail()
            if r then C.snapTo(r) elseif focus then C.snapTo(focus) end
        end
    elseif G.targeting == "beam" then
        if I.pressed("beam_point") then
            C.click(1)
            G.beamStage = G.beamStage == 0 and 1 or 0
            if G.beamStage == 1 then C.mode = "free" end
        end
        if I.pressed("target_cancel") then C.click(3) end
    elseif G.targeting then
        if I.pressed("target_confirm") then C.click(1) end
        if I.pressed("target_cancel") then C.click(3) end
    elseif onShip and focus and focus.kind == "room" then
        if selectedCrewCount() > 0 then
            if I.pressed("room_send") then C.click(3); E.feedback.pulse("select") end      -- FTL: right button sends
            if I.pressed("room_deselect_all") then clearSelection() end
        elseif I.pressed("room_open") then openRoom(focus, shipIdOfPanel()) end
        if I.pressed("room_detail") then enterDetail(focus, shipIdOfPanel()) end
    elseif roomUnder then
        local shipId = roomUnder.extra
        if selectedCrewCount() > 0 then
            if I.pressed("room_send") then C.click(3); E.feedback.pulse("select") end
            if I.pressed("room_deselect_all") then clearSelection() end
        elseif I.pressed("room_open") then setPanel(shipId == 1 and "enemy" or "ship", true); openRoom(roomUnder, shipId) end
        if I.pressed("room_detail") then setPanel(shipId == 1 and "enemy" or "ship", true); enterDetail(roomUnder, shipId) end
    elseif sysFocus then
        if I.pressed("system_power_up") then C.snapTo(focus); C.click(1) end
        if I.pressed("system_power_down") then C.snapTo(focus); C.click(3) end
        if I.pressed("system_off") then
            C.snapTo(focus)
            for _ = 1, systemPower(focus.id) do C.click(3) end   -- remove every bar
        end
    elseif slotFocus then
        if I.pressed("slot_toggle") then C.press(1); G.drag = "select" end   -- tap: toggle; hold: move
        if I.pressed("slot_off") then C.snapTo(focus); C.click(3) end
        if I.pressed("slot_retarget") then
            C.snapTo(focus)
            if not slotPowered(focus) then C.click(1) end       -- power it first
            C.click(1)                                          -- then arm / re-target
        end
    elseif G.panel == "crew" and focus and focus.kind == "crewbox" then
        if I.pressed("crew_select") then C.click(1, { shift = selectedCrewCount() > 0 }) end
        if I.pressed("crew_deselect_all") then clearSelection() end
        if I.pressed("crew_reorder") then C.press(3); G.drag = "alt" end
    else
        if I.pressed("ui_select") then C.click(1) end
    end
    if I.pressed("cursor_click") then C.click(1) end
    if I.pressed("cursor_rclick") then C.click(3) end
    -- deselecting works from any group while units are selected
    if not G.detail and not G.targeting and selectedCrewCount() > 0 and not (onShip and focus and focus.kind == "room")
       and (I.pressed("room_deselect_all") or I.pressed("crew_deselect_all")) and G.panel ~= "crew" then
        clearSelection()
    end
    -- global
    if I.pressed("jump") then hotkey("jump", 106) end
    if I.pressed("pause") then hotkey("pause", E.KEY.SPACE) end
    if I.pressed("ship_screens") then hotkey("ship_info", 117) end   -- systems / crew / inventory
    if I.pressed("ship_inventory") then hotkey("ship_inv", 105) end    -- straight to the inventory tab
    if I.pressed("escape_menu") then C.key(E.KEY.ESC) end
    if I.pressed("autofire") then hotkey("autofire", 118) end
    if I.pressed("crew_all") then hotkey("crew_all", 113) end
    if I.pressed("doors_open") then hotkey("open", 122) end
    if I.pressed("doors_close") then hotkey("close", 120) end
    if I.pressed("saved_positions") then hotkey("loadPositions", nil) end
    if I.pressed("return_positions") then hotkey("savePositions", nil) end

    -- hints (named by the verb that applies, so the glyph follows the user's binding)
    local nsel = selectedCrewCount()
    local hint = { { "nav_up", "Move cursor" } }
    if G.detail then
        local t = G.target
        if t and t.kind == "crew" then
            hint[#hint + 1] = { "detail_toggle_unit", (t.crew.selectionState == 1) and "Deselect unit" or "Select unit" }
        elseif t and t.kind == "door" then
            hint[#hint + 1] = { "detail_toggle_door", (t.extra == 1) and "Close door" or "Open door" }
        end
        hint[#hint + 1] = { "detail_back", "Back to rooms" }
    elseif G.targeting == "beam" then
        hint[#hint + 1] = { "beam_point", G.beamStage == 0 and "Beam start" or "Beam end" }
        hint[#hint + 1] = { "target_cancel", "Cancel aim" }
    elseif G.targeting then
        hint[#hint + 1] = { "target_confirm", "Aim at room" }
        hint[#hint + 1] = { "target_cancel", "Cancel aim" }
        if G.targeting == "bomb" or G.targeting == "teleport" then hint[#hint + 1] = { "group_enemy", "Other ship" } end
    elseif (G.panel == "ship" or G.panel == "enemy") or roomUnder then
        if nsel > 0 then
            hint[#hint + 1] = { "room_send", "Send " .. nsel .. " here" }; hint[#hint + 1] = { "room_detail", "Pick more units" }; hint[#hint + 1] = { "room_deselect_all", "Deselect all" }
        else
            hint[#hint + 1] = { "room_open", "Units & doors" }
        end
    elseif sysFocus then
        hint[#hint + 1] = { "system_power_up", "Power +" }; hint[#hint + 1] = { "system_power_down", "Power -" }; hint[#hint + 1] = { "system_off", "Unpower" }
    elseif slotFocus then
        hint[#hint + 1] = { "slot_toggle", "On / off (hold to move)" }; hint[#hint + 1] = { "slot_off", "Turn off" }; hint[#hint + 1] = { "slot_retarget", "Re-aim" }
    elseif G.panel == "crew" then
        hint[#hint + 1] = { "crew_select", nsel > 0 and "Add to selection" or "Select unit" }; hint[#hint + 1] = { "crew_reorder", "Hold to reorder" }
        if nsel > 0 then hint[#hint + 1] = { "crew_deselect_all", "Deselect all" } end
    else
        hint[#hint + 1] = { "ui_select", "Select" }
    end
    hint[#hint + 1] = { "jump", "FTL jump" }
    hint[#hint + 1] = { "group_next", "Next group" }
    G.hint = hint
end

function G.render()
    if G.detail and G.target and G.target.kind == "anchor" then
        C.drawFrame(G.target)              -- an empty room looks exactly like room mode
    elseif G.detail and G.target then
        C.drawFrame(G.target, nil, 2)
        if C.focus then C.drawFrame(C.focus, Graphics.GL_Color(1, 1, 1, 0.35), 3) end
    elseif C.mode == "snap" and C.focus then
        C.drawFrame(C.focus)
    end
end

function G.panelLabel() return PANEL_LABEL[G.panel] or "" end
function G.setPanel(name) I, C, N = E.input, E.cursor, E.nav; leaveDetail(); setPanel(name) end -- luacheck: ignore
