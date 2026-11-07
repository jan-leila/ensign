-- 60_hud.lua: on-screen button hints in FTL's style (glyph + label strip) and
-- the active panel label. Hidden while the player uses the mouse.
local E = ENSIGN
local H = {}
E.hud = H

local FONT_SMALL = 10
local FONT_LABEL = 13
local colBg, colText

local function colors()
    if not colBg then
        colBg = Graphics.GL_Color(0, 0, 0, 0.55)
        colText = Graphics.GL_Color(1, 1, 1, 1)
    end
end

function H.visible()
    if E.settings.hud == 0 then return false end
    if not E.input.connected then return false end
    return E.input.lastDevice == "pad" or E.input.lastDevice == "kbd"
end

-- The strip sits at the bottom right. In flight the game's subsystem group is raised
-- by H.SUBSYSTEM_LIFT while the hints are visible so the two never overlap.
H.HINT_Y = 720 - 34
H.LABEL_Y = H.HINT_Y - 26
H.SUBSYSTEM_LIFT = 36
H.SUBSYSTEM_FRAME_DX, H.SUBSYSTEM_FRAME_DY = 13, 32  -- frame image offset from the group's anchor (calibrated)

-- Draw a row of [glyph] Label pairs, right-aligned at the bottom of the screen.
function H.drawHints(hints, y)
    if not hints or #hints == 0 then return end
    colors()
    local items = {}
    local total = 0
    for _, h in ipairs(hints) do
        local glyph, text = E.input.glyph(h[1])
        local tex = glyph and E.img("ensign/glyphs/" .. glyph .. ".png") or nil
        local label = h[2]
        local w = (tex and 28 or 0) + 4 + Graphics.freetype.easy_measureWidth(FONT_SMALL, label) + 14
        if not tex then
            label = "[" .. (text or "?") .. "] " .. label
            w = Graphics.freetype.easy_measureWidth(FONT_SMALL, label) + 14
        end
        items[#items + 1] = { tex = tex, label = label, w = w }
        total = total + w
    end
    local x = 1280 - 8 - total
    y = y or H.HINT_Y
    Graphics.CSurface.GL_DrawRect(x - 6, y - 4, total + 12, 30, colBg)
    for _, it in ipairs(items) do
        local cx = x
        if it.tex then
            Graphics.CSurface.GL_BlitImage(it.tex, cx, y - 3, 28, 28, 0, colText, false)
            cx = cx + 32
        end
        Graphics.freetype.easy_print(FONT_SMALL, cx, y + 4, it.label)
        x = x + it.w
    end
end

function H.drawPanelLabel(text)
    if not text or text == "" then return end
    colors()
    local w = Graphics.freetype.easy_measureWidth(FONT_LABEL, text) + 16
    local x, y = 1280 - 8 - w, H.LABEL_Y
    Graphics.CSurface.GL_DrawRect(x, y, w, 22, colBg)
    Graphics.freetype.easy_print(FONT_LABEL, x + 8, y + 3, text)
end

function H.drawStatus(text)
    colors()
    Graphics.freetype.easy_print(FONT_SMALL, 8, 720 - 18, text)
end
