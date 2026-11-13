-- 10_input.lua: Steam Input action layer with edge detection, auto-repeat and
-- analog-to-direction conversion.
--
-- Every state-specific verb is its own Steam action (room_open, detail_toggle_unit,
-- system_power_up, ...). Several of them share a physical button by default; the
-- modules only consult the verbs that apply to their current state, so each one
-- stays independently rebindable in Steam's configurator.
local E = ENSIGN
local I = {}
E.input = I

I.sets = { "InGame", "Menus" }
I.digital = {
    -- in flight
    "nav_up", "nav_down", "nav_left", "nav_right",
    "group_prev", "group_next", "group_crew", "group_systems", "group_weapons", "group_drones", "group_ship", "group_enemy",
    "room_open", "room_send", "room_detail", "room_deselect_all",
    "detail_toggle_unit", "detail_toggle_door", "detail_back",
    "target_confirm", "beam_point", "target_cancel",
    "system_power_up", "system_power_down", "system_off", "system_use",
    "slot_toggle", "slot_off", "slot_retarget",
    "crew_select", "crew_deselect_all", "crew_reorder",
    "ui_select", "ui_back",
    "jump", "pause", "ship_screens", "ship_inventory", "escape_menu",
    "autofire", "crew_all", "doors_open", "doors_close", "saved_positions", "return_positions",
    "cursor_click", "cursor_rclick",
    -- direct actions (unbound by default)
    "weapon_slot_1", "weapon_slot_2", "weapon_slot_3", "weapon_slot_4",
    "drone_slot_1", "drone_slot_2", "drone_slot_3", "drone_slot_4",
    "crew_slot_1", "crew_slot_2", "crew_slot_3", "crew_slot_4", "crew_slot_5", "crew_slot_6", "crew_slot_7", "crew_slot_8",
    "power_shields_up", "power_shields_down", "power_engines_up", "power_engines_down", "power_oxygen_up", "power_oxygen_down",
    "power_weapons_up", "power_weapons_down", "power_drones_up", "power_drones_down", "power_medbay_up", "power_medbay_down",
    "power_clonebay_up", "power_clonebay_down", "power_teleporter_up", "power_teleporter_down", "power_cloaking_up", "power_cloaking_down",
    "power_artillery_up", "power_artillery_down", "power_hacking_up", "power_hacking_down", "power_mind_up", "power_mind_down",
    "use_teleport", "use_cloak", "use_battery", "use_mind", "use_hacking", "slot_clear_target",
    -- menus
    "menu_up", "menu_down", "menu_left", "menu_right",
    "menu_select", "menu_pickup", "menu_drop", "menu_back", "menu_put_back", "menu_alt", "menu_info",
    "menu_tab_prev", "menu_tab_next", "menu_click", "menu_rclick", "menu_pause", "menu_escape",
    "choice_1", "choice_2", "choice_3", "choice_4", "choice_5", "choice_6", "choice_7", "choice_8",
    "map_next_sector", "map_cancel",
}
I.analog = { "nav_move", "cursor_move", "menu_nav", "menu_cursor" }

-- Physical buttons for the headless test driver (`press a`): the verbs each button
-- carries by default. The modules decide which verb applies.
I.BUTTONS = {
    a = { "room_open", "room_send", "detail_toggle_unit", "detail_toggle_door", "target_confirm", "beam_point",
          "system_power_up", "slot_toggle", "crew_select", "ui_select", "menu_select", "menu_pickup", "menu_drop" },
    b = { "room_deselect_all", "detail_back", "target_cancel", "system_power_down", "slot_off", "crew_deselect_all",
          "ui_back", "menu_back", "menu_put_back" },
    x = { "room_detail", "system_off", "system_use", "slot_retarget", "crew_reorder", "menu_alt" },
    y = { "jump", "menu_info" },
    lb = { "group_prev", "menu_tab_prev" }, rb = { "group_next", "menu_tab_next" },
    lt = { "system_power_down" }, rt = { "system_power_up" },
    start = { "ship_screens", "menu_escape" }, view = { "ship_inventory", "menu_escape" },
    r5 = { "pause", "menu_pause" }, l3 = { "crew_all" },
    up = { "nav_up", "menu_up" }, down = { "nav_down", "menu_down" }, left = { "nav_left", "menu_left" }, right = { "nav_right", "menu_right" },
}

