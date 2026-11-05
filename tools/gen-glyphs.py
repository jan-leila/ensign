#!/usr/bin/env python3
"""Generate controller glyph + UI PNGs for the ensign mod (FTL-style, flat, no AA blur).
Run from repo root:  nix develop -c python3 tools/gen-glyphs.py
Font: set GLYPH_FONT to a bold TTF (default: DejaVu Sans Bold via fc-match).
"""
import os, subprocess, sys, shutil
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "img", "ensign")
GL, UI = os.path.join(ROOT, "glyphs"), os.path.join(ROOT, "ui")

def find_font():
    f = os.environ.get("GLYPH_FONT")
    if f: return f
    try:
        out = subprocess.run(["fc-match", "-f", "%{file}", "DejaVu Sans:bold"], capture_output=True, text=True).stdout
        if out and os.path.exists(out): return out
    except Exception: pass
    sys.exit("set GLYPH_FONT=/path/to/DejaVuSans-Bold.ttf")
FONT = find_font()

# ---- op helpers (each returns a list of magick args that draws WHITE on the current image)
def canvas(w, h): return ["-size", f"{w}x{h}", "xc:none", "+antialias"]
def fillop(*d): return ["-fill", "white", "-stroke", "none"] + [x for s in d for x in ("-draw", s)]
def lineop(*d, w=1): return ["-fill", "none", "-stroke", "white", "-strokewidth", str(w)] + [x for s in d for x in ("-draw", s)]
def sub(w, h, ops): return ["("] + canvas(w, h) + ops + [")"]
def hollow(w, h, outer, inner, extra=()):
    """outer shape filled, inner shape erased"""
    return ["("] + canvas(w, h) + fillop(outer) + ["("] + canvas(w, h) + fillop(inner) + [")",
            "-compose", "DstOut", "-composite", ")", "-compose", "Over"]
def text(w, h, s, size, grav="center", off="+0+0", font=None):
    return sub(w, h, ["-fill", "white", "-stroke", "none", "-font", font or FONT, "-pointsize", str(size),
                      "-gravity", grav, "-annotate", off, s, "+gravity"])
def ring(w, h, cx, cy, ro, t=2):
    return hollow(w, h, f"circle {cx},{cy} {cx},{cy-ro}", f"circle {cx},{cy} {cx},{cy-ro+t}")
def rrect(w, h, x0, y0, x1, y1, r, t=2):
    if r == 0:
        return hollow(w, h, f"rectangle {x0},{y0} {x1},{y1}", f"rectangle {x0+t},{y0+t} {x1-t},{y1-t}")
    return hollow(w, h, f"roundrectangle {x0},{y0} {x1},{y1} {r},{r}",
                  f"roundrectangle {x0+t},{y0+t} {x1-t},{y1-t} {max(r-t,0)},{max(r-t,0)}")
def hl(w, h, x0, x1, y, t=2): return fillop(f"rectangle {x0},{y} {x1},{y+t-1}")

def build(path, w, h, ops):
    cmd = ["magick"] + canvas(w, h) + ops + ["-background", "none", "-flatten",
        "(", "+clone", "-channel", "A", "-morphology", "Dilate", "Square:1", "+channel",
        "-fill", "#141414", "-colorize", "100", "-channel", "A", "-evaluate", "Multiply", "0.85", "+channel", ")",
        "+swap", "-composite", "-define", "png:color-type=6", path]
    subprocess.run(cmd, check=True)

jobs = []
def glyph(name, ops, w=28, h=28, d=GL): jobs.append((os.path.join(d, name + ".png"), w, h, ops))
W = H = 28

# ---- face buttons
def face_letter(name, ch):
    glyph(name, ring(W, H, 13.5, 13.5, 12) + text(W, H, ch, 17, off="+0+0"))
for p in ("xbox", "nin", "deck"):
    for ch in "ABXY": face_letter(f"{p}_{ch.lower()}", ch)

