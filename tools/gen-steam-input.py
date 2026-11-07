#!/usr/bin/env python3
"""Regenerate steam_input/ensign_actions.vdf and steam_input/configs/*.vdf.

Everything is driven by the ACTIONS table below (action, title, default physical
inputs per controller).  Dependency-free; run:  python3 tools/gen-steam-input.py
After writing, the generated files are re-parsed with an order-preserving VDF
parser (duplicate keys kept) and cross-checked; a per-controller table is printed.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "steam_input")

# --------------------------------------------------------------------------
# Physical inputs (xbox names).  Each maps to (source, input name in group).
# Sources: diamond, LT, RT, switch, joystick, dpad, rstick, lpad, rpad
# --------------------------------------------------------------------------
PHYS = {
    "A": ("diamond", "button_A"), "B": ("diamond", "button_B"),
    "X": ("diamond", "button_X"), "Y": ("diamond", "button_Y"),
    "LT": ("LT", "edge"), "RT": ("RT", "edge"),
    "LB": ("switch", "left_bumper"), "RB": ("switch", "right_bumper"),
    "View": ("switch", "button_escape"), "Start": ("switch", "button_menu"),
    "DU": ("dpad", "dpad_north"), "DD": ("dpad", "dpad_south"),
    "DL": ("dpad", "dpad_west"), "DR": ("dpad", "dpad_east"),
    "LS": ("joystick", "click"), "RS": ("rstick", "click"),
    "RPAD": ("rpad", "click"),
    # Steam Deck back buttons (L4/R4 = upper, L5/R5 = lower; assignment unverified)
    "L4": ("switch", "button_back_left_upper"), "R4": ("switch", "button_back_right_upper"),
    "L5": ("switch", "button_back_left"), "R5": ("switch", "button_back_right"),
    # Steam Controller grips
    "GripL": ("switch", "button_back_left"), "GripR": ("switch", "button_back_right"),
}
# Input order inside each group (emission order)
INPUT_ORDER = {
    "diamond": ["button_A", "button_B", "button_X", "button_Y"],
    "switch": ["left_bumper", "right_bumper", "button_escape", "button_menu",
               "button_back_left_upper", "button_back_right_upper",
               "button_back_left", "button_back_right"],
    "dpad": ["dpad_north", "dpad_south", "dpad_west", "dpad_east"],
}

# Controller classes.  default key -> physical list used by that class.
# "base" applies everywhere; "deck"/"sc" add or override.
CONTROLLERS = [  # (controller_type, class)
    ("neptune", "deck"), ("steamcontroller_gordon", "sc"), ("xbox360", "pad"),
    ("xboxone", "pad"), ("xboxelite", "pad"), ("ps4", "pad"), ("ps5", "pad"),
    ("switch_pro", "pad"), ("generic", "pad"),
]

# (set, name, title, {class: [physical,...]})   class "*" = all classes
# Per-class lists replace the "*" list for that class if present.
IG, MN = "InGame", "Menus"
BUTTONS = [
    (IG, "nav_up", "Navigate up", {"*": ["DU"]}),
    (IG, "nav_down", "Navigate down", {"*": ["DD"]}),
    (IG, "nav_left", "Navigate left", {"*": ["DL"]}),
    (IG, "nav_right", "Navigate right", {"*": ["DR"]}),
    (IG, "group_prev", "Previous group", {"*": ["LB"]}),
    (IG, "group_next", "Next group", {"*": ["RB"]}),
    (IG, "group_crew", "Go to crew group", {}),
    (IG, "group_systems", "Go to power (systems) group", {}),
    (IG, "group_weapons", "Go to weapons group", {}),
    (IG, "group_drones", "Go to drones group", {}),
    (IG, "group_ship", "Go to ship group", {}),
    (IG, "group_enemy", "Go to enemy ship", {}),
    (IG, "room_open", "Room: open units & doors", {"*": ["A"]}),
    (IG, "room_send", "Room: send selected units", {"*": ["A"]}),
    (IG, "room_detail", "Room: show details", {"*": ["X"]}),
    (IG, "room_deselect_all", "Room: deselect all units", {"*": ["B"]}),
    (IG, "detail_toggle_unit", "Detail: select / deselect unit", {"*": ["A"]}),
    (IG, "detail_toggle_door", "Detail: open / close door", {"*": ["A"]}),
    (IG, "detail_back", "Detail: back", {"*": ["B"]}),
    (IG, "target_confirm", "Targeting: confirm", {"*": ["A"]}),
    (IG, "beam_point", "Beam: choose point", {"*": ["A"]}),
    (IG, "target_cancel", "Targeting: cancel", {"*": ["B"]}),
    (IG, "system_power_up", "System: add power", {"*": ["A", "RT"]}),
    (IG, "system_power_down", "System: remove power", {"*": ["B", "LT"]}),
    (IG, "system_off", "System: turn off", {"*": ["X"]}),
    (IG, "slot_toggle", "Weapon / drone: toggle power", {"*": ["A"]}),
    (IG, "slot_off", "Weapon / drone: turn off", {"*": ["B"]}),
    (IG, "slot_retarget", "Weapon / drone: re-target", {"*": ["X"]}),
    (IG, "crew_select", "Crew: select", {"*": ["A"]}),
    (IG, "crew_deselect_all", "Crew: deselect all", {"*": ["B"]}),
    (IG, "crew_reorder", "Crew: reorder", {"*": ["X"]}),
    (IG, "ui_select", "UI: select", {"*": ["A"]}),
    (IG, "ui_back", "UI: back", {"*": ["B"]}),
    (IG, "jump", "Jump (FTL jump)", {"*": ["Y"]}),
    (IG, "pause", "Pause", {"*": ["LS"], "deck": ["R5"], "sc": ["GripR"]}),
    (IG, "ship_screens", "Open ship screens (systems / crew / inventory)", {"*": ["Start"]}),
    (IG, "ship_inventory", "Open inventory", {"*": ["View"]}),
    (IG, "escape_menu", "Escape menu", {}),
    (IG, "autofire", "Toggle autofire", {"deck": ["L5"]}),
    (IG, "crew_all", "Select all crew", {"*": ["RS"], "deck": ["LS"], "sc": ["LS"]}),
    (IG, "doors_open", "Open all doors", {"deck": ["L4"], "sc": ["GripL"]}),
    (IG, "doors_close", "Close all doors", {"deck": ["R4"]}),
    (IG, "saved_positions", "Save crew positions", {}),
    (IG, "return_positions", "Return crew to saved positions", {}),
    (IG, "cursor_click", "Cursor click", {"deck": ["RPAD"], "sc": ["RPAD"]}),
    (IG, "cursor_rclick", "Cursor right click", {}),

    (MN, "menu_up", "Menu up", {"*": ["DU"]}),
    (MN, "menu_down", "Menu down", {"*": ["DD"]}),
    (MN, "menu_left", "Menu left", {"*": ["DL"]}),
    (MN, "menu_right", "Menu right", {"*": ["DR"]}),
    (MN, "menu_select", "Menu select", {"*": ["A"]}),
    (MN, "menu_pickup", "Menu pick up", {"*": ["A"]}),
    (MN, "menu_drop", "Menu drop", {"*": ["A"]}),
    (MN, "menu_back", "Menu back", {"*": ["B"]}),
    (MN, "menu_put_back", "Menu put back", {"*": ["B"]}),
    (MN, "menu_alt", "Menu secondary", {"*": ["X"]}),
    (MN, "menu_info", "Menu info", {"*": ["Y"]}),
    (MN, "menu_tab_prev", "Previous tab", {"*": ["LB"]}),
    (MN, "menu_tab_next", "Next tab", {"*": ["RB"]}),
    (MN, "menu_pause", "Menu pause", {"*": ["LS"], "deck": ["R5"], "sc": ["GripR"]}),
    (MN, "menu_escape", "Menu escape", {"*": ["Start", "View"]}),
    (MN, "menu_click", "Menu click", {"deck": ["RPAD"], "sc": ["RPAD"]}),
    (MN, "menu_rclick", "Menu right click", {}),
]
# (set, name, title, input_mode)
ANALOG = [
    (IG, "nav_move", "Navigate (stick / pad)", "joystick_move"),
    (IG, "cursor_move", "Free cursor", "absolute_mouse"),
    (MN, "menu_nav", "Menu navigation", "joystick_move"),
    (MN, "menu_cursor", "Menu cursor", "absolute_mouse"),
]
SETS = [(IG, "In Game"), (MN, "Menus")]
SET_ANALOG = {IG: ("nav_move", "cursor_move"), MN: ("menu_nav", "menu_cursor")}

# Group sources per class and set (order = group id order, ids continue across sets)
SRC_MODE = {"diamond": "four_buttons", "LT": "trigger", "RT": "trigger", "switch": "switches",
            "joystick": "joystick_move", "dpad": "dpad", "rstick": "absolute_mouse",
            "lpad": "joystick_move", "rpad": "absolute_mouse"}
SRC_PRESET = {"diamond": "button_diamond", "LT": "left_trigger", "RT": "right_trigger",
              "switch": "switch", "joystick": "joystick", "dpad": "dpad",
              "rstick": "right_joystick", "lpad": "left_trackpad", "rpad": "right_trackpad"}
LAYOUT = {  # class -> set -> [sources]
    "pad": {IG: ["diamond", "LT", "RT", "switch", "joystick", "dpad", "rstick"],
            MN: ["diamond", "switch", "joystick", "dpad", "rstick"]},
    "deck": {IG: ["diamond", "LT", "RT", "switch", "joystick", "dpad", "rstick", "lpad", "rpad"],
             MN: ["diamond", "switch", "joystick", "dpad", "rstick", "lpad", "rpad"]},
    # Steam Controller: left pad is a dpad group, right pad is the mouse group
    "sc": {IG: ["diamond", "LT", "RT", "switch", "joystick", "dpad", "rpad"],
           MN: ["diamond", "switch", "joystick", "dpad", "rpad"]},
}
# analog action attached to a source's group (per class)
ANALOG_SRC = {
    "pad": {"joystick": 0, "rstick": 1},
    "deck": {"joystick": 0, "rstick": 1, "lpad": 0, "rpad": 1},
    "sc": {"joystick": 0, "rpad": 1},
}


def phys_for(entry, cls):
    d = entry[3]
    return d[cls] if cls in d else d.get("*", [])


# --------------------------------------------------------------------------
# VDF emission
# --------------------------------------------------------------------------
def emit(items, depth=0, out=None):
    out = [] if out is None else out
    t = "\t" * depth
    for k, v in items:
        if isinstance(v, str):
            out.append('%s"%s"\t\t"%s"' % (t, k, v))
        else:
            out.append('%s"%s"' % (t, k))
            out.append(t + "{")
            emit(v, depth + 1, out)
            out.append(t + "}")
    return out


def actions_block(legacy=True):
    sets = []
    for s, _ in SETS:
        analog = [(n, [("title", "#Action_" + n), ("input_mode", m)])
                  for ss, n, _t, m in ANALOG if ss == s]
        buttons = [(n, "#Action_" + n) for ss, n, _t, _p in BUTTONS if ss == s]
        sets.append((s, [("title", "#Set_" + s)] + ([("legacy_set", "0")] if legacy else []) + [
                         ("StickPadGyro", analog), ("Button", buttons)]))
    return sets


def build_config(ctype, cls):
    titles = {n: t for _s, n, t, _p in BUTTONS}
    groups, presets, gid = [], [], 0
    for pid, (s, _) in enumerate(SETS):
        binds = {}  # (source, input) -> [(set, name)]
        for e in BUTTONS:
            if e[0] != s:
                continue
            for p in phys_for(e, cls):
                src, inp = PHYS[p]
                binds.setdefault((src, inp), []).append(e[1])
        used = {k for k in binds}
        sb = []
        for src in LAYOUT[cls][s]:
            inputs = []
            names = INPUT_ORDER.get(src)
            if names is None:
                names = sorted({i for (sr, i) in used if sr == src})
            for inp in names:
                acts = binds.get((src, inp))
                if not acts:
                    continue
                for a in acts:
                    assert "," not in titles[a], a
                inputs.append((inp, [("activators", [("Full_Press", [("bindings", [
                    ("binding", "game_action %s %s, %s" % (s, a, titles[a])) for a in acts
                ])])])]))
            g = [("id", str(gid)), ("mode", SRC_MODE[src]), ("inputs", inputs)]
            if src in ANALOG_SRC[cls]:
                g.append(("gameactions", [(s, SET_ANALOG[s][ANALOG_SRC[cls][src]])]))
            groups.append(("group", g))
            sb.append((str(gid), SRC_PRESET[src] + " active"))
            gid += 1
        presets.append(("preset", [("id", str(pid)), ("name", s), ("group_source_bindings", sb)]))
    top = [("version", "3"), ("revision", "1"),
           ("title", "Ensign default - " + ctype),
           ("description", "Default Ensign (FTL) controller layout"),
           ("controller_type", "controller_" + ctype),
           ("actions", actions_block())] + groups + presets + [("settings", [])]
    return [("controller_mappings", top)]


def build_manifest():
    cfgs = [("controller_" + c, [("0", [("path", "configs/controller_%s.vdf" % c)])])
            for c, _ in CONTROLLERS]
    loc = [("Set_" + s, t) for s, t in SETS]
    loc = [("Set_" + s, t) for s, t in SETS]
    for s, _ in SETS:
        loc += [("Action_" + n, t) for ss, n, t, _m in ANALOG if ss == s]
        loc += [("Action_" + n, t) for ss, n, t, _p in BUTTONS if ss == s]
    return [("Action Manifest", [("configurations", cfgs), ("actions", actions_block(False)),
                                 ("localization", [("english", loc)])])]


def write(path, tree):
    with open(path, "w") as f:
        f.write("\n".join(emit(tree)) + "\n")


# --------------------------------------------------------------------------
# Order-preserving parser + validation
# --------------------------------------------------------------------------
def parse(text):
    toks = re.findall(r'"((?:[^"\\]|\\.)*)"|([{}])', text)
    pos = 0

    def block():
        nonlocal pos
        items = []
        while pos < len(toks):
            s, br = toks[pos]
            if br == "}":
                pos += 1
                return items
            pos += 1
            k = s
            s2, br2 = toks[pos]
            if br2 == "{":
                pos += 1
                items.append((k, block()))
            else:
                pos += 1
                items.append((k, s2))
        return items
    return block()


def get(items, key):
    return [v for k, v in items if k == key]


def validate():
    errs = []
    man = parse(open(os.path.join(ROOT, "ensign_actions.vdf")).read())[0][1]
    mactions = get(man, "actions")[0]
    loc = dict(get(get(man, "localization")[0], "english")[0])
    # titles / localization
    refs = []

    def walk_titles(items):
        for k, v in items:
            if isinstance(v, str):
                if v.startswith("#"):
                    refs.append(v[1:])
            else:
                walk_titles(v)
    walk_titles(mactions)
    for r in refs:
        if r not in loc:
            errs.append("missing localization " + r)
    names = {}
    for sname, sitems in mactions:
        for sec in ("StickPadGyro", "Button"):
            for ent in get(sitems, sec)[0]:
                if ent[0] in names:
                    errs.append("duplicate action name " + ent[0])
                names[ent[0]] = sname
    if len(set(names)) != len(names):
        errs.append("names not unique")
    for _s, n, _t, _p in BUTTONS:
        if n not in names:
            errs.append("table action not in manifest " + n)
    table = {}
    for c, cls in CONTROLLERS:
        path = os.path.join(ROOT, "configs", "controller_%s.vdf" % c)
        cfg = parse(open(path).read())[0][1]
        if get(cfg, "controller_type") != ["controller_" + c]:
            errs.append(c + ": controller_type")
        if [(s, [x for x in v if x[0] != "legacy_set"]) for s, v in get(cfg, "actions")[0]] != mactions:
            errs.append(c + ": actions block differs from manifest")
        ids, rows, nb = [], {}, 0
        gmap = {}
        for g in get(cfg, "group"):
            gid = get(g, "id")[0]
            ids.append(gid)
            gmap[gid] = get(g, "mode")[0]
            for ga in get(g, "gameactions"):
                for s, a in ga:
                    if names.get(a) != s:
                        errs.append("%s: gameaction %s %s invalid" % (c, s, a))
            for inp, body in get(g, "inputs")[0]:
                for act in get(body, "activators")[0]:
                    for b in get(get(act[1], "bindings")[0], "binding"):
                        nb += 1
                        m = re.match(r"game_action (\w+) (\w+), (.*)$", b)
                        if not m or names.get(m.group(2)) != m.group(1):
                            errs.append("%s: bad binding %r" % (c, b))
                            continue
                        rows.setdefault("g%s %s" % (gid, inp), []).append(m.group(2))
        if len(ids) != len(set(ids)):
            errs.append(c + ": duplicate group ids")
        for p in get(cfg, "preset"):
            for gid, v in get(p, "group_source_bindings")[0]:
                if gid not in ids:
                    errs.append("%s: preset refs missing group %s" % (c, gid))
        table[c] = (nb, rows, gmap)
    return errs, table


def main():
    os.makedirs(os.path.join(ROOT, "configs"), exist_ok=True)
    write(os.path.join(ROOT, "ensign_actions.vdf"), build_manifest())
    for c, cls in CONTROLLERS:
        write(os.path.join(ROOT, "configs", "controller_%s.vdf" % c), build_config(c, cls))
    errs, table = validate()
    for c, (nb, rows, gmap) in table.items():
        print("== controller_%s: %d bindings, %d groups" % (c, nb, len(gmap)))
        for k, v in rows.items():
            print("  %-34s %s" % (k + " (" + gmap[k.split()[0][1:]] + ")", ", ".join(v)))
    print("ERRORS: %s" % (errs or "none"))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