-- Keyboard: every physical pad button also has a key, so the whole mod works without a
-- controller. The keys avoid everything FTL binds itself. (SDL 1.2 key codes.)
I.KEYS = {
    [273] = "up", [274] = "down", [276] = "left", [275] = "right",   -- arrows
    [13] = "a", [271] = "a",                                         -- Enter / keypad Enter
    [8] = "b",                                                       -- Backspace
    [127] = "x",                                                     -- Delete
    [277] = "y",                                                     -- Insert
    [91] = "lb", [93] = "rb", [280] = "lb", [281] = "rb",            -- [ ] and Page Up / Page Down
    [45] = "lt", [61] = "rt",                                        -- - and =
    [278] = "start", [279] = "view",                                 -- Home / End
}
I.KEY_NAMES = { up = "Arrows", down = "Arrows", left = "Arrows", right = "Arrows", a = "Enter", b = "Backspace", x = "Delete",
                y = "Insert", lb = "[", rb = "]", lt = "-", rt = "=", start = "Home", view = "End",
                l3 = "Q", r5 = "Space", l4 = "Z", r4 = "X", l5 = "V", nav_move = "Arrows", cursor_move = "Mouse" }
local kbd = {}            -- physical button name -> held
I.keyboard = false        -- a mapped key has been used this session
local verbButtons = {}    -- verb -> physical buttons carrying it
I.currentSet = "Menus"
-- the generic navigation names resolve to the menu variants in the Menus set
local menuMap = { nav_up = "menu_up", nav_down = "menu_down", nav_left = "menu_left", nav_right = "menu_right",
                  nav_move = "menu_nav", cursor_move = "menu_cursor", cursor_click = "menu_click", cursor_rclick = "menu_rclick" }
local function resolve(name)
    if I.currentSet == "Menus" then return menuMap[name] or name end
    return name
end

local prev, cur, pressedAt, repeatAt = {}, {}, {}, {}
local virtual = {}
I.lastDevice = "none"
I.lastPadTime = -100
I.connected = false
I.anyInput = false
I.fakeFamily = nil

-- A button that is still held when the action set changes (Start opens the ship
-- screens -> set Menus, where Start is menu_escape) would otherwise register as a
-- fresh press in the new set. Rising edges in the first moments after a switch are
-- held over: ignored until that button is released.
local switchedAt = -100
local heldOver = {}
function I.setSet(name)
    if name ~= I.currentSet then
        I.currentSet = name
        switchedAt = E.time or 0
        if E.native then Ensign.setActionSet(name) end
    end
end

