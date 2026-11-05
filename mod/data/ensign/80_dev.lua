-- 80_dev.lua: headless test driver. Active only when the native shim runs with
-- ENSIGN_DEV=1. It reads a command script from the game's data directory
-- (ensign_test.txt) and executes one line at a time, writing results to
-- ensign_test_out.txt. Commands:
--   wait <seconds>          expect_screen <name>     press <action> [ticks]
--   nav <up|down|left|right> move <x> <y>           click [button]
--   key <sdlkey>            dump                     log <text>
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
        if ship and ship.shieldSystem then s = s .. " shieldsPower=" .. tostring(ship.shieldSystem.powerState.first) end
        s = s .. " crewMode=" .. tostring(E.game.roomCrewMode) .. " targeting=" .. tostring(E.game.targeting)
        if ship and ship.weaponSystem then s = s .. " weaponsPower=" .. tostring(ship.weaponSystem.powerState.first) end
        s = s .. " hoverW0=" .. tostring(Ensign.armamentHover(3, 0)) .. " hoverW1=" .. tostring(Ensign.armamentHover(3, 1)) .. " hoverSys3=" .. tostring(Ensign.sysboxHover(3))
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
    elseif cmd == "nav" then E.input.virtualPress("nav_" .. a1, 2); emit("nav " .. a1)
    elseif cmd == "move" then E.cursor.mode = "free"; E.cursor.focus = nil; E.cursor.moveTo(tonumber(a1) or 0, tonumber(a2) or 0); emit("move " .. rest)
    elseif cmd == "click" then E.cursor.click(tonumber(a1) or 1); emit("click " .. (a1 or "1"))
    elseif cmd == "key" then E.cursor.key(tonumber(a1)); emit("key " .. a1)
    elseif cmd == "focus" then
        for _, h in ipairs(Ensign.hitboxes()) do
            if h.kind == a1 and (a2 == "" or h.id == tonumber(a2)) then E.cursor.mode = "snap"; E.cursor.snapTo(h); emit("focus " .. rest); break end
        end
    elseif cmd == "wait_screen" then
        local s = Ensign.screen()
        if s == a1 then emit("PASS wait_screen " .. a1)
        elseif (tonumber(a2) or 10) > 0 then idx = idx - 1; lines[idx] = string.format("wait_screen %s %d", a1, (tonumber(a2) or 10) - 1); waitUntil = E.time + 1
        else emit("FAIL wait_screen " .. a1 .. " (got " .. s .. ")") end
    elseif cmd == "probe" then Ensign.devProbe(); emit("probe written to ensign.log")
    elseif cmd == "dump" then dump()
    elseif cmd == "log" then emit(rest)
    elseif cmd == "fail" then emit("FAIL " .. rest)
    elseif cmd == "end" then D.active = false emit("script finished")
    else emit("unknown command: " .. line) end
end
