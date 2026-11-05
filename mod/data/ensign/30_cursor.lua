-- 30_cursor.lua: the virtual cursor. The game's own pointer follows it because
-- every move is injected as a real mouse move, so hover states, tooltips and
-- aiming previews behave exactly as with a mouse.
local E = ENSIGN
local C = {}
E.cursor = C

C.x, C.y = 640, 360
C.mode = "snap"          -- "snap": jumps between hits; "free": analog/trackpad driven
C.focus = nil            -- current snapped hit
C.visible = false
C.shiftHeld = false
local queue = {}         -- pending click phases
local lastSent = { x = -1, y = -1 }
local freeAccum = { x = 0, y = 0 }

function C.sync(force)
    if not E.native then return end
    if force or lastSent.x ~= C.x or lastSent.y ~= C.y then
        E.injecting = true
        Ensign.mouseMove(math.floor(C.x), math.floor(C.y))
        E.injecting = false
        lastSent.x, lastSent.y = C.x, C.y
    end
end

function C.moveTo(x, y)
    C.x = E.clamp(x, 0, 1279)
    C.y = E.clamp(y, 0, 719)
    C.sync()
end

function C.snapTo(hit)
    C.focus = hit
    if hit then
        local cx, cy = E.center(hit)
        C.moveTo(cx, cy)
    end
end

-- Queue a click at the current cursor position: button down now, up next tick.
-- opts.shift holds Shift around the click (multi-select), opts.hold keeps the button down.
function C.click(button, opts)
    button = button or 1
    opts = opts or {}
    queue[#queue + 1] = { button = button, shift = opts.shift, phase = 0 }
end

function C.processQueue()
    if not E.native then queue = {} return end
    local q = queue[1]
    if not q then return end
    E.injecting = true
    if q.phase == 0 then
        if q.shift then Ensign.keyDown(E.KEY.LSHIFT) end
        C.sync(true)
        Ensign.mouseDown(q.button)
        q.phase = 1
    else
        Ensign.mouseUp(q.button)
        if q.shift then Ensign.keyUp(E.KEY.LSHIFT) end
        table.remove(queue, 1)
    end
    E.injecting = false
end

function C.key(k)
    if not E.native or not k then return end
    E.injecting = true
    Ensign.keyDown(k)
    Ensign.keyUp(k)
    E.injecting = false
end

-- Free movement from the analog axis. Returns true if the cursor moved.
function C.updateFree()
    local ax, ay, isDelta = E.input.cursorAxis()
    if ax == 0 and ay == 0 then return false end
    local dx, dy
    if isDelta then
        dx, dy = ax, ay                      -- trackpad / mouse-like: pixels per frame
    else
        local mag = math.sqrt(ax * ax + ay * ay)
        if mag < 0.12 then return false end
        local curve = mag * mag              -- fine control near the centre
        local speed = E.settings.cursorSpeed * curve * E.dt
        dx, dy = ax / mag * speed, ay / mag * speed
    end
    freeAccum.x = freeAccum.x + dx
    freeAccum.y = freeAccum.y + dy
    local ix, iy = math.floor(freeAccum.x), math.floor(freeAccum.y)
    if ix == 0 and iy == 0 then return false end
    freeAccum.x, freeAccum.y = freeAccum.x - ix, freeAccum.y - iy
    C.mode = "free"
    C.focus = nil
    C.moveTo(C.x + ix, C.y + iy)
    return true
end

-- Drawing: FTL-style bracket frame around the focused hit.
local tex = {}
local function img(name)
    if tex[name] == nil then
        local ok, t = pcall(function() return Hyperspace.Resources:GetImageId(name) end)
        tex[name] = ok and t or false
    end
    return tex[name] or nil
end
E.img = img

local WHITE = nil
function C.drawFrame(h, color, pad)
    if not h then return end
    pad = pad or 3
    WHITE = WHITE or Graphics.GL_Color(1, 1, 1, 1)
    color = color or WHITE
    local x, y, w, hh = h.x - pad, h.y - pad, h.w + pad * 2, h.h + pad * 2
    local tl, tr, bl, br = img("img/ensign/ui/corner_tl.png"), img("img/ensign/ui/corner_tr.png"),
                           img("img/ensign/ui/corner_bl.png"), img("img/ensign/ui/corner_br.png")
    if tl and tr and bl and br then
        local B = Graphics.CSurface.GL_BlitImage
        B(tl, x, y, 10, 10, 0, color, false)
        B(tr, x + w - 10, y, 10, 10, 0, color, false)
        B(bl, x, y + hh - 10, 10, 10, 0, color, false)
        B(br, x + w - 10, y + hh - 10, 10, 10, 0, color, false)
    else
        Graphics.CSurface.GL_DrawRectOutline(x, y, w, hh, color, 2)
    end
end
