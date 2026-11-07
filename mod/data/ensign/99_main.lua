-- 99_main.lua: wires everything to Hyperspace's events.
local E = ENSIGN

if not E.native then
    if log then log("[Ensign] native shim not loaded (ensign.amd64.so must be LD_PRELOADed before Hyperspace); controller support disabled") end
end

local lastTime = nil
local initialized = false

local function init()
    if initialized then return end
    initialized = true
    E.loadSettings()
    E.input.register()
    E.feedback.registerEvents()
    E.dev.init()
    E.log("Ensign " .. E.VERSION .. " ready; native " .. tostring(E.native and Ensign.version() or "none"))
end

local function tick()
    if not E.native then return end
    local now = Ensign.time()
    E.dt = lastTime and math.min(0.1, now - lastTime) or 0
    lastTime = now
    E.time = now
    E.frame = E.frame + 1
    if not initialized then init() end

    local screen = Ensign.screen()
    E.screen = screen
    E.input.setSet(screen == "game" and "InGame" or "Menus")
    E.input.update()
    E.dev.update()
    E.cursor.processQueue()

    -- hide the game's pointer while the controller drives a snapped selection
    pcall(function()
        local hide = E.input.connected and (E.input.lastDevice == "pad" or E.input.lastDevice == "kbd") and E.cursor.mode == "snap"
        if hide or E.mouseHidden then Hyperspace.Mouse.bHideMouse = hide end   -- the game may reset it each frame
        E.mouseHidden = hide
    end)

    -- keep the subsystem row clear of the hint strip (restored as soon as the hints hide)
    pcall(function()
        local lift = (E.hud.visible() or E.dev.active) and E.hud.SUBSYSTEM_LIFT or 0
        if E.dev.liftOverride then lift = E.dev.liftOverride end
        if lift ~= E.lastLift then Ensign.liftSubsystems(lift, E.hud.SUBSYSTEM_FRAME_DX, E.hud.SUBSYSTEM_FRAME_DY); E.lastLift = lift
        elseif lift ~= 0 then Ensign.liftSubsystems(lift, E.hud.SUBSYSTEM_FRAME_DX, E.hud.SUBSYSTEM_FRAME_DY) end
    end)

    if E.input.connected or E.dev.active then
        if screen == "game" then
            E.game.update()
            E.feedback.watch()
        elseif screen ~= "none" then
            E.menus.update(screen)
        end
    end
end

local function renderOverlay()
    if not E.native then return end
    if not (E.input.connected or E.dev.active) then return end
    local ok, err = pcall(function()
        if not E.hud.visible() and not E.dev.active then return end
        if E.screen == "game" then
            E.game.render()
            E.hud.drawPanelLabel(E.game.panelLabel())
            E.hud.drawHints(E.game.hint)
        elseif E.screen ~= "none" then
            E.menus.render()
            E.hud.drawHints(E.menus.hint)
        end
    end)
    if not ok then E.log("render error: " .. tostring(err)) end
end

-- real mouse movement hides the controller HUD
script.on_internal_event(Defines.InternalEvents.ON_MOUSE_MOVE, function(x, y, xrel, yrel, l, r, m)
    if not E.injecting and (xrel ~= 0 or yrel ~= 0) then E.input.lastDevice = "mouse" end
    return Defines.Chain.CONTINUE
end)

-- keyboard: the mapped keys drive the same verbs as the pad buttons
pcall(function()
    script.on_internal_event(Defines.InternalEvents.ON_KEY_DOWN, function(key)
        if E.input.onKey(key, true) then return Defines.Chain.PREEMPT end
        return Defines.Chain.CONTINUE
    end)
    script.on_internal_event(Defines.InternalEvents.ON_KEY_UP, function(key)
        if E.input.onKey(key, false) then return Defines.Chain.PREEMPT end
        return Defines.Chain.CONTINUE
    end)
end)

script.on_internal_event(Defines.InternalEvents.ON_TICK, function()
    local ok, err = pcall(tick)
    if not ok then
        E.errors = (E.errors or 0) + 1
        if E.errors < 20 then E.log("tick error: " .. tostring(err)) end
    end
end)

script.on_render_event(Defines.RenderEvents.MOUSE_CONTROL, function() end, renderOverlay)

script.on_load(function()
    E.log("scripts loaded (native=" .. tostring(E.native) .. ")")
end)
