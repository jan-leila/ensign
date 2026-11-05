-- 40_menus.lua: controller handling for every non-combat screen (main menu, hangar,
-- options, events, store, ship screens, star map, dialogs). The native side
-- enumerates the clickable rectangles; this module navigates and clicks them.
local E = ENSIGN
local M = {}
E.menus = M
local I, C, N = nil, nil, nil

M.hits = {}
M.screen = "none"
M.lastScreen = "none"
M.hint = {}

local function kinds(...)
    local t = {}
    for _, k in ipairs({ ... }) do t[k] = true end
    return t
end

-- Which hits are navigable on each screen (nil = all)
local navigable = {
    starmap = kinds("location", "button", "close", "sector"),
}

local function clickFocus(button, opts)
    if C.mode == "free" or not C.focus then
        C.click(button, opts)
    else
        C.snapTo(C.focus)
        C.click(button, opts)
    end
end

local function cycleTabs(dir)
    local tabs = N.filterKind(M.hits, kinds("tab"))
    if #tabs == 0 then return false end
    table.sort(tabs, function(a, b) return a.x < b.x end)
    local idx = 1
    for i, t in ipairs(tabs) do if C.focus and E.sameHit(t, C.focus) then idx = i end end
    -- prefer the currently selected tab (extra = currentTab for tabbed windows)
    local cur = tabs[1].extra
    for i, t in ipairs(tabs) do if t.id == cur then idx = i end end
    idx = idx + dir
    if idx < 1 then idx = #tabs elseif idx > #tabs then idx = 1 end
    C.snapTo(tabs[idx])
    C.click(1)
    return true
end

local function findHit(kind, id)
    for _, h in ipairs(M.hits) do if h.kind == kind and (id == nil or h.id == id) then return h end end
    return nil
end

function M.update(screen)
    I, C, N = E.input, E.cursor, E.nav
    M.screen = screen
    M.hits = Ensign.hitboxes()
    local filter = navigable[screen]
    local cands = filter and N.filterKind(M.hits, filter) or M.hits
    if screen ~= M.lastScreen then
        -- new screen: focus the most sensible default
        C.focus = nil
        M.lastScreen = screen
        local def = findHit("confirm_yes") or findHit("choice", 0) or findHit("location") or findHit("button", 0)
        if def and screen ~= "starmap" then C.snapTo(def) end
        if screen == "starmap" then
            -- start on the beacon we are at
            for _, h in ipairs(cands) do if h.kind == "location" and h.extra % 2 == 1 then C.snapTo(h) end end
        end
    else
        C.focus = N.refresh(C.focus, cands)
        if not C.focus and C.mode == "snap" and #cands > 0 then C.snapTo(N.nearest(C.x, C.y, cands)) end
    end

    -- analog cursor
    C.updateFree()

    local dir = I.navDirection()
    if dir then
        local from = C.focus or { x = C.x - 1, y = C.y - 1, w = 2, h = 2, kind = "_cursor", id = -1 }
        local nxt = N.pick(from, cands, dir, function(h) return h.enabled ~= false end)
        if not nxt and not C.focus then nxt = N.nearest(C.x, C.y, cands) end
        if nxt then
            C.mode = "snap"
            C.snapTo(nxt)
            E.feedback.tick()
        end
    end

    if I.pressed("select") or I.pressed("cursor_click") then
        if screen == "rename" or screen == "input" then
            C.key(E.KEY.RETURN)
        elseif screen == "starmap" and C.focus and C.focus.kind == "location" and M.lastLocation and E.sameHit(C.focus, M.lastLocation) then
            -- second press on the same beacon: jump
            local jb = findHit("button", 1)
            if jb then C.snapTo(jb); C.click(1); C.snapTo(C.focus) end
        else
            clickFocus(1)
            if screen == "starmap" and C.focus and C.focus.kind == "location" then M.lastLocation = C.focus end
        end
    end
    if I.pressed("alt") or I.pressed("cursor_rclick") then clickFocus(3) end
    if I.pressed("back") then
        if screen == "confirm" then
            local no = findHit("confirm_no")
            if no then C.snapTo(no); C.click(1) end
        elseif screen == "mainmenu" then -- luacheck: ignore 542
        elseif screen == "credits" then
            C.click(1)
        elseif screen == "shipbuilder" then
            local b = findHit("button", 2)  -- "back" to the main menu
            if b then C.snapTo(b); C.click(1) else C.key(E.KEY.ESC) end
        elseif screen == "starmap" then
            local cl = findHit("close")
            if cl then C.snapTo(cl); C.click(1) else C.key(E.KEY.ESC) end
        elseif screen == "store" or screen == "shipscreens" then
            local cl = findHit("close", 200) or findHit("close")
            if cl then C.snapTo(cl); C.click(1) else C.key(E.KEY.ESC) end
        else
            C.key(E.KEY.ESC)
        end
    end
    if I.pressed("panel_prev") then cycleTabs(-1) end
    if I.pressed("panel_next") then cycleTabs(1) end
    if I.pressed("game_menu") then C.key(E.KEY.ESC) end
    if I.pressed("pause") and screen == "starmap" then
        local wait = findHit("button", 2)
        if wait then C.snapTo(wait); C.click(1) end
    end
    if I.pressed("jump") and screen == "starmap" then
        local jb = findHit("button", 1)
        if jb then C.snapTo(jb); C.click(1) end
    end
    if I.pressed("info") and screen == "starmap" then
        local d = findHit("button", 3)
        if d then C.snapTo(d); C.click(1) end
    end

    -- HUD hints
    local hint = { { "nav_up", "Navigate" }, { "select", "Select" } }
    if screen == "confirm" then hint[#hint + 1] = { "back", "No" }
    elseif screen == "starmap" then
        hint[#hint + 1] = { "jump", "Jump" }; hint[#hint + 1] = { "pause", "Wait" }; hint[#hint + 1] = { "back", "Close map" }
    elseif screen == "store" or screen == "shipscreens" then
        hint[#hint + 1] = { "panel_next", "Tab" }; hint[#hint + 1] = { "alt", "Alt" }; hint[#hint + 1] = { "back", "Close" }
    elseif screen == "options" or screen == "pausemenu" or screen == "scores" then
        hint[#hint + 1] = { "back", "Close" }
    elseif screen == "rename" or screen == "input" then
        hint = { { "select", "Confirm" }, { "back", "Cancel" } }
    elseif screen == "shipbuilder" or screen == "shipselect" then
        hint[#hint + 1] = { "panel_next", "Type" }; hint[#hint + 1] = { "back", "Back" }
    end
    M.hint = hint
end

function M.render()
    if C.mode == "snap" and C.focus then
        C.drawFrame(C.focus)
    end
end
