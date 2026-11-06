-- 50_game.lua: in-flight controls. The screen is split into panels; the bumpers
-- cycle them and the d-pad / stick moves a selection inside the active panel:
--   ship     your rooms (crew inside a room, doors of a room)
--   enemy    the enemy's rooms (forced while a weapon / power is aimed)
--   power    the reactor's system boxes
--   weapons  weapon slots + autofire
--   drones   drone slots
--   crew     the crew portraits on the left
--   top      FTL button, ship / store / options buttons
local E = ENSIGN
local G = {}
E.game = G
local I, C, N

G.panel = "ship"
G.hits = {}
G.panelHits = {}
G.roomCrewMode = false     -- selecting individual crew inside a room
G.roomCrew = {}
G.crewIndex = 1
G.doorMode = false         -- cycling the doors of the focused room
G.doors = {}
G.doorIndex = 1
G.drag = nil               -- button held for a drag ("select" or "alt")
G.targeting = nil          -- "weapon" | "beam" | "bomb" | "teleport" | "hack" | "mind" | nil
G.beamStage = 0
G.hint = {}
G.lastPanel = nil
G.prevFocus = nil

local PANEL_ORDER = { "ship", "enemy", "power", "weapons", "drones", "crew", "top" }
local PANEL_LABEL = { ship = "YOUR SHIP", enemy = "ENEMY SHIP", power = "POWER", weapons = "WEAPONS",
                      drones = "DRONES", crew = "CREW", top = "CONTROLS" }
local PREFERRED = { ship = "room", enemy = "room", power = "sysbox", weapons = "armament", drones = "armament", crew = "crewbox", top = "ftl" }
local SYS = { shields = 0, engines = 1, oxygen = 2, weapons = 3, drones = 4, medbay = 5, pilot = 6,
              sensors = 7, doors = 8, teleporter = 9, cloaking = 10, artillery = 11, battery = 12,
              clonebay = 13, mind = 14, hacking = 15 }
-- kinds that can be dragged with a held button (FTL reorders weapons/drones with the left
-- button; Hyperspace reorders the crew list with the right button)
local DRAG_LEFT = { armament = true }
local DRAG_RIGHT = { crewbox = true }

local function kindFilter(panel)
    if panel == "ship" then return function(h) return h.kind == "room" and h.extra == 0 end
    elseif panel == "enemy" then return function(h) return h.kind == "room" and h.extra == 1 end
    elseif panel == "power" then return function(h) return h.kind == "sysbox" end
    elseif panel == "weapons" then return function(h) return (h.kind == "armament" and h.extra == 3) or h.kind == "autofire" end
    elseif panel == "drones" then return function(h) return h.kind == "armament" and h.extra == 4 end
    elseif panel == "crew" then return function(h) return h.kind == "crewbox" or (h.kind == "button" and (h.id == 600 or h.id == 601)) end
    elseif panel == "top" then return function(h) return h.kind == "ftl" or h.kind == "topbar" end end
    return function() return false end
end

local function panelAvailable(panel)
    local f = kindFilter(panel)
    for _, h in ipairs(G.hits) do if f(h) then return true end end
    return false
end