local tracked = {}
for _, n in ipairs(I.digital) do if not menuMap[n] then tracked[#tracked + 1] = n end end
for btn, verbs in pairs(I.BUTTONS) do for _, v in ipairs(verbs) do verbButtons[v] = verbButtons[v] or {}; table.insert(verbButtons[v], btn) end end
for k in pairs(menuMap) do tracked[#tracked + 1] = k end

-- held state of a verb and where it comes from ("pad" for Steam Input and the test driver, "kbd")
local function readDigital(name)
    if virtual[name] and virtual[name] > 0 then return true, "pad" end
    for _, btn in ipairs(verbButtons[name] or {}) do if kbd[btn] then return true, "kbd" end end
    if not E.native then return false end
    if Ensign.digital(resolve(name)) then return true, "pad" end
    return false
end

-- key events from the game (Hyperspace ON_KEY_DOWN / ON_KEY_UP); returns true when the
-- key is one of ours. Text entry screens keep the keyboard to themselves.
function I.onKey(code, down)
    local btn = I.KEYS[code]
    if not btn then return false end
    if E.injecting then return false end
    if E.screen == "rename" or E.screen == "input" then return false end
    kbd[btn] = down and true or nil
    if down then I.keyboard = true; I.lastDevice = "kbd"; I.lastPadTime = E.time or 0 end
    return true
end

-- raw left-stick / pad vector (x right, y up, both -1..1); the test driver can fake it
local vAxis = { x = 0, y = 0, ticks = 0 }
function I.virtualAxis(x, y, ticks) vAxis.x, vAxis.y, vAxis.ticks = x, y, ticks or 2 end
function I.navAxis()
    if vAxis.ticks > 0 then return vAxis.x, vAxis.y, math.sqrt(vAxis.x ^ 2 + vAxis.y ^ 2) end
    if not E.native then return 0, 0, 0 end
    local x, y = Ensign.analog(resolve("nav_move"))
    x, y = x or 0, y or 0
    return x, y, math.sqrt(x * x + y * y)
end

local stickDir = { up = false, down = false, left = false, right = false }
local function stickDirections()
    local x, y = I.navAxis()
    local hi, lo = 0.55, 0.35
    local function hyst(on, v) if on then return v > lo else return v > hi end end
    stickDir.right = hyst(stickDir.right, x)
    stickDir.left = hyst(stickDir.left, -x)
    stickDir.up = hyst(stickDir.up, y)
    stickDir.down = hyst(stickDir.down, -y)
    return stickDir
end

local loggedPress = {}
function I.update()
    I.anyInput = false
    if E.native then
        I.connected = Ensign.poll() or (I.fakeFamily ~= nil) or I.keyboard
    end
    local now = E.time
    local sd = stickDirections()
    local guard = (now - switchedAt) < E.settings.setSwitchGuard
    for _, name in ipairs(tracked) do -- luacheck: ignore 421
        prev[name] = cur[name] or false
        local v, src = readDigital(name)
        local isVirtual = virtual[name] and virtual[name] > 0
        if v and not prev[name] and guard and not isVirtual then heldOver[name] = true end
        if heldOver[name] then
            if not v then heldOver[name] = nil end
            v = false
        end
        if name == "nav_up" then v = v or sd.up
        elseif name == "nav_down" then v = v or sd.down
        elseif name == "nav_left" then v = v or sd.left
        elseif name == "nav_right" then v = v or sd.right end
        cur[name] = v
        if v and not prev[name] then
            pressedAt[name] = now
            repeatAt[name] = now + E.settings.repeatDelay
            if not loggedPress[name] then loggedPress[name] = true; E.log("first press: " .. name .. " (set " .. I.currentSet .. ")") end
        end
        if v and src == "pad" then I.anyInput = true end
    end
    for k, v in pairs(virtual) do if v > 0 then virtual[k] = v - 1 end end -- luacheck: ignore
    if vAxis.ticks > 0 then vAxis.ticks = vAxis.ticks - 1 end
    local cx, cy = I.cursorAxis()
    if math.abs(cx) > 0.05 or math.abs(cy) > 0.05 then I.anyInput = true end
    if I.anyInput then I.lastDevice = "pad"; I.lastPadTime = now end
end

function I.down(name) return cur[name] or false end
function I.pressed(name) return (cur[name] or false) and not (prev[name] or false) end
function I.released(name) return (prev[name] or false) and not (cur[name] or false) end
function I.repeated(name)
    if I.pressed(name) then return true end
    if cur[name] and repeatAt[name] and E.time >= repeatAt[name] then
        repeatAt[name] = E.time + E.settings.repeatRate
        return true
    end
    return false
end
function I.heldFor(name) if cur[name] and pressedAt[name] then return E.time - pressedAt[name] end return 0 end

function I.cursorAxis()
    if not E.native then return 0, 0 end
    local x, y, active, mode = Ensign.analog(resolve("cursor_move"))
    if not active then return 0, 0 end
    if mode == 4 or mode == 5 then return x, -y, true end   -- AbsoluteMouse / RelativeMouse deliver deltas
    return x, -y, false
end

function I.navDirection()
    if I.repeated("nav_up") then return "up" end
    if I.repeated("nav_down") then return "down" end
    if I.repeated("nav_left") then return "left" end
    if I.repeated("nav_right") then return "right" end
    return nil
end

-- test driver: press one action, or a physical button (every verb it carries)
function I.virtualPress(name, ticks)
    local verbs = I.BUTTONS[name]
    if verbs then for _, v in ipairs(verbs) do virtual[v] = ticks or 2 end
    else virtual[name] = ticks or 2 end
end

-- Fixed fallback glyphs per family, used when Steam has no binding to report
-- (or by the headless harness via `fakepad`).
local FALLBACK_BUTTON = {
    xbox = { a = "xbox_a", b = "xbox_b", x = "xbox_x", y = "xbox_y", lb = "xbox_lb", rb = "xbox_rb", lt = "xbox_lt", rt = "xbox_rt",
             start = "xbox_menu", view = "xbox_view", l3 = "stick_l_click", up = "dpad", nav_move = "stick_l", cursor_move = "stick_r" },
    ps = { a = "ps_cross", b = "ps_circle", x = "ps_square", y = "ps_triangle", lb = "ps_l1", rb = "ps_r1", lt = "ps_l2", rt = "ps_r2",
           start = "ps_options", view = "ps_share", l3 = "stick_l_click", up = "dpad", nav_move = "stick_l", cursor_move = "stick_r" },
    nin = { a = "nin_a", b = "nin_b", x = "nin_x", y = "nin_y", lb = "nin_l", rb = "nin_r", lt = "nin_zl", rt = "nin_zr",
            start = "nin_plus", view = "nin_minus", l3 = "stick_l_click", up = "dpad", nav_move = "stick_l", cursor_move = "stick_r" },
    deck = { a = "deck_a", b = "deck_b", x = "deck_x", y = "deck_y", lb = "deck_l1", rb = "deck_r1", lt = "deck_l2", rt = "deck_r2",
             start = "deck_menu", view = "deck_view", l3 = "stick_l_click", up = "dpad", nav_move = "stick_l", cursor_move = "pad_r" },
}
FALLBACK_BUTTON.steam = FALLBACK_BUTTON.deck   -- Steam Controllers use the Deck's face and shoulder glyphs
local verbButton = {}
for btn, verbs in pairs(I.BUTTONS) do for _, v in ipairs(verbs) do verbButton[v] = verbButton[v] or btn end end
verbButton.doors_open, verbButton.doors_close, verbButton.autofire, verbButton.pause, verbButton.menu_pause = "l4", "r4", "l5", "r5", "r5"

function I.glyph(name)
    if I.lastDevice == "kbd" then
        local btn = verbButton[name] or name
        return nil, I.KEY_NAMES[btn] or btn
    end
    if E.native and not I.fakeFamily then
        local o, text, glyph = Ensign.origin(resolve(name))
        if o then return glyph, text end
    end
    local family = I.fakeFamily
    if not family and E.native then local _, _, f = Ensign.controllerType(); family = f end
    local tab = FALLBACK_BUTTON[family or "xbox"] or FALLBACK_BUTTON.xbox
    local btn = verbButton[name] or name
    if (family == "deck" or family == "steam") and (btn == "l4" or btn == "r4" or btn == "l5" or btn == "r5") then return "deck_" .. btn, name end
    if btn == "r5" then btn = "l3" end   -- pads without back buttons carry pause on the stick click
    local g = tab[btn] or (btn == "down" or btn == "left" or btn == "right") and "dpad" or nil
    if g then return g, name end
    return nil
end

function I.register()
    if not E.native then return end
    local _, status = Ensign.registerActions({ sets = I.sets, digital = I.digital, analog = I.analog })
    E.log("Steam Input: " .. tostring(status))
    Ensign.setActionSet(I.currentSet)
end
