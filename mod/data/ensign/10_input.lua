-- 10_input.lua: Steam Input action layer with edge detection, auto-repeat and
-- analog-to-direction conversion. Semantic action names are shared between the
-- InGame and Menus action sets; the mapping below resolves them per set.
local E = ENSIGN
local I = {}
E.input = I

I.sets = { "InGame", "Menus" }
I.digital = {
    "nav_up", "nav_down", "nav_left", "nav_right", "select", "back", "alt", "info",
    "panel_prev", "panel_next", "power_up", "power_down", "pause", "game_menu", "jump",
    "crew_all", "doors_open", "doors_close", "autofire", "focus_toggle", "cursor_click",
    "cursor_rclick", "saved_positions", "return_positions",
    "menu_up", "menu_down", "menu_left", "menu_right", "menu_select", "menu_back", "menu_alt",
    "menu_info", "menu_tab_prev", "menu_tab_next", "menu_click", "menu_rclick", "menu_pause", "menu_escape",
}
I.analog = { "nav_move", "cursor_move", "menu_nav", "menu_cursor" }

-- semantic name -> action name per set
local menuMap = {
    nav_up = "menu_up", nav_down = "menu_down", nav_left = "menu_left", nav_right = "menu_right",
    select = "menu_select", back = "menu_back", alt = "menu_alt", info = "menu_info",
    panel_prev = "menu_tab_prev", panel_next = "menu_tab_next", cursor_click = "menu_click",
    cursor_rclick = "menu_rclick", pause = "menu_pause", game_menu = "menu_escape",
    nav_move = "menu_nav", cursor_move = "menu_cursor",
}
I.currentSet = "Menus"

local function resolve(name)
    if I.currentSet == "Menus" then return menuMap[name] or name end
    return name
end

-- state tables keyed by semantic name
local prev, cur, pressedAt, repeatAt = {}, {}, {}, {}
local virtual = {}        -- dev harness injects presses here (name -> ticks remaining)
I.lastDevice = "none"     -- "pad" or "mouse"; used to show/hide the HUD
I.lastPadTime = -100
I.connected = false
I.anyInput = false

function I.setSet(name)
    if name ~= I.currentSet then
        I.currentSet = name
        if E.native then Ensign.setActionSet(name) end
    end
end

local semantic = {}
for _, n in ipairs(I.digital) do if not n:match("^menu_") then semantic[#semantic + 1] = n end end

local function readDigital(name)
    if virtual[name] and virtual[name] > 0 then return true end
    if not E.native then return false end
    local s = Ensign.digital(resolve(name))
    return s
end

-- analog direction with hysteresis -> pseudo digital nav presses
local stickDir = { up = false, down = false, left = false, right = false }
local function stickDirections()
    if not E.native then return stickDir end
    local x, y = Ensign.analog(resolve("nav_move"))
    local hi, lo = 0.55, 0.35
    local function hyst(on, v) if on then return v > lo else return v > hi end end
    -- Steam Input: y is positive up for joystick_move
    stickDir.right = hyst(stickDir.right, x)
    stickDir.left = hyst(stickDir.left, -x)
    stickDir.up = hyst(stickDir.up, y)
    stickDir.down = hyst(stickDir.down, -y)
    return stickDir
end

function I.update()
    I.anyInput = false
    if E.native then
        I.connected = Ensign.poll()
    end
    local now = E.time
    local sd = stickDirections()
    for _, name in ipairs(semantic) do
        prev[name] = cur[name] or false
        local v = readDigital(name)
        if name == "nav_up" then v = v or sd.up
        elseif name == "nav_down" then v = v or sd.down
        elseif name == "nav_left" then v = v or sd.left
        elseif name == "nav_right" then v = v or sd.right end
        cur[name] = v
        if v and not prev[name] then
            pressedAt[name] = now
            repeatAt[name] = now + E.settings.repeatDelay
        end
        if v then I.anyInput = true end
    end
    for k, v in pairs(virtual) do if v > 0 then virtual[k] = v - 1 end end -- luacheck: ignore
    local cx, cy = I.cursorAxis()
    if math.abs(cx) > 0.05 or math.abs(cy) > 0.05 then I.anyInput = true end
    if I.anyInput then I.lastDevice = "pad"; I.lastPadTime = now end
end

function I.down(name) return cur[name] or false end
function I.pressed(name) return (cur[name] or false) and not (prev[name] or false) end
function I.released(name) return (prev[name] or false) and not (cur[name] or false) end
-- pressed, or held long enough to auto-repeat (for navigation)
function I.repeated(name)
    if I.pressed(name) then return true end
    if cur[name] and repeatAt[name] and E.time >= repeatAt[name] then
        repeatAt[name] = E.time + E.settings.repeatRate
        return true
    end
    return false
end
function I.heldFor(name) if cur[name] and pressedAt[name] then return E.time - pressedAt[name] end return 0 end

-- analog cursor axis (-1..1), y positive = down (screen space)
function I.cursorAxis()
    if not E.native then return 0, 0 end
    local x, y, active, mode = Ensign.analog(resolve("cursor_move"))
    if not active then return 0, 0 end
    -- absolute_mouse mode delivers deltas in pixels; joystick modes deliver -1..1
    if mode == 4 or mode == 5 then  -- AbsoluteMouse / RelativeMouse
        return x, -y, true
    end
    return x, -y, false
end

function I.navDirection()
    if I.repeated("nav_up") then return "up" end
    if I.repeated("nav_down") then return "down" end
    if I.repeated("nav_left") then return "left" end
    if I.repeated("nav_right") then return "right" end
    return nil
end

-- dev harness hooks
function I.virtualPress(name, ticks) virtual[name] = ticks or 2 end

function I.glyph(name)
    if not E.native then return nil end
    local o, text, glyph = Ensign.origin(resolve(name))
    if not o then return nil end
    return glyph, text
end

function I.register()
    if not E.native then return end
    local _, status = Ensign.registerActions({ sets = I.sets, digital = I.digital, analog = I.analog })
    E.log("Steam Input: " .. tostring(status))
    Ensign.setActionSet(I.currentSet)
end
