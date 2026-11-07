-- Ensign: controller support for FTL (Hyperspace Lua side).
-- 00_core.lua: shared namespace, settings, small utilities.
-- All Ensign scripts run in one global environment (Hyperspace has no `require`),
-- so everything lives under the ENSIGN table.

ENSIGN = ENSIGN or {}
local E = ENSIGN
E.VERSION = "0.1.0"
E.native = (type(Ensign) == "table")      -- the native shim registered its table
E.enabled = E.native

function E.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local msg = table.concat(parts, " ")
    if E.native then Ensign.log(msg) end
    if log then log("[Ensign] " .. msg) end
end

-- Settings (persisted in the Hyperspace profile via metaVariables when available).
E.settings = {
    rumble = 1,          -- 0..1 strength multiplier
    haptics = 1,         -- trackpad/Deck haptic ticks
    cursorSpeed = 900,   -- free-cursor pixels/second at full deflection
    hud = 1,             -- show button hints
    repeatDelay = 0.35,  -- seconds before auto-repeat of nav input
    setSwitchGuard = 0.3, -- seconds after an action-set switch during which held-over buttons are ignored
    repeatRate = 0.09,   -- seconds between repeats
}

local function metaGet(key, default)
    local ok, v = pcall(function() return Hyperspace.metaVariables[key] end)
    if ok and v ~= nil and v ~= 0 then return v end
    return default
end
local function metaSet(key, value)
    pcall(function() Hyperspace.metaVariables[key] = value end)
end

function E.loadSettings()
    local s = E.settings
    s.rumble = metaGet("ensign_rumble_pct", 100) / 100
    s.haptics = metaGet("ensign_haptics", 1) == 1 and 1 or 0
    s.hud = metaGet("ensign_hud", 1) == 1 and 1 or 0
    s.cursorSpeed = metaGet("ensign_cursor_speed", 900)
end
function E.saveSettings()
    local s = E.settings
    metaSet("ensign_rumble_pct", math.floor(s.rumble * 100))
    metaSet("ensign_haptics", s.haptics)
    metaSet("ensign_hud", s.hud)
    metaSet("ensign_cursor_speed", s.cursorSpeed)
end

-- Geometry helpers
function E.center(h) return h.x + h.w / 2, h.y + h.h / 2 end
function E.contains(h, x, y) return x >= h.x and y >= h.y and x < h.x + h.w and y < h.y + h.h end
function E.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
-- `extra` identifies the hit only for these kinds; elsewhere it carries changing state.
E.identityKinds = { room = true, armament = true, door = true }
function E.sameHit(a, b)
    if not (a and b) or a.kind ~= b.kind or a.id ~= b.id then return false end
    if E.identityKinds[a.kind] then return a.extra == b.extra end
    return true
end

-- Hotkeys: respect the player's own keybindings from settings.ini.
local keyCache = {}
function E.hotkey(name, fallback)
    if keyCache[name] then return keyCache[name] end
    local ok, k = pcall(function() return Hyperspace.Settings:GetHotkey(name) end)
    if ok and k and k ~= 0 then keyCache[name] = k return k end
    return fallback
end
E.KEY = { ESC = 27, RETURN = 13, SPACE = 32, LSHIFT = 304, LCTRL = 306, TAB = 9,
          UP = 273, DOWN = 274, RIGHT = 275, LEFT = 276 }

-- Safe accessors into the game
function E.app() return Hyperspace.App end
function E.gui()
    local ok, g = pcall(function() return Hyperspace.App.gui end)
    if ok then return g end
    return nil
end
function E.playerShip()
    local ok, s = pcall(function() return Hyperspace.ships.player end)
    if ok then return s end
    return nil
end
function E.enemyShip()
    local ok, s = pcall(function() return Hyperspace.ships.enemy end)
    if ok then return s end
    return nil
end

E.time = 0          -- seconds, updated every tick
E.dt = 0
E.frame = 0