def ps_symbol(kind):
    c = 13.5
    r = ring(W, H, c, c, 12)
    if kind == "cross":
        s = lineop("line 9,9 18,18", "line 18,9 9,18", w=2)
    elif kind == "circle":
        s = sub(W, H, []) and hollow(W, H, f"circle {c},{c} {c},{c-6}", f"circle {c},{c} {c},{c-4}")
    elif kind == "square":
        s = hollow(W, H, "rectangle 8,8 19,19", "rectangle 10,10 17,17")
    else:
        s = lineop("polyline 13.5,7.5 19.5,18.5 7.5,18.5 13.5,7.5", w=2)
    return r + s
for k in ("cross", "circle", "square", "triangle"): glyph(f"ps_{k}", ps_symbol(k))

# ---- shoulder / trigger
def shoulder(name, label):
    size = 12 if len(label) <= 2 else 10
    glyph(name, rrect(W, H, 1, 6, 26, 21, 4) + text(W, H, label, size, off="+0+0"))
for n, l in [("xbox_lb","LB"),("xbox_rb","RB"),("xbox_lt","LT"),("xbox_rt","RT"),
             ("ps_l1","L1"),("ps_r1","R1"),("ps_l2","L2"),("ps_r2","R2"),
             ("nin_l","L"),("nin_r","R"),("nin_zl","ZL"),("nin_zr","ZR"),
             ("deck_l1","L1"),("deck_r1","R1"),("deck_l2","L2"),("deck_r2","R2"),
             ("deck_l4","L4"),("deck_l5","L5"),("deck_r4","R4"),("deck_r5","R5")]:
    shoulder(n, l)

# ---- menu buttons
def lines3(): return hl(W, H, 8, 19, 9) + hl(W, H, 8, 19, 13) + hl(W, H, 8, 19, 17)
def views():
    return (hollow(W, H, "rectangle 7,8 16,16", "rectangle 8,9 15,15") +
            hollow(W, H, "rectangle 11,12 20,20", "rectangle 12,13 19,19"))
def menu_btn(name, sym): glyph(name, ring(W, H, 13.5, 13.5, 12) + sym)
menu_btn("xbox_menu", lines3()); menu_btn("xbox_view", views())
menu_btn("ps_options", lines3())
menu_btn("ps_share", lineop("line 9,14 18,9", "line 9,14 18,19", w=1) +
         fillop("circle 9,14 9,11.5", "circle 18,9 18,6.5", "circle 18,19 18,16.5"))
menu_btn("nin_plus", fillop("rectangle 8,13 19,14", "rectangle 13,8 14,19"))
menu_btn("nin_minus", fillop("rectangle 8,13 19,14"))
menu_btn("deck_menu", lines3()); menu_btn("deck_view", views())
menu_btn("steam", lineop("line 9,17 18,10", w=2) + fillop("circle 9,17 9,13.5", "circle 18,10 18,7.5"))

# ---- sticks
def stick(name, letter, click):
    t = 3 if click else 2
    r = ring(W, H, 11.5, 11.5, 11, t) + fillop("circle 11.5,11.5 11.5,8" if click else "circle 11.5,11.5 11.5,9")
    let = text(W, H, letter, 13, grav="southeast", off="+0+0")
    glyph(name, ["("] + canvas(W, H) + r + ["-background", "none", "-flatten", "("] + canvas(W, H) + let +
          ["-channel", "A", "-morphology", "Dilate", "Square:1", "+channel", ")",
           "-compose", "DstOut", "-composite", ")", "-compose", "Over"] + let)
for s in "lr":
    stick(f"stick_{s}", s.upper(), False); stick(f"stick_{s}_click", s.upper(), True)