local function collect(panel)
    local f = kindFilter(panel)
    local out = {}
    for _, h in ipairs(G.hits) do if f(h) then out[#out + 1] = h end end
    return out
end

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

local function leaveSubModes()
    G.roomCrewMode = false
    G.doorMode = false
end

-- First element of a panel: nearest room for the ships, left-most widget elsewhere.
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
        leaveSubModes()
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

-- crew inside the focused room (player ship)
local function crewInRoom(roomId)
    local out = {}
    local ship = E.playerShip()
    if not ship then return out end
    local ox, oy = Ensign.shipOrigins()
    pcall(function()
        local list = ship.vCrewList
        for i = 0, list:size() - 1 do
            local c = list[i]
            if c and c.currentShipId == 0 and c.iRoomId == roomId and not c.bDead and c:GetControllable() then
                out[#out + 1] = { kind = "crew", id = i, x = ox + c.x - 12, y = oy + c.y - 14, w = 24, h = 28,
                                  label = c:GetName(), extra = 0, crew = c }
            end
        end
    end)
    table.sort(out, function(a, b) if a.x == b.x then return a.y < b.y end return a.x < b.x end)
    return out
end

-- doors touching a room, from the game's own door objects (ship-local x,y)
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
local function doorsOfRoom(roomId)
    local out = {}
    for _, h in ipairs(G.allDoors()) do
        if h.r1 == roomId or h.r2 == roomId then out[#out + 1] = h end
    end
    table.sort(out, function(a, b) if math.abs(a.y - b.y) > 5 then return a.y < b.y end return a.x < b.x end)
    return out
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

local function currentSubHit()
    if G.roomCrewMode then return G.roomCrew[G.crewIndex] end
    if G.doorMode then return G.doors[G.doorIndex] end
    return nil
end

function G.update()
    I, C, N = E.input, E.cursor, E.nav
    G.hits = Ensign.hitboxes()
    local targeting = detectTargeting()
    local targetingChanged = targeting ~= G.targeting
    G.targeting = targeting
    if targetingChanged then G.beamStage = 0 end

    -- forced panels while aiming
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
    C.focus = N.refresh(C.focus, G.panelHits) or (C.mode == "snap" and firstHit(G.panel, G.panelHits) or nil)
    if C.mode == "snap" and C.focus and not currentSubHit() and not E.sameHit(C.focus, G.prevFocus) then C.snapTo(C.focus) end
    G.prevFocus = C.focus
    local focus = C.focus

    -- release a held drag button
    if G.drag == "select" and I.released("select") then C.release(1); G.drag = nil end
    if G.drag == "alt" and I.released("alt") then C.release(3); G.drag = nil end

    -- panels
    if I.pressed("panel_prev") then cyclePanel(-1) end
    if I.pressed("panel_next") then cyclePanel(1) end
    if I.pressed("focus_toggle") then
        if G.panel == "enemy" then setPanel("ship") elseif panelAvailable("enemy") then setPanel("enemy") end
    end

    -- free cursor
    if C.updateFree() then leaveSubModes() end

    -- directional navigation
    local dir = I.navDirection()
    if dir then
        if G.roomCrewMode and #G.roomCrew > 0 then
            local nxt = N.pick(G.roomCrew[G.crewIndex], G.roomCrew, dir)
            if nxt then
                for i, h in ipairs(G.roomCrew) do if h == nxt then G.crewIndex = i end end
                C.moveTo(E.center(nxt))
                E.feedback.tick()
            end
        elseif G.doorMode then
            -- leaving door mode: navigation goes back to rooms
            G.doorMode = false
            local nxt = focus and N.pick(focus, G.panelHits, dir)
            if nxt then C.snapTo(nxt) elseif focus then C.snapTo(focus) end
            E.feedback.tick()
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
            end
        end
    end

    -- select
    if I.pressed("select") or I.pressed("cursor_click") then
        if G.roomCrewMode and #G.roomCrew > 0 then
            local crew = G.roomCrew[G.crewIndex]
            if crew then
                C.moveTo(E.center(crew))
                C.click(1, { shift = selectedCrewCount() > 0 })
                E.feedback.pulse("select")
            end
        elseif G.doorMode and G.doors[G.doorIndex] then
            C.moveTo(E.center(G.doors[G.doorIndex]))
            C.click(1)                  -- toggle the door
            E.feedback.pulse("select")
        elseif G.targeting == "beam" then
            C.click(1)
            G.beamStage = G.beamStage == 0 and 1 or 0
            if G.beamStage == 1 then C.mode = "free" end
        elseif focus and focus.kind == "room" and selectedCrewCount() > 0 and not G.targeting then
            -- FTL issues move orders with the RIGHT button (a left click on a room deselects)
            C.click(3)
            E.feedback.pulse("select")
        elseif focus and focus.kind == "room" and focus.extra == 0 and G.panel == "ship"
               and selectedCrewCount() == 0 and not G.targeting then
            G.roomCrew = crewInRoom(focus.id)
            if #G.roomCrew > 0 then
                G.roomCrewMode = true
                G.crewIndex = 1
                C.moveTo(E.center(G.roomCrew[1]))
                E.feedback.tick()
            else
                C.click(1)
            end
        elseif focus and DRAG_LEFT[focus.kind] and I.pressed("select") then
            -- hold to drag: the button stays down until released; a quick tap is a click
            C.press(1)
            G.drag = "select"
        else
            C.click(1)
        end
    end
    -- alt / right button
    if I.pressed("alt") or I.pressed("cursor_rclick") then
        if focus and DRAG_RIGHT[focus.kind] and I.pressed("alt") then
            C.press(3)                  -- held: reorder the crew list; tap: nothing harmful
            G.drag = "alt"
        elseif focus and focus.kind == "sysbox" and focus.id == SYS.teleporter then
            hotkey("ret_tele", nil)
        elseif focus and focus.kind == "sysbox" and focus.id == SYS.doors then
            hotkey("close", 120)
        else
            C.click(3)
        end
    end
    -- back: leave the current sub-mode, keeping any crew selection so a destination can be picked
    if I.pressed("back") then
        if G.roomCrewMode or G.doorMode then
            leaveSubModes()
            if focus then C.snapTo(focus) end
        elseif G.targeting then
            C.click(3)
        elseif G.panel ~= "ship" then
            setPanel("ship")
        elseif selectedCrewCount() > 0 then
            if focus and focus.kind == "room" then C.snapTo(focus) end
            C.click(1)                  -- a left click on a room with crew selected clears the selection
        end
    end
    -- info / Y: doors of the focused room, special systems, autofire
    if I.pressed("info") then
        if G.panel == "ship" and focus and focus.kind == "room" and not G.targeting then
            if not G.doorMode then
                G.doors = doorsOfRoom(focus.id)
                G.doorIndex = 1
                G.doorMode = #G.doors > 0
                G.roomCrewMode = false
            else
                G.doorIndex = G.doorIndex % #G.doors + 1
            end
            if G.doorMode then C.moveTo(E.center(G.doors[G.doorIndex])); E.feedback.tick() end
        elseif focus and focus.kind == "sysbox" then
            local primary = systemHotkeys(focus.id)
            if primary then hotkey(primary, nil) end
        elseif G.panel == "weapons" then
            hotkey("autofire", 118)
        end
    end
    -- power triggers
    if I.pressed("power_up") then
        if G.panel == "power" or G.panel == "weapons" or G.panel == "drones" then
            if focus then C.snapTo(focus) end
            C.click(1)
        end
    end
    if I.pressed("power_down") then
        if G.panel == "power" or G.panel == "weapons" or G.panel == "drones" then
            if focus then C.snapTo(focus) end
            C.click(3)
        end
    end
    -- global hotkeys
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
    local hint = { { "nav_up", "Move" } }
    if G.roomCrewMode then
        hint[#hint + 1] = { "select", selectedCrewCount() > 0 and "Add crew" or "Select crew" }
        hint[#hint + 1] = { "back", "Rooms" }
    elseif G.doorMode then
        hint[#hint + 1] = { "select", "Open / close" }; hint[#hint + 1] = { "info", "Next door" }; hint[#hint + 1] = { "back", "Rooms" }
    elseif G.targeting == "beam" then
        hint[#hint + 1] = { "select", G.beamStage == 0 and "Beam start" or "Beam end" }
        hint[#hint + 1] = { "back", "Cancel" }
    elseif G.targeting then
        hint[#hint + 1] = { "select", "Target" }
        hint[#hint + 1] = { "back", "Cancel" }
        if G.targeting == "bomb" or G.targeting == "teleport" then hint[#hint + 1] = { "focus_toggle", "Other ship" } end
    elseif G.panel == "ship" then
        hint[#hint + 1] = { "select", selectedCrewCount() > 0 and "Send crew" or "Crew in room" }
        hint[#hint + 1] = { "info", "Doors" }
        if selectedCrewCount() > 0 then hint[#hint + 1] = { "back", "Deselect" } end
        hint[#hint + 1] = { "panel_next", "Panel" }
    elseif G.panel == "power" then
        hint[#hint + 1] = { "power_up", "Power +" }; hint[#hint + 1] = { "power_down", "Power -" }
        if focus and systemHotkeys(focus.id) then hint[#hint + 1] = { "info", "Activate" } end
        hint[#hint + 1] = { "panel_next", "Panel" }
    elseif G.panel == "weapons" or G.panel == "drones" then
        hint[#hint + 1] = { "select", G.panel == "weapons" and "Arm (hold: move)" or "Deploy (hold: move)" }
        hint[#hint + 1] = { "alt", "Depower" }
        if G.panel == "weapons" then hint[#hint + 1] = { "info", "Autofire" } end
        hint[#hint + 1] = { "panel_next", "Panel" }
    elseif G.panel == "crew" then
        hint[#hint + 1] = { "select", "Select" }; hint[#hint + 1] = { "alt", "Hold: reorder" }; hint[#hint + 1] = { "crew_all", "All crew" }
        hint[#hint + 1] = { "panel_next", "Panel" }
    else
        hint[#hint + 1] = { "select", "Select" }; hint[#hint + 1] = { "panel_next", "Panel" }
    end
    hint[#hint + 1] = { "pause", "Pause" }
    G.hint = hint
end

function G.render()
    local sub = currentSubHit()
    if sub then
        C.drawFrame(sub, nil, 2)
        if C.focus then C.drawFrame(C.focus, Graphics.GL_Color(1, 1, 1, 0.35), 3) end
    elseif C.mode == "snap" and C.focus then
        C.drawFrame(C.focus)
    end
end

function G.panelLabel() return PANEL_LABEL[G.panel] or "" end
function G.setPanel(name) I, C, N = E.input, E.cursor, E.nav; setPanel(name) end
