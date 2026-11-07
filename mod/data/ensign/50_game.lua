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
--      system box: power +      slot: power on, then aim      crew portrait: select (adds)
--   B  detail: back to rooms    rooms: deselect all    system box: power -    slot: cancel aim, then power off
--   X  room: open detail (even with units selected)   system box: turn off   slot: power + aim in one go
--      cloak / battery: fire   hacking / mind control: arm (A on the room targets)   teleporter: send, again: return
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

local PANEL_ORDER = { "crew", "systems", "weapons", "drones", "subsystems", "ship", "enemy" }
local PANEL_LABEL = { ship = "YOUR SHIP", enemy = "ENEMY SHIP", systems = "POWER", weapons = "WEAPONS",
                      drones = "DRONES", subsystems = "SUBSYSTEMS", crew = "CREW", top = "CONTROLS" }
local PREFERRED = { ship = "room", enemy = "room", systems = "sysbox", weapons = "armament", drones = "armament",
                    subsystems = "sysbox", crew = "crewbox", top = "ftl" }
local SYS = { shields = 0, engines = 1, oxygen = 2, weapons = 3, drones = 4, medbay = 5, pilot = 6,
              sensors = 7, doors = 8, teleporter = 9, cloaking = 10, artillery = 11, battery = 12,
              clonebay = 13, mind = 14, hacking = 15 }
-- the subsystem row (piloting, sensors, doors, backup battery) sits at the far right of
-- the bottom bar and is its own group
local SUBSYSTEM = { [SYS.pilot] = true, [SYS.sensors] = true, [SYS.doors] = true, [SYS.battery] = true }
-- screen layout: moving past the edge of a group crosses into its neighbour
-- (a list = whichever of those groups has the nearest target in that direction).
-- Bottom bar, left to right: systems, weapons, drones, subsystems.
local NEIGHBOR = {
    ship       = { down = { "systems", "weapons", "drones", "subsystems" }, up = "top", left = "crew", right = "enemy" },
    enemy      = { left = "ship", down = { "subsystems", "drones", "weapons", "systems" }, up = "top" },
    systems    = { up = "ship", left = "crew", right = { "weapons", "drones", "subsystems" } },
    weapons    = { up = "ship", left = "systems", right = { "drones", "subsystems" } },
    drones     = { up = "ship", left = { "weapons", "systems" }, right = "subsystems" },
    subsystems = { up = { "enemy", "ship" }, left = { "drones", "weapons", "systems" } },
    crew       = { right = "ship", down = "systems", up = "top" },
    top        = { down = "ship" },
}



local function hasSystem(id)
    local ok, v = pcall(function() return E.playerShip():HasSystem(id) end)
    return ok and v or false
end

local function kindFilter(panel)
    if panel == "ship" then return function(h) return h.kind == "room" and h.extra == 0 end
    elseif panel == "enemy" then return function(h) return h.kind == "room" and h.extra == 1 end
    elseif panel == "systems" then return function(h) return h.kind == "sysbox" and not SUBSYSTEM[h.id] end
    elseif panel == "subsystems" then return function(h) return h.kind == "sysbox" and SUBSYSTEM[h.id] == true end
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
    local tele, hack, mind = Ensign.specialArmed()
    if tele and tele ~= 0 then return "teleport" end
    if hack then return "hack" end
    if mind and mind ~= 0 then return "mind" end
    local okm, m = pcall(function() return Hyperspace.Mouse end)
    if okm and m then
        if m.iTeleporting and m.iTeleporting ~= 0 then return "teleport" end
        if m.iHacking and m.iHacking ~= 0 then return "hack" end
        if m.iMindControlling and m.iMindControlling ~= 0 then return "mind" end
    end
    return nil
end

-- special systems: cloak / battery fire at once; hacking, mind control and the
-- teleporter arm and then take a room (teleporter: send, press again for return)
local SPECIAL = { [9] = "teleporter", [10] = "cloaking", [12] = "battery", [14] = "mind", [15] = "hacking" }
-- off -> send -> return -> off, skipping what the game refuses (nobody in the teleporter
-- room, nobody to bring back, not enough charge)
local function cycleTeleporter(cur)
    if cur == 0 then return Ensign.armTeleporter(1) or Ensign.armTeleporter(2)
    elseif cur == 1 then return Ensign.armTeleporter(2) or Ensign.armTeleporter(0)
    else return Ensign.armTeleporter(0) end