# ---- dpad
CROSS = [(10,2),(17,2),(17,10),(25,10),(25,17),(17,17),(17,25),(10,25),(10,17),(2,17),(2,10),(10,10)]
def poly(pts): return "polygon " + " ".join(f"{x},{y}" for x, y in pts)
def dpad(name, arm):
    o = 2
    outer = [(x+o, y+o) for x, y in [(8,0),(17,0),(17,8),(25,8),(25,17),(17,17),(17,25),(8,25),(8,17),(0,17),(0,8),(8,8)]]
    o = 2
    # plus: 24 px, arm width 8 (centred at 8..15 within 0..23)
    pts = [(8,0),(15,0),(15,8),(23,8),(23,15),(15,15),(15,23),(8,23),(8,15),(0,15),(0,8),(8,8)]
    P = [(x+2, y+2) for x, y in pts]
    inner = [(8,0),(15,0),(15,8),(23,8),(23,15),(15,15),(15,23),(8,23),(8,15),(0,15),(0,8),(8,8)]
    ops = []
    # carve interior by drawing smaller cross (inset 2)
    ins = [(10,2),(13,2),(13,10),(21,10),(21,13),(13,13),(13,21),(10,21),(10,13),(2,13),(2,10),(10,10)]
    ins = [(x+2, y+2) for x, y in ins]
    ops = ["("] + canvas(W, H) + fillop(poly(P)) + ["("] + canvas(W, H) + fillop(poly(ins)) + [")",
           "-compose", "DstOut", "-composite", ")", "-compose", "Over"]
    arms = {"up": "rectangle 10,2 17,11", "down": "rectangle 10,16 17,25",
            "left": "rectangle 2,10 11,17", "right": "rectangle 16,10 25,17"}
    if arm: ops += fillop(arms[arm])
    glyph(name, ops)
dpad("dpad", None)
for a in ("up", "down", "left", "right"): dpad(f"dpad_{a}", a)

# ---- trackpads
def pad(name, click):
    ops = rrect(W, H, 3, 3, 24, 24, 4)
    if click:
        ops += fillop("circle 13.5,13.5 13.5,9")
    else:
        ops += fillop(*[f"rectangle {x},{y} {x+1},{y+1}" for x in (8, 13, 18) for y in (8, 13, 18)])
    glyph(name, ops)
for s in "lr": pad(f"pad_{s}", False); pad(f"pad_{s}_click", True)

# ---- misc
glyph("unknown", ring(W, H, 13.5, 13.5, 12) + text(W, H, "?", 17))
glyph("key", rrect(W, H, 2, 2, 25, 25, 5) + fillop("rectangle 5,22 22,23") + text(W, H, "K", 15, off="+0-1"))

# ---- UI pieces
def corner(name, flip_x, flip_y):
    ops = fillop("rectangle 1,1 9,2", "rectangle 1,1 2,9")
    if flip_x: ops += ["-flop"]
    if flip_y: ops += ["-flip"]
    glyph(name, ops, 10, 10, UI)
corner("corner_tl", False, False); corner("corner_tr", True, False)
corner("corner_bl", False, True); corner("corner_br", True, True)
glyph("marker_room", rrect(35, 35, 1, 1, 33, 33, 0), 35, 35, UI)
glyph("marker_crew", hollow(24, 24, "polygon 12,1 22,11.5 12,22 2,11.5", "polygon 12,4.5 18.5,11.5 12,18.5 5.5,11.5"), 24, 24, UI)

os.makedirs(GL, exist_ok=True); os.makedirs(UI, exist_ok=True)
with ThreadPoolExecutor(8) as ex:
    list(ex.map(lambda j: build(*j), jobs))
subprocess.run(["magick", "-size", "1x1", "xc:rgba(0,0,0,0.6)", "-define", "png:color-type=6",
                os.path.join(UI, "hud_bg.png")], check=True)

# contact sheet
files = sorted(os.path.join(GL, f) for f in os.listdir(GL)) + sorted(os.path.join(UI, f) for f in os.listdir(UI) if f != "hud_bg.png")
subprocess.run(["magick", "montage", "-background", "#3a3a3a", "-filter", "point", "-geometry", "56x56+8+8",
                "-tile", "12x", *files, os.path.join(os.path.dirname(os.path.dirname(ROOT)), "..", "docs", "glyph_contact_sheet.png")], check=True)
print(len(jobs) + 1, "files")
