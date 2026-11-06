-- 50_game.lua: in-flight controls.
--
-- Groups (the bumpers rotate them; panel_crew / panel_systems / panel_ship jump directly):
--   crew     the crew portraits on the left
--   systems  reactor system boxes + weapon and drone slots (empty slots skipped) + autofire
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
--   Y  FTL jump       Start: ship screens       View: pause       d-pad: move, crossing group edges
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

local PANEL_ORDER = { "crew", "systems", "ship", "enemy" }
local PANEL_LABEL = { ship = "YOUR SHIP", enemy = "ENEMY SHIP", systems = "SYSTEMS & WEAPONS",
                      crew = "CREW", top = "CONTROLS" }
local PREFERRED = { ship = "room", enemy = "room", systems = "sysbox", crew = "crewbox", top = "ftl" }
local SYS = { shields = 0, engines = 1, oxygen = 2, weapons = 3, drones = 4, medbay = 5, pilot = 6,
              sensors = 7, doors = 8, teleporter = 9, cloaking = 10, artillery = 11, battery = 12,
              clonebay = 13, mind = 14, hacking = 15 }
-- screen layout: moving past the edge of a group crosses into its neighbour
local NEIGHBOR = {
    ship    = { down = "systems", up = "top", left = "crew", right = "enemy" },
    enemy   = { left = "ship", down = "systems", up = "top" },
    systems = { up = "ship", left = "crew" },
    crew    = { right = "ship", down = "systems", up = "top" },
    top     = { down = "ship" },
}



local function hasSystem(id)
    local ok, v = pcall(function() return E.playerShip():HasSystem(id) end)
    return ok and v or false
end

local function kindFilter(panel)
    if panel == "ship" then return function(h) return h.kind == "room" and h.extra == 0 end
    elseif panel == "enemy" then return function(h) return h.kind == "room" and h.extra == 1 end
    elseif panel == "systems" then
        local w, d = hasSystem(SYS.weapons), hasSystem(SYS.drones)
        return function(h)
            if h.kind == "sysbox" then return true end
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
    local function pickFrom(list, extra)
        local cands = {}
        for _, t in ipairs(list) do if not sameTarget(t, cur) and (not extra or extra(t)) then cands[#cands + 1] = t end end
        return N.pick(cur, cands, dir, nil, true)   -- strict cone: only what is really in that direction
    end
    local roomR = roomHit(R, shipId)
    -- 1. inside the current room (units, anchor), then its doors: from a unit only the
    --    door on the wall facing `dir`; from a door any door of the room in that direction
    local nxt = pickFrom(G.targets, function(t) return t.kind ~= "door" and inRoom(t, R) end)
    if not nxt then nxt = pickFrom(G.targets, function(t) return t.kind == "door" and inRoom(t, R) and (cur.kind == "door" or doorOnWall(t, roomR, dir)) end) end
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
    if G.panel == "top" then idx = 3 end
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

-- cross into the neighbouring group in that direction, landing in the direction of travel
local function transition(dir)
    local nb = NEIGHBOR[G.panel] and NEIGHBOR[G.panel][dir]
    if G.panel == "systems" and dir == "up" and C.focus and C.focus.x < 250 then nb = "crew" end
    if nb == "enemy" and not panelAvailable("enemy") then nb = nil end
    if not nb or not panelAvailable(nb) then return false end
    G.panel = nb
    leaveDetail()
    G.panelHits = collect(nb)
    C.mode = "snap"
    local from = { x = C.x - 1, y = C.y - 1, w = 2, h = 2, kind = "_cursor", id = -1 }
    C.snapTo(N.pick(from, G.panelHits, dir) or N.nearest(C.x, C.y, G.panelHits))
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
            local nxt = N.pick(from, G.panelHits, dir)
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
    local slotFocus = G.panel == "systems" and focus and focus.kind == "armament"
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
        elseif I.pressed("room_open") then
            if not enterDetail(focus, shipIdOfPanel()) then C.click(1) end
        end
        if I.pressed("room_detail") then enterDetail(focus, shipIdOfPanel()) end
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
    if I.pressed("escape_menu") then C.key(E.KEY.ESC) end
    if I.pressed("autofire") then hotkey("autofire", 118) end
    if I.pressed("crew_all") then hotkey("crew_all", 113) end
    if I.pressed("doors_open") then hotkey("open", 122) end
    if I.pressed("doors_close") then hotkey("close", 120) end
    if I.pressed("saved_positions") then hotkey("loadPositions", nil) end
    if I.pressed("return_positions") then hotkey("savePositions", nil) end

    -- hints (named by the verb that applies, so the glyph follows the user's binding)
    local nsel = selectedCrewCount()
    local hint = { { "nav_up", "Move" } }
    if G.detail then
        local t = G.target
        if t and t.kind == "crew" then
            hint[#hint + 1] = { "detail_toggle_unit", (t.crew.selectionState == 1) and "Deselect" or "Select" }
        elseif t and t.kind == "door" then
            hint[#hint + 1] = { "detail_toggle_door", "Open / close" }
        end
        hint[#hint + 1] = { "detail_back", "Rooms" }
    elseif G.targeting == "beam" then
        hint[#hint + 1] = { "beam_point", G.beamStage == 0 and "Beam start" or "Beam end" }
        hint[#hint + 1] = { "target_cancel", "Cancel" }
    elseif G.targeting then
        hint[#hint + 1] = { "target_confirm", "Target" }
        hint[#hint + 1] = { "target_cancel", "Cancel" }
        if G.targeting == "bomb" or G.targeting == "teleport" then hint[#hint + 1] = { "group_enemy", "Other ship" } end
    elseif G.panel == "ship" or G.panel == "enemy" then
        if nsel > 0 then
            hint[#hint + 1] = { "room_send", "Send " .. nsel }; hint[#hint + 1] = { "room_detail", "Units & doors" }; hint[#hint + 1] = { "room_deselect_all", "Deselect all" }
        else
            hint[#hint + 1] = { "room_open", "Units & doors" }
        end
    elseif sysFocus then
        hint[#hint + 1] = { "system_power_up", "Power +" }; hint[#hint + 1] = { "system_power_down", "Power -" }; hint[#hint + 1] = { "system_off", "Turn off" }
    elseif slotFocus then
        hint[#hint + 1] = { "slot_toggle", "Toggle (hold: move)" }; hint[#hint + 1] = { "slot_off", "Turn off" }; hint[#hint + 1] = { "slot_retarget", "Re-target" }
    elseif G.panel == "crew" then
        hint[#hint + 1] = { "crew_select", nsel > 0 and "Add" or "Select" }; hint[#hint + 1] = { "crew_reorder", "Hold: reorder" }
        if nsel > 0 then hint[#hint + 1] = { "crew_deselect_all", "Deselect all" } end
    else
        hint[#hint + 1] = { "ui_select", "Select" }
    end
    hint[#hint + 1] = { "jump", "Jump" }
    hint[#hint + 1] = { "group_next", "Group" }
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
