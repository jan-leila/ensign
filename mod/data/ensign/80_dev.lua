-- 80_dev.lua: headless test driver. Active only when the native shim runs with
-- ENSIGN_DEV=1. It reads a command script from the game's data directory
-- (ensign_test.txt) and executes one line at a time, writing results to
-- ensign_test_out.txt. Commands:
--   wait <seconds>          expect_screen <name>     press <action> [ticks]
--   nav <up|down|left|right> move <x> <y>           click [button]
--   key <sdlkey>            dump                     log <text>
--   stick <x> <y>           (left stick vector for a few ticks; y up)
--   set <panel>             fail <text>              end
local E = ENSIGN
local D = {}
E.dev = D
D.active = false
local lines, idx, waitUntil = {}, 1, 0
local out = {}

local function flush()
    if E.native then Ensign.devWriteFile("ensign_test_out.txt", table.concat(out, "\n") .. "\n") end
end
local function emit(s) out[#out + 1] = string.format("[%7.2f] %s", E.time, s); flush() end

function D.init()
    if not E.native or not Ensign.devEnabled() then return end
    local path = Ensign.devEnv("ENSIGN_TEST_SCRIPT") or "ensign_test.txt"
    local text = Ensign.devReadFile(path)
    if not text then return end
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then lines[#lines + 1] = line end
    end
    D.active = #lines > 0
    emit("dev script loaded: " .. #lines .. " commands")
end

local function gameState()
    local s = ""
    pcall(function()
        local gui = E.gui()
        local ship = E.playerShip()
        s = s .. " paused=" .. tostring(gui.bPaused) .. " selCrew=" .. tostring(gui.crewControl.selectedCrew:size())
        local w = gui.combatControl.weapControl.armedWeapon
        s = s .. " armed=" .. (w and w.blueprint.name or "nil")
        pcall(function() s = s .. " shieldsPower=" .. tostring(ship.shieldSystem.powerState.first) end)
        pcall(function() s = s .. " enginesPower=" .. tostring(ship:GetSystem(1).powerState.first) end)
        s = s .. " crewMode=" .. tostring(E.game.roomCrewMode) .. " targeting=" .. tostring(E.game.targeting)
        s = s .. " aimPts=" .. tostring(gui.combatControl.aimingPoints:size()) .. " movingBeam=" .. tostring(gui.combatControl.movingBeam)
        if w then s = s .. " wTargets=" .. tostring(w.targets:size()) end
        if ship and ship.weaponSystem then
            s = s .. " weaponsPower=" .. tostring(ship.weaponSystem.powerState.first)
            local names = {}
            for i = 0, ship.weaponSystem.weapons:size() - 1 do
                local wp = ship.weaponSystem.weapons[i]
                names[#names + 1] = wp.blueprint.name .. (wp.powered and "+" or "-") .. tostring(wp.targets:size())
            end
            s = s .. " weapons=" .. table.concat(names, ",")
        end
        if E.game.doorMode then for _, d in ipairs(E.game.doors) do s = s .. " door[" .. tostring(d.id) .. " " .. tostring(d.label) .. " " .. tostring(d.x) .. "," .. tostring(d.y) .. " open=" .. tostring(d.door and d.door.bOpen) .. "]" end end
        local t = E.game.target
        s = s .. " detail=" .. tostring(E.game.detail) .. " target=" .. (t and (t.kind .. "#" .. tostring(t.id) .. "@" .. tostring(t.roomId or t.roomSide)) or "nil") .. " carry=" .. tostring(E.menus.carry ~= nil)
        s = s .. " hoverW0=" .. tostring(Ensign.armamentHover(3, 0)) .. " hoverSys0=" .. tostring(Ensign.sysboxHover(0)) .. " hoverSys3=" .. tostring(Ensign.sysboxHover(3))
        local list = ship.vCrewList
        for i = 0, list:size() - 1 do
            local c = list[i]
            if c and c.iShipId == 0 then s = s .. string.format(" crew%d[%s room=%d pos=%d,%d sel=%d]", i, c:GetName(), c.iRoomId, c.x, c.y, c.selectionState) end
        end
    end)
    return s
end

local function dump()
    emit("screen=" .. Ensign.screen() .. gameState() .. " cursor=" .. math.floor(E.cursor.x) .. "," .. math.floor(E.cursor.y)
         .. " mode=" .. E.cursor.mode .. " panel=" .. tostring(E.game.panel)
         .. " focus=" .. (E.cursor.focus and (E.cursor.focus.kind .. "#" .. E.cursor.focus.id) or "nil")
         .. " steam=" .. tostring(Ensign.status()) .. " connected=" .. tostring(Ensign.connected()))
    local hits = Ensign.hitboxes()
    for _, h in ipairs(hits) do
        emit(string.format("  hit %-10s id=%-3d x=%4d y=%4d w=%3d h=%3d extra=%d enabled=%s label=%s",
            h.kind, h.id, h.x, h.y, h.w, h.h, h.extra, tostring(h.enabled), h.label or ""))
    end
end

function D.update()
    if not D.active then return end
    if E.time < waitUntil then return end
    local line = lines[idx]
    if not line then D.active = false emit("script finished") return end
    idx = idx + 1
    local cmd, rest = line:match("^(%S+)%s*(.*)$")
    local a1, a2 = rest:match("^(%S*)%s*(%S*)")
    if cmd == "wait" then waitUntil = E.time + (tonumber(a1) or 1)
    elseif cmd == "expect_screen" then
        local s = Ensign.screen()
        emit((s == a1 and "PASS" or "FAIL") .. " expect_screen " .. a1 .. " (got " .. s .. ")")
    elseif cmd == "press" then E.input.virtualPress(a1, tonumber(a2) or 2); emit("press " .. a1)
    elseif cmd == "press_if" then
        -- press_if <screen> <action>: press only while that screen is showing
        if Ensign.screen() == a1 then E.input.virtualPress(a2, 2); emit("press_if " .. a1 .. " -> " .. a2) end
    elseif cmd == "nav" then E.input.virtualPress("nav_" .. a1, 2); emit("nav " .. a1)
    elseif cmd == "sublift" then   -- sublift <dy> [frameDx frameDy]: subsystem row lift calibration
        D.liftOverride = tonumber(a1) or 0
        local fx, fy = rest:match("^%S+%s+(%S+)%s+(%S+)")
        if fx then E.hud.SUBSYSTEM_FRAME_DX, E.hud.SUBSYSTEM_FRAME_DY = tonumber(fx), tonumber(fy) end
        emit("sublift " .. rest)
    elseif cmd == "stick" then E.input.virtualAxis(tonumber(a1) or 0, tonumber(a2) or 0, 3); emit("stick " .. rest)
    elseif cmd == "move" then E.cursor.mode = "free"; E.cursor.focus = nil; E.cursor.moveTo(tonumber(a1) or 0, tonumber(a2) or 0); emit("move " .. rest)
    elseif cmd == "click" then E.cursor.click(tonumber(a1) or 1); emit("click " .. (a1 or "1"))
    elseif cmd == "key" then E.cursor.key(tonumber(a1)); emit("key " .. a1)
    elseif cmd == "focus" then
        -- focus <kind> [id|reachable]: reachable = a star map beacon connected to the current one
        for _, h in ipairs(Ensign.hitboxes()) do
            local ok = h.kind == a1 and (a2 == "" or h.id == tonumber(a2) or (a2 == "reachable" and h.kind == "location" and h.extra % 4 >= 2 and h.extra % 2 == 0))
            if ok then E.cursor.mode = "snap"; E.cursor.snapTo(h); emit("focus " .. rest .. " -> " .. h.kind .. "#" .. h.id); break end
        end
    elseif cmd == "wait_screen" then
        local s = Ensign.screen()
        if s == a1 then emit("PASS wait_screen " .. a1)
        elseif (tonumber(a2) or 10) > 0 then idx = idx - 1; lines[idx] = string.format("wait_screen %s %d", a1, (tonumber(a2) or 10) - 1); waitUntil = E.time + 1
        else emit("FAIL wait_screen " .. a1 .. " (got " .. s .. ")") end
    elseif cmd == "panel" then E.game.setPanel(a1); emit("panel " .. a1)
    elseif cmd == "hover" then
        -- hover <sysId> <x> <y>: move the cursor there and report the system box hover flag
        E.cursor.mode = "free"; E.cursor.focus = nil
        E.cursor.moveTo(tonumber(a2) or 0, tonumber(rest:match("^%S+%s+%S+%s+(%S+)")) or 0)
        idx = idx - 1; lines[idx] = "hover_read " .. rest; waitUntil = E.time + 0.05
    elseif cmd == "hover_read" then
        local x, y = tonumber(a2), tonumber(rest:match("^%S+%s+%S+%s+(%S+)"))
        emit(string.format("hover sys%s at %d,%d = %s", a1, x, y, tostring(Ensign.sysboxHover(tonumber(a1)))))
    elseif cmd == "doors" then
        for _, d in ipairs(E.game.allDoors()) do emit(string.format("door %s rooms %s centre %d,%d %s", tostring(d.id), d.label, d.x + d.w / 2, d.y + d.h / 2, d.door.bVertical and "V" or "H")) end
        for _, h in ipairs(Ensign.hitboxes()) do if h.kind == "room" and h.extra == 0 then emit(string.format("room %d rect %d,%d %dx%d", h.id, h.x, h.y, h.w, h.h)) end end
    elseif cmd == "probe" then Ensign.devProbe(); emit("probe written to ensign.log")
    elseif cmd == "event" then
        -- force a game event (e.g. PIRATE for a hostile ship, STORE for a shop)
        local ok, err = pcall(function()
            Hyperspace.CustomEventsParser.GetInstance():LoadEvent(Hyperspace.App.world, a1, false, -1)
        end)
        emit("event " .. a1 .. " -> " .. tostring(ok) .. " " .. tostring(err or ""))
    elseif cmd == "addweapon" then
        local ok, err = pcall(function()
            local bp = Hyperspace.Blueprints:GetWeaponBlueprint(a1)
            Hyperspace.ships.player:AddWeapon(bp, tonumber(a2) or -1)
        end)
        emit("addweapon " .. a1 .. " -> " .. tostring(ok) .. " " .. tostring(err or ""))
    elseif cmd == "addsystem" then
        local ok, err = pcall(function() Hyperspace.ships.player:AddSystem(tonumber(a1)) end)
        emit("addsystem " .. a1 .. " -> " .. tostring(ok) .. " " .. tostring(err or ""))
    elseif cmd == "power" then
        -- power <systemId> <amount>: add reactor power to a system directly
        local ok, err = pcall(function()
            local sys = Hyperspace.ships.player:GetSystem(tonumber(a1))
            for _ = 1, tonumber(a2) or 1 do sys:IncreasePower(1, false) end
        end)
        emit("power " .. rest .. " -> " .. tostring(ok) .. " " .. tostring(err or ""))
    elseif cmd == "shot" then
        -- ask the harness for a screenshot; the request file disappears once taken
        Ensign.devWriteFile("ensign_shot_request", a1)
        local deadline = E.time + 3
        idx = idx - 1
        lines[idx] = "shot_wait " .. a1 .. " " .. string.format("%.2f", deadline)
        waitUntil = E.time + 0.2
    elseif cmd == "shot_wait" then
        if Ensign.devReadFile("ensign_shot_request") == nil then emit("shot " .. a1 .. " taken")
        elseif E.time > (tonumber(a2) or 0) then emit("WARN shot " .. a1 .. " not taken (no harness poller?)")
        else idx = idx - 1; waitUntil = E.time + 0.2 end
    elseif cmd == "fakepad" then
        -- pretend a controller is attached so the HUD draws (glyphs from a fixed family)
        E.input.fakeFamily = a1 ~= "" and a1 or "xbox"
        E.input.connected = true
        E.input.lastDevice = "pad"
        emit("fakepad " .. E.input.fakeFamily)
    elseif cmd == "dump" then dump()
    elseif cmd == "log" then emit(rest)
    elseif cmd == "fail" then emit("FAIL " .. rest)
    elseif cmd == "end" then D.active = false emit("script finished")
    else emit("unknown command: " .. line) end
end