end
local function useSystem(sysId)
    local tele, hack, mind = Ensign.specialArmed()
    if sysId == 10 then return Ensign.cloak()
    elseif sysId == 12 then return Ensign.battery()
    elseif sysId == 15 then return Ensign.armHacking(not hack)
    elseif sysId == 14 then return Ensign.armMind(not (mind and mind ~= 0))
    elseif sysId == 9 then return cycleTeleporter(tele or 0) end
    return false
end
local function cancelSpecial(mode)
    if mode == "teleport" then return Ensign.armTeleporter(0)
    elseif mode == "hack" then return Ensign.armHacking(false)
    elseif mode == "mind" then return Ensign.armMind(false) end
    return false
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
                                  door = d, airlock = airlock, index = i }
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

-- d-pad in detail mode: same room first, then the door on that wall; stepping out of the
-- room (through a door or straight into the next room) returns to room mode there
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
        if side ~= R then
            -- leaving the room: back to room mode, on the room we arrive in
            local r = roomHit(side, shipId)
            if r then
                leaveDetail()
                C.mode = "snap"
                C.snapTo(r)
                E.feedback.tick()
                return true
            end
        end
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
-- ---- direct game logic (native/src/logic.cpp); every call falls back to the screen path
local function sendSelected(room)
    local sent, ok = 0, false
    pcall(function()
        local list = E.playerShip().vCrewList
        for i = 0, list:size() - 1 do
            local c = list[i]
            if c and c.selectionState == 1 and not c.bDead then
                sent = sent + 1
                local moved = Ensign.moveCrew(i, room.id)
                if E.dev.active then E.log("moveCrew " .. i .. " -> room " .. room.id .. ": " .. tostring(moved)) end
                if moved then ok = true end
            end
        end
    end)
    if sent > 0 and not ok then C.snapTo(room); C.click(3) end   -- the game's own right click
    return sent > 0
end
local function slotPowerSet(h, on)
    if h.extra == 3 then return Ensign.weaponPower(h.id, on) end
    return Ensign.dronePower(h.id, on)
end

local function slotPowered(h)
    local ok, v = pcall(function()
        local ship = E.playerShip()
        if h.extra == 3 then return ship.weaponSystem.weapons[h.id].powered end
        return ship.droneSystem.drones[h.id].powered
    end)
    return ok and v or false
end
-- arm a weapon for aiming; an unpowered one is powered first and armed on the next frame
local function slotAim(h)
    if h.extra ~= 3 then return false end
    if not slotPowered(h) then
        if not slotPowerSet(h, true) then return false end
        G.pendingArm = { slot = h.id, at = E.frame + 2 }
        return true
    end
    return Ensign.armWeapon(h.id)
end
-- aim the armed weapon at a room (bombs may target our own ship); beams take two rooms
local function aimAt(room, first)
    local x, y = Ensign.roomCenter(room.extra, room.id)
    if not x then return false end
    if first then return Ensign.fireAt(room.extra, first.x, first.y, x, y) end
    return Ensign.fireAt(room.extra, x, y)
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
    if G.pendingArm and E.frame >= G.pendingArm.at then Ensign.armWeapon(G.pendingArm.slot); G.pendingArm = nil end
    if G.drain and G.drain.n > 0 then Ensign.sysPower(G.drain.id, -1); G.drain.n = G.drain.n - 1 end   -- one bar per frame

    -- weapon / drone slot A: a tap powers the slot up, and on a powered weapon arms it
    -- (the enemy group then takes over for the target). On a powered drone it powers down.
    -- Holding A, or moving while it is held, picks the slot up to drag it to another slot.
    if G.slotHold then
        local h = G.slotHold
        local moving = I.down("nav_up") or I.down("nav_down") or I.down("nav_left") or I.down("nav_right")
        if not h.started and I.down("slot_toggle") and (E.time - h.at >= 0.3 or moving) then
            h.started = true; G.drag = "slot"               -- carrying the slot: release on another slot swaps them
        end
        if I.released("slot_toggle") or not I.down("slot_toggle") then
            if h.started then
                G.drag = nil
                local dest = C.focus
                if dest and dest.kind == "armament" and dest.extra == h.hit.extra and dest.id ~= h.hit.id then
                    if h.hit.extra == 3 then Ensign.swapWeapons(h.hit.id, dest.id) else Ensign.swapDrones(h.hit.id, dest.id) end
                    E.feedback.pulse("select")
                end
            else
                if not h.powered then slotPowerSet(h.hit, true)          -- power on
                elseif h.hit.extra == 3 then slotAim(h.hit)              -- powered weapon: aim
                else slotPowerSet(h.hit, false) end                      -- powered drone: power off
            end
            G.slotHold = nil
        end
    end
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
    local sysFocus = (G.panel == "systems" or G.panel == "subsystems") and focus and focus.kind == "sysbox"
    local slotFocus = (G.panel == "weapons" or G.panel == "drones") and focus and focus.kind == "armament"
    local slotFocusPowered = slotFocus and slotPowered(focus)
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
            if not Ensign.door(t.airlock or false, t.index or -1, t.extra ~= 1) then
                C.moveTo(E.center(t)); C.click(1)                    -- fallback: the game's own click
                G.restore = { keep = rememberSelection(), at = E.frame + 3 }
            end
            E.feedback.pulse("select")
        end
        if I.pressed("detail_back") then
            local r = roomHit(targetRoom(t), shipIdOfPanel())
            leaveDetail()
            if r then C.snapTo(r) elseif focus then C.snapTo(focus) end
        end
    elseif G.targeting == "beam" then
        local room = (focus and focus.kind == "room") and focus or roomUnder
        if I.pressed("beam_point") and room then
            if G.beamStage == 0 then
                local x, y = Ensign.roomCenter(room.extra, room.id)
                if x then G.beamStart = { x = x, y = y }; G.beamStage = 1 else C.click(1) end
            else
                if not aimAt(room, G.beamStart) then C.click(1) end
                G.beamStage = 0
            end
            E.feedback.pulse("select")
        end
        if I.pressed("target_cancel") then if not Ensign.armWeapon(-1) then C.click(3) end; G.beamStage = 0 end
    elseif G.targeting == "weapon" or G.targeting == "bomb" then
        local room = (focus and focus.kind == "room") and focus or roomUnder
        if I.pressed("target_confirm") and room then
            if not aimAt(room) then C.click(1) end
            E.feedback.pulse("select")
        end
        if I.pressed("target_cancel") then if not Ensign.armWeapon(-1) then C.click(3) end end
    elseif G.targeting then   -- hacking / mind control / teleport: the combat controller's own handler
        local room = (focus and focus.kind == "room") and focus or roomUnder
        if I.pressed("target_confirm") and room then
            local done
            if G.targeting == "hack" and room.extra == 1 then done = Ensign.hackRoom(room.id)
            else done = Ensign.combatClick(E.center(room)) end
            if not done and G.targeting ~= "hack" then C.snapTo(room); C.click(1) end
            E.feedback.pulse("select")
        end
        if I.pressed("target_cancel") then if not cancelSpecial(G.targeting) then C.click(3) end end
        if I.pressed("system_use") and G.targeting == "teleport" then   -- X again: send -> return -> off
            cycleTeleporter(Ensign.specialArmed() or 0)
        end
    elseif onShip and focus and focus.kind == "room" then
        if selectedCrewCount() > 0 then
            if I.pressed("room_send") then sendSelected(focus); E.feedback.pulse("select") end
            if I.pressed("room_deselect_all") then clearSelection() end
        elseif I.pressed("room_open") then openRoom(focus, shipIdOfPanel()) end
        if I.pressed("room_detail") then enterDetail(focus, shipIdOfPanel()) end
    elseif roomUnder then
        local shipId = roomUnder.extra
        if selectedCrewCount() > 0 then
            if I.pressed("room_send") then sendSelected(roomUnder); E.feedback.pulse("select") end
            if I.pressed("room_deselect_all") then clearSelection() end
        elseif I.pressed("room_open") then setPanel(shipId == 1 and "enemy" or "ship", true); openRoom(roomUnder, shipId) end
        if I.pressed("room_detail") then setPanel(shipId == 1 and "enemy" or "ship", true); enterDetail(roomUnder, shipId) end
    elseif sysFocus then
        if I.pressed("system_power_up") then if not Ensign.sysPower(focus.id, 1) then E.feedback.pulse("select") end end
        if I.pressed("system_power_down") then Ensign.sysPower(focus.id, -1) end
        if I.pressed("system_off") and not SPECIAL[focus.id] then G.drain = { id = focus.id, n = systemPower(focus.id) } end   -- one bar per frame
        if I.pressed("system_use") and SPECIAL[focus.id] then
            if useSystem(focus.id) then E.feedback.pulse("select") end
        end
    elseif slotFocus then
        if I.pressed("slot_toggle") then G.slotHold = { hit = focus, at = E.time, powered = slotPowered(focus), started = false } end
        if I.pressed("slot_off") then slotPowerSet(focus, false) end
        if I.pressed("slot_retarget") then slotAim(focus) end
    elseif G.panel == "crew" and focus and focus.kind == "crewbox" then
        if I.pressed("crew_select") then
            local ok = pcall(function()
                local crew = E.gui().crewControl.crewBoxes[focus.extra].pCrew
                toggleSelect(crew)
            end)
            if not ok then C.click(1, { shift = selectedCrewCount() > 0 }) end
        end
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
    if I.pressed("pause") then if not Ensign.setPaused(not Ensign.paused()) then hotkey("pause", E.KEY.SPACE) end end
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
    elseif G.targeting == "hack" then
        hint[#hint + 1] = { "target_confirm", "Hack this system" }; hint[#hint + 1] = { "target_cancel", "Cancel" }
    elseif G.targeting == "mind" then
        hint[#hint + 1] = { "target_confirm", "Control crew here" }; hint[#hint + 1] = { "target_cancel", "Cancel" }
    elseif G.targeting == "teleport" then
        local tele = Ensign.specialArmed()
        hint[#hint + 1] = { "target_confirm", tele == 2 and "Return crew from here" or "Beam crew here" }
        hint[#hint + 1] = { "target_cancel", "Cancel" }; hint[#hint + 1] = { "group_enemy", "Other ship" }
    elseif G.targeting then
        hint[#hint + 1] = { "target_confirm", "Aim at room" }
        hint[#hint + 1] = { "target_cancel", "Cancel aim" }
        if G.targeting == "bomb" then hint[#hint + 1] = { "group_enemy", "Other ship" } end
    elseif (G.panel == "ship" or G.panel == "enemy") or roomUnder then
        if nsel > 0 then
            hint[#hint + 1] = { "room_send", "Send " .. nsel .. " here" }; hint[#hint + 1] = { "room_detail", "Pick more units" }; hint[#hint + 1] = { "room_deselect_all", "Deselect all" }
        else
            hint[#hint + 1] = { "room_open", "Units & doors" }
        end
    elseif sysFocus then
        hint[#hint + 1] = { "system_power_up", "Power +" }; hint[#hint + 1] = { "system_power_down", "Power -" }
        local kind = SPECIAL[focus.id]
        if kind == "cloaking" then hint[#hint + 1] = { "system_use", "Cloak" }
        elseif kind == "battery" then hint[#hint + 1] = { "system_use", "Backup battery" }
        elseif kind == "hacking" then hint[#hint + 1] = { "system_use", "Hack" }
        elseif kind == "mind" then hint[#hint + 1] = { "system_use", "Mind control" }
        elseif kind == "teleporter" then hint[#hint + 1] = { "system_use", "Teleport (again: return)" }
        else hint[#hint + 1] = { "system_off", "Unpower" } end
    elseif slotFocus then
        local aLabel = "Power on (hold to move)"
        if slotFocusPowered then aLabel = (focus.extra == 3) and "Aim (hold to move)" or "Power off (hold to move)" end
        hint[#hint + 1] = { "slot_toggle", aLabel }
        hint[#hint + 1] = { "slot_off", "Power off" }
        if focus.extra == 3 and not slotFocusPowered then hint[#hint + 1] = { "slot_retarget", "Power + aim" } end
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
