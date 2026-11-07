#include <map>
#include <climits>
#include "game.h"
#include "log.h"
#include "ftl_structs_elf64.h"
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>

namespace {

CApp** p_cApp = nullptr;
typedef void (*MouseMoveFn)(CApp*, int, int, int, int, bool, bool, bool);
typedef void (*MouseBtnFn)(CApp*, int, int);
typedef void (*KeyFn)(CApp*, int);
MouseMoveFn f_mouseMove = nullptr;
MouseBtnFn f_lDown = nullptr, f_lUp = nullptr, f_rDown = nullptr, f_rUp = nullptr, f_mDown = nullptr;
KeyFn f_keyDown = nullptr, f_keyUp = nullptr, f_textInput = nullptr;
bool g_resolved = false;

int g_rawX = 0, g_rawY = 0;
bool g_holdL = false, g_holdR = false, g_holdM = false;

template <class V> size_t vsize(const V& v) {
    if (!v._start || !v._finish || v._finish < v._start) return 0;
    size_t n = (size_t)(v._finish - v._start);
    return n > 4096 ? 0 : n;   // garbage guard
}
// FocusWindow::bOpen may be uninitialized memory before a window is ever used; only 1 means open.
inline bool is_open(const FocusWindow& w) { return *(const unsigned char*)&w.bOpen == 1; }
inline bool is_open(const ChoiceBox& c) { return is_open(c._base); }
inline bool is_open(const ConfirmWindow& c) { return is_open(c._base); }
inline bool is_open(const TabbedWindow& t) { return is_open(t._base); }
inline bool sane_ptr(const void* p) { return (uintptr_t)p > 0x10000 && (uintptr_t)p < 0x800000000000ull; }

const char* cstr(const std__string& s) { return sane_ptr(s.string) ? s.string : ""; }
const char* cstr(const TextString& t) { return cstr(t.data); }

CApp* app() { return (p_cApp && *p_cApp) ? *p_cApp : nullptr; }

// ---- CommandGui tail calibration --------------------------------------------
// The IDA layout of `Upgrades` is 8 bytes larger than the real object, so every
// CommandGui member after `upgradeScreen` sits earlier than the header says.
// The ship-screens TabbedWindow holds real pointers to crewScreen/equipScreen,
// which lets us measure the shift at runtime instead of trusting the header.
static long gui_tail_delta(CommandGui* gui) {
    static long cached = 0;
    static CommandGui* cachedFor = nullptr;
    if (gui == cachedFor) return cached;
    if (vsize(gui->shipScreens.windows) >= 2 && gui->shipScreens.windows._start[1]) {
        long d = (char*)gui->shipScreens.windows._start[1] - (char*)&gui->crewScreen;
        if (d > -64 && d < 64) { cached = d; cachedFor = gui; ensign::logf("CommandGui tail delta measured: %ld bytes", d); }
    }
    return cached;
}
template <class T> static T* tail(CommandGui* gui, T* p) { return (T*)((char*)p + gui_tail_delta(gui)); }
#define GUI_TAIL(gui, member) (*tail(gui, &(gui)->member))

// Hyperspace keeps the upgrade boxes in its own paged container (CustomUpgrades).
// Mirror of the relevant part of Hyperspace 1.23's layout; validated at runtime
// by checking that `orig` points at the game's Upgrades screen.
struct HS_UpgradeBoxSet {
    std::vector<std::vector<UpgradeBox*>> boxes;
    void* leftButton; void* rightButton;
    int currentPage;
    Upgrades* orig;
};
struct HS_CustomUpgrades {
    Upgrades* orig; void* renameInput; bool allowRename; bool allowButton;
    HS_UpgradeBoxSet systemBoxes;
    HS_UpgradeBoxSet subSystemBoxes;
    void* renameButton;
};
static HS_CustomUpgrades* hs_custom_upgrades() {
    static HS_CustomUpgrades* p = (HS_CustomUpgrades*)dlsym(RTLD_DEFAULT, "_ZN14CustomUpgrades8instanceE");
    return p;
}


void add_rect(std::vector<game::Hit>& out, const char* kind, int id, int x, int y, int w, int h,
              const std::string& label = "", bool enabled = true, int extra = 0) {
    if (w <= 0 || h <= 0 || w > 1400 || h > 800 || x < -200 || y < -200 || x > 1500 || y > 900) return;
    game::Hit hit; hit.kind = kind; hit.id = id; hit.x = x; hit.y = y; hit.w = w; hit.h = h;
    hit.label = label; hit.enabled = enabled; hit.extra = extra;
    out.push_back(std::move(hit));
}
void add_button(std::vector<game::Hit>& out, const GenericButton& b, const char* kind, int id,
                const std::string& label = "", int extra = 0) {
    add_rect(out, kind, id, b.hitbox.x, b.hitbox.y, b.hitbox.w, b.hitbox.h, label, b.bActive, extra);
}
// Image buttons whose hitbox was never filled in: fall back to position + image size.
void add_imgbutton(std::vector<game::Hit>& out, const Button& b, const char* kind, int id,
                   const std::string& label = "", int extra = 0) {
    const GenericButton& g = b._base;
    if (g.hitbox.w > 0 && g.hitbox.w < 1400 && g.hitbox.h > 0 && g.hitbox.h < 800 && g.hitbox.x >= 0 && g.hitbox.x < 1280) {
        add_rect(out, kind, id, g.hitbox.x, g.hitbox.y, g.hitbox.w, g.hitbox.h, label, true, extra);
        return;
    }
    int w = b.imageSize.x, h = b.imageSize.y;
    if (w <= 0 || w > 600 || h <= 0 || h > 400) { w = 24; h = 24; }
    add_rect(out, kind, id, g.position.x, g.position.y, w, h, label, true, extra);
}
void add_textbutton(std::vector<game::Hit>& out, const TextButton& b, const char* kind, int id, int extra = 0) {
    add_button(out, b._base, kind, id, cstr(b.label), extra);
}
void add_confirm(std::vector<game::Hit>& out, const ConfirmWindow& c) {
    add_textbutton(out, c.yesButton, "confirm_yes", 0);
    add_textbutton(out, c.noButton, "confirm_no", 1);
}
void add_choicebox(std::vector<game::Hit>& out, const ChoiceBox& cb) {
    size_t n = vsize(cb.choiceBoxes);
    size_t nt = vsize(cb.choices);
    for (size_t i = 0; i < n; i++) {
        const Globals__Rect& r = cb.choiceBoxes._start[i];
        std::string label = i < nt ? cstr(cb.choices._start[i].text) : "";
        add_rect(out, "choice", (int)i, r.x, r.y, r.w, r.h, label, true, cb.selectedChoice);
    }
}
void add_equipment_boxes(std::vector<game::Hit>& out, const std__vector_14EquipmentBoxZ1& v, const char* kind) {
    size_t n = vsize(v);
    for (size_t i = 0; i < n; i++) {
        EquipmentBox* b = v._start[i];
        if (!b) continue;
        const Globals__Rect& r = b->hitBox;
        bool empty = !b->item.pWeapon && !b->item.pDrone && !b->item.pCrew && !b->item.augment;
        if (b->slot < 0) continue;
        add_rect(out, kind, (int)i, r.x, r.y, r.w, r.h, empty ? "empty" : "item", !b->bBlocked, b->slot);
    }
}
void add_options(std::vector<game::Hit>& out, const OptionsScreen& o) {
    if (is_open(o.wipeProfileDialog._base)) { add_confirm(out, o.wipeProfileDialog); return; }
    if (is_open(o.restartRequiredDialog._base)) { add_choicebox(out, o.restartRequiredDialog); return; }
    if (o.bCustomizeControls) {
        const ControlsScreen& c = o.controls;
        if (is_open(c.resetDialog._base)) { add_confirm(out, c.resetDialog); return; }
        int page = c.currentPage;
        if (page >= 0 && page < 4) {
            size_t n = vsize(c.buttons[page]);
            for (size_t i = 0; i < n; i++) {
                const ControlButton& b = c.buttons[page]._start[i];
                add_rect(out, "control", (int)i, b.rect.x, b.rect.y, b.rect.w, b.rect.h, cstr(b.desc), true, page);
            }
        }
        for (int i = 0; i < 4; i++) add_button(out, c.pageButtons[i]._base, "tab", i, "page");
        add_textbutton(out, c.defaultButton, "button", 100);
        add_textbutton(out, o.closeButton, "close", 101);
        return;
    }
    add_choicebox(out, o._base);
    add_rect(out, "slider", 0, o.soundVolume.box.x, o.soundVolume.box.y, o.soundVolume.box.w, o.soundVolume.box.h, "sound");
    add_rect(out, "slider", 1, o.musicVolume.box.x, o.musicVolume.box.y, o.musicVolume.box.w, o.musicVolume.box.h, "music");
    add_textbutton(out, o.closeButton, "close", 101);
    if (o.showWipeButton) add_textbutton(out, o.wipeProfileButton, "button", 102);
    add_textbutton(out, o.steamAdditions.syncAchievementsButton, "button", 103);
}

bool store_window(CommandGui* gui, Store*& storeOut) {
    const TabbedWindow& tw = gui->storeScreens;
    size_t n = vsize(tw.windows);
    for (size_t i = 0; i < n; i++) {
        FocusWindow* w = tw.windows._start[i];
        if (w && w != (FocusWindow*)tail(gui, &gui->equipScreen) && w != (FocusWindow*)&gui->upgradeScreen &&
            w != (FocusWindow*)tail(gui, &gui->crewScreen)) { storeOut = (Store*)w; return true; }
    }
    return false;
}

void add_store(std::vector<game::Hit>& out, CommandGui* gui) {
    const TabbedWindow& tw = gui->storeScreens;
    Store* st = nullptr;
    if (store_window(gui, st) && is_open(st->confirmDialog._base)) { add_confirm(out, st->confirmDialog); return; }
    size_t nb = vsize(tw.buttons);
    for (size_t i = 0; i < nb; i++) if (tw.buttons._start[i]) add_button(out, tw.buttons._start[i]->_base, "tab", (int)i, "", (int)tw.currentTab);
    add_textbutton(out, tw.doneButton, "close", 200);
    FocusWindow* cur = (tw.currentTab < vsize(tw.windows)) ? tw.windows._start[tw.currentTab] : nullptr;
    Equipment& eq = GUI_TAIL(gui, equipScreen);
    if (cur == (FocusWindow*)&eq || cur == nullptr) {
        add_equipment_boxes(out, eq.vEquipmentBoxes, "equip");
    }
    if (st && (cur == (FocusWindow*)st || cur == nullptr)) {
        // sections hold 3 boxes each; page 1 shows sections 0-1, page 2 sections 2-3.
        // The resource / repair boxes follow the section boxes and are always visible.
        size_t n = vsize(st->vStoreBoxes);
        int sections = st->sectionCount;
        int firstSection = st->bShowPage2 ? 2 : 0;
        for (size_t i = 0; i < n; i++) {
            StoreBox* b = st->vStoreBoxes._start[i];
            if (!b) continue;
            int section = (sections > 0 && (int)i < sections * 3) ? (int)i / 3 : -1;
            if (section >= 0 && (section < firstSection || section >= firstSection + 2)) continue;
            add_button(out, b->button._base, "store", (int)i, section >= 0 ? "stock" : "resource", b->count);
        }
        n = vsize(st->vItemBoxes);
        for (size_t i = 0; i < n; i++) {
            StoreBox* b = st->vItemBoxes._start[i];
            if (!b) continue;
            add_button(out, b->button._base, "storeitem", (int)i, "", b->count);
        }
        if (sections > 2) {   // the page buttons only exist with more than two sections
            add_button(out, st->page1._base, "tab", 10, "page1");
            add_button(out, st->page2._base, "tab", 11, "page2");
        }
        add_button(out, st->exitButton._base, "close", 201);
    }
}

void add_ship_screens(std::vector<game::Hit>& out, CommandGui* gui) {
    const TabbedWindow& tw = gui->shipScreens;
    CrewManifest& cm = GUI_TAIL(gui, crewScreen);
    Equipment& eq = GUI_TAIL(gui, equipScreen);
    if (is_open(cm.deleteDialog._base)) { add_confirm(out, cm.deleteDialog); return; }
    size_t nb = vsize(tw.buttons);
    for (size_t i = 0; i < nb; i++) if (tw.buttons._start[i]) add_button(out, tw.buttons._start[i]->_base, "tab", (int)i, "", (int)tw.currentTab);
    add_textbutton(out, tw.doneButton, "close", 200);
    FocusWindow* cur = (tw.currentTab < vsize(tw.windows)) ? tw.windows._start[tw.currentTab] : nullptr;
    if (cur == (FocusWindow*)&gui->upgradeScreen) {
        const Upgrades& up = gui->upgradeScreen;
        int added = 0;
        HS_CustomUpgrades* cu = hs_custom_upgrades();
        if (cu && cu->orig == &gui->upgradeScreen) {
            const HS_UpgradeBoxSet* sets[2] = { &cu->systemBoxes, &cu->subSystemBoxes };
            for (int s = 0; s < 2; s++) {
                const HS_UpgradeBoxSet& set = *sets[s];
                if (set.currentPage < 0 || (size_t)set.currentPage >= set.boxes.size()) continue;
                for (UpgradeBox* b : set.boxes[set.currentPage]) {
                    if (!sane_ptr(b) || b->isDummy) continue;
                    const GenericButton& gb = b->boxButton._base;
                    if (gb.hitbox.w > 0 && gb.hitbox.h > 0) add_rect(out, "upgrade", added, gb.hitbox.x, gb.hitbox.y, gb.hitbox.w, gb.hitbox.h, b->system ? cstr(b->system->name) : "", true, s);
                    else add_rect(out, "upgrade", added, b->location.x, b->location.y, 62, s == 0 ? 150 : 115, b->system ? cstr(b->system->name) : "", true, s);
                    added++;
                }
            }
        }
        size_t n = vsize(up.vUpgradeBoxes);
        for (size_t i = 0; i < n && added == 0; i++) {
            UpgradeBox* b = up.vUpgradeBoxes._start[i];
            if (!b || b->isDummy) continue;
            add_button(out, b->boxButton._base, "upgrade", (int)i, b->system ? cstr(b->system->name) : "", b->subsystem);
        }
        add_button(out, up.reactorButton._base._base, "upgrade", 100, "reactor");
        add_textbutton(out, up.undoButton, "button", 101);
    } else if (cur == (FocusWindow*)&cm) {
        size_t n = vsize(cm.crewBoxes);
        for (size_t i = 0; i < n; i++) {
            CrewEquipBox* b = cm.crewBoxes._start[i];
            if (!b) continue;
            const Globals__Rect& r = b->_base.hitBox;
            add_rect(out, "crewequip", (int)i, r.x, r.y, r.w, r.h, b->_base.item.pCrew ? "item" : "empty", true, 0);
            if (b->bShowDelete) add_textbutton(out, b->deleteButton, "button", 300 + (int)i);
            if (b->bShowRename) add_textbutton(out, b->renameButton, "button", 400 + (int)i);
        }
    } else {
        add_equipment_boxes(out, eq.vEquipmentBoxes, "equip");
    }
}

void add_shipbuilder(std::vector<game::Hit>& out, ShipBuilder& sb) {
    if (sb.shipSelect.bOpen) {
        const ShipSelect& ss = sb.shipSelect;
        if (is_open(ss.tutorial._base)) { add_choicebox(out, ss.tutorial); return; }
        size_t n = vsize(ss.shipButtons);
        for (size_t i = 0; i < n; i++) if (ss.shipButtons._start[i]) add_button(out, ss.shipButtons._start[i]->_base._base, "ship", (int)i, "", ss.selectedShip);
        add_textbutton(out, ss.typeA, "tab", 0); add_textbutton(out, ss.typeB, "tab", 1); add_textbutton(out, ss.typeC, "tab", 2);
        add_textbutton(out, ss.confirm, "close", 200);
        return;
    }
    if (is_open(sb.introScreen._base)) { add_choicebox(out, sb.introScreen); return; }
    add_textbutton(out, sb.startButton, "button", 1);
    add_textbutton(out, sb.backButton, "button", 2);
    add_textbutton(out, sb.renameButton, "button", 3);
    add_button(out, sb.leftButton._base, "button", 4, "prev ship");
    add_button(out, sb.rightButton._base, "button", 5, "next ship");
    add_textbutton(out, sb.listButton, "button", 6);
    add_textbutton(out, sb.showButton, "button", 7);
    add_textbutton(out, sb.easyButton, "button", 8);
    add_textbutton(out, sb.normalButton, "button", 9);
    add_textbutton(out, sb.hardButton, "button", 10);
    add_textbutton(out, sb.typeA, "tab", 0); add_textbutton(out, sb.typeB, "tab", 1); add_textbutton(out, sb.typeC, "tab", 2);
    add_textbutton(out, sb.randomButton, "button", 11);
    add_textbutton(out, sb.advancedOffButton, "button", 12);
    add_textbutton(out, sb.advancedOnButton, "button", 13);
    add_equipment_boxes(out, sb.vEquipmentBoxes, "equip");
    size_t n = vsize(sb.vCrewBoxes);
    for (size_t i = 0; i < n; i++) {
        CrewCustomizeBox* b = sb.vCrewBoxes._start[i];
        if (!b) continue;
        const Globals__Rect& r = b->_base._base.hitBox;
        add_rect(out, "crewequip", (int)i, r.x, r.y, r.w, r.h, b->_base._base.item.pCrew ? "item" : "empty");
        if (b->bCustomizing) {
            add_textbutton(out, b->acceptButton, "button", 500 + (int)i);
            add_textbutton(out, b->bigRenameButton, "button", 520 + (int)i);
            add_button(out, b->leftButton._base, "button", 540 + (int)i, "prev");
            add_button(out, b->rightButton._base, "button", 560 + (int)i, "next");
        }
    }
    n = vsize(sb.sysBoxes);
    for (size_t i = 0; i < n; i++) {
        SystemCustomBox* b = sb.sysBoxes._start[i];
        if (!b) continue;
        add_button(out, b->button._base, "sysbox", b->_base.pSystem ? b->_base.pSystem->iSystemType : (int)i, "", 0);
    }
}

void add_ingame(std::vector<game::Hit>& out, CApp* a) {
    CommandGui* gui = a->gui;
    WorldManager* world = a->world;
    static bool trace = getenv("ENSIGN_TRACE") != nullptr;
#define T(s) do { if (trace) ensign::logf("  ingame: %s", s); } while (0)
    T("topbar");
    // top bar
    add_imgbutton(out, GUI_TAIL(gui, upgradeButton), "topbar", 0, "ship");
    add_textbutton(out, GUI_TAIL(gui, storeButton), "topbar", 1);
    add_imgbutton(out, GUI_TAIL(gui, optionsButton), "topbar", 2, "options");
    add_button(out, gui->ftlButton._base._base, "ftl", 0, "FTL", gui->ftlButton.ready ? 1 : 0);
    T("sysboxes");
    const SystemControl& sc = gui->sysControl;
    size_t n = vsize(sc.sysBoxes);
    for (size_t i = 0; i < n; i++) {
        SystemBox* b = sc.sysBoxes._start[i];
        if (!b || !b->pSystem) continue;
        // SystemControl renders translated by its position, so box geometry is relative to it
        const Globals__Rect& r = b->hitBox;
        int sys = b->pSystem->iSystemType;
        int ox = sc.position.x, oy = sc.position.y;
        // The game only reacts to the mouse in a 20x19 band over the system icon, just
        // below the power bars (measured with tools/run-headless.sh hover probes), so
        // report a 36x36 frame centred on that band.
        if (r.w > 0 && r.h > 0) {
            int cx = ox + r.x + 8, cy = oy + r.y + r.h + 1;
            add_rect(out, "sysbox", sys, cx - 18, cy - 18, 36, 36, cstr(b->pSystem->name), true, (int)i);
        }
        else add_rect(out, "sysbox", sys, ox + b->location.x + 10, oy + b->location.y - 40, 36, 60, cstr(b->pSystem->name), true, (int)i);
    }
    // the door subsystem's "open all" / "close all" buttons (DoorBox keeps them as plain buttons)
    for (size_t i = 0; i < n; i++) {
        SystemBox* b = sc.sysBoxes._start[i];
        if (!b || !b->pSystem || b->pSystem->iSystemType != 8) continue;
        // their hitboxes are relative to the box, which is drawn at SystemControl's position + its location
        const DoorBox* db = (const DoorBox*)b;
        int bx = sc.position.x + db->buttonOffset.x, by = sc.position.y + db->buttonOffset.y;   // the game keeps the buttons' origin here (it follows the box)
        const GenericButton& o = db->openDoors._base; const GenericButton& c = db->closeDoors._base;
        add_rect(out, "doorbtn", 0, bx + o.hitbox.x, by + o.hitbox.y, o.hitbox.w, o.hitbox.h, "open all doors", o.bActive, 0);
        add_rect(out, "doorbtn", 1, bx + c.hitbox.x, by + c.hitbox.y, c.hitbox.w, c.hitbox.h, "close all doors", c.bActive, 0);
    }
    T("crewboxes");
    const CrewControl& cc = gui->crewControl;
    n = vsize(cc.crewBoxes);
    for (size_t i = 0; i < n; i++) {
        CrewBox* b = cc.crewBoxes._start[i];
        if (!b) continue;
        add_rect(out, "crewbox", b->number, b->box.x, b->box.y, b->box.w, b->box.h, "", b->bSelectable, (int)i);
    }
    add_button(out, cc.saveStations._base, "button", 600, "save positions");
    add_button(out, cc.returnStations._base, "button", 601, "return to positions");
    T("armaments");
    const CombatControl& combat = gui->combatControl;
    const ArmamentControl* ctrls[2] = { &combat.weapControl._base, &combat.droneControl._base };
    for (int c = 0; c < 2; c++) {
        const ArmamentControl& ac = *ctrls[c];
        size_t nb = vsize(ac.boxes);
        for (size_t i = 0; i < nb; i++) {
            ArmamentBox* b = ac.boxes._start[i];
            if (!b) continue;
            int bx = b->location.x, by = b->location.y;
            if (bx < ac.location.x - 5) { bx += ac.location.x; by += ac.location.y; }
            // unused slots keep a stale location far from the control: skip them
            if (by < ac.location.y - 40 || by > ac.location.y + 80) continue;
            add_rect(out, "armament", (int)i, bx, by - 2, 95, 44, cstr(b->iconName), true, ac.systemId);   // the slot box itself (the name strip hangs below it)
        }
    }
    {
        const GenericButton& ab = combat.weapControl.autoFireButton._base;
        int ax = ab.hitbox.x, ay = ab.hitbox.y;
        // the autofire button lives in WeaponControl's translated frame
        if (ay < 400) { ax += combat.weapControl._base.location.x; ay += combat.weapControl._base.location.y; }
        add_rect(out, "autofire", 0, ax, ay, ab.hitbox.w, ab.hitbox.h, "AUTOFIRE", ab.bActive, 0);
    }
    T("rooms");
    if (world && world->playerShip && world->playerShip->shipManager) {
        ShipManager* sm = world->playerShip->shipManager;
        const Ship& ship = sm->ship;
        int ox = gui->shipPosition.x, oy = gui->shipPosition.y;
        size_t nr = vsize(ship.vRoomList);
        for (size_t i = 0; i < nr; i++) {
            Room* r = ship.vRoomList._start[i];
            if (!r) continue;
            add_rect(out, "room", r->iRoomId, ox + r->rect.x, oy + r->rect.y, r->rect.w, r->rect.h, "", true, 0);
        }
        size_t nd = vsize(ship.vDoorList);
        for (size_t i = 0; i < nd; i++) {
            Door* d = ship.vDoorList._start[i];
            if (!d) continue;
            int w = d->width > 0 && d->width < 100 ? d->width : (d->bVertical ? 10 : 35);
            int h = d->height > 0 && d->height < 100 ? d->height : (d->bVertical ? 35 : 10);
            char rooms[32]; snprintf(rooms, sizeof rooms, "%d,%d", d->iRoom1, d->iRoom2);
            add_rect(out, "door", d->iDoorId, ox + d->x - w / 2, oy + d->y - h / 2, w, h, rooms, true, d->bOpen ? 1 : 0);
        }
    }
    T("enemy");
    if (combat.currentTarget && combat.currentTarget->shipManager && combat.open) {
        ShipManager* sm = combat.currentTarget->shipManager;
        const Ship& ship = sm->ship;
        int ox = combat.position.x + combat.targetPosition.x, oy = combat.position.y + combat.targetPosition.y;
        size_t nr = vsize(ship.vRoomList);
        for (size_t i = 0; i < nr; i++) {
            Room* r = ship.vRoomList._start[i];
            if (!r) continue;
            add_rect(out, "room", r->iRoomId, ox + r->rect.x, oy + r->rect.y, r->rect.w, r->rect.h, "", true, 1);
        }
    }
}

void add_starmap(std::vector<game::Hit>& out, StarMap& sm) {
    static bool trace = getenv("ENSIGN_TRACE") != nullptr;
#define TS(s) do { if (trace) ensign::logf("  starmap: %s", s); } while (0)
    TS("begin");
    if (sm.bChoosingNewSector) {
        size_t n = vsize(sm.sectorHitBoxes);
        for (size_t i = 0; i < n; i++) {
            const Globals__Rect& r = sm.sectorHitBoxes._start[i];
            add_rect(out, "sector", (int)i, r.x, r.y, r.w, r.h, "", true, sm.potentialSectorChoice);
        }
        add_textbutton(out, sm.closeSectorButton, "close", 200);
        return;
    }
    TS("locations");
    size_t n = vsize(sm.locations);
    for (size_t i = 0; i < n; i++) {
        Location* loc = sm.locations._start[i];
        if (!sane_ptr(loc)) continue;
        // hit zone used by the game's own hover test: loc + position + [35..55] x [33..53]
        int x = (int)loc->loc.x + sm.position.x + 35, y = (int)loc->loc.y + sm.position.y + 33;
        bool reachable = false;
        if (sane_ptr(sm.currentLoc)) {
            size_t nc = vsize(sm.currentLoc->connectedLocations);
            for (size_t j = 0; j < nc; j++) if (sm.currentLoc->connectedLocations._start[j] == loc) reachable = true;
        }
        int extra = (loc == sm.currentLoc ? 1 : 0) | (reachable ? 2 : 0) | (loc->known ? 4 : 0) | (loc->visited ? 8 : 0) | (loc->beacon ? 16 : 0);
        add_rect(out, "location", (int)i, x, y, 20, 20, "", loc == sm.currentLoc || reachable || sm.bMapRevealed, extra);
    }
    TS("buttons");
    // the map's buttons keep window-relative hitboxes; the window sits at sm.position
    auto add_map_button = [&](const GenericButton& b, const char* kind, int id, const char* label) {
        add_rect(out, kind, id, b.hitbox.x + sm.position.x, b.hitbox.y + sm.position.y, b.hitbox.w, b.hitbox.h, label, b.bActive, 0);
    };
    add_map_button(sm.jumpButton._base, "button", 1, "jump");
    add_map_button(sm.waitButton._base, "button", 2, "wait");
    add_map_button(sm.distressButton._base._base, "button", 3, "distress");
    add_map_button(sm.endButton._base, "button", 4, "next sector");
    add_map_button(sm.closeButton._base, "close", 200, "close");
}

} // namespace

namespace game {

bool init() {
    if (g_resolved) return true;
    p_cApp = (CApp**)dlsym(RTLD_DEFAULT, "_ZN6Global6__cAppE");
    f_mouseMove = (MouseMoveFn)dlsym(RTLD_DEFAULT, "_ZN4CApp11OnMouseMoveEiiiibbb");
    f_lDown = (MouseBtnFn)dlsym(RTLD_DEFAULT, "_ZN4CApp13OnLButtonDownEii");
    f_lUp = (MouseBtnFn)dlsym(RTLD_DEFAULT, "_ZN4CApp11OnLButtonUpEii");
    f_rDown = (MouseBtnFn)dlsym(RTLD_DEFAULT, "_ZN4CApp13OnRButtonDownEii");
    f_rUp = (MouseBtnFn)dlsym(RTLD_DEFAULT, "_ZN4CApp11OnRButtonUpEii");
    f_mDown = (MouseBtnFn)dlsym(RTLD_DEFAULT, "_ZN4CApp13OnMButtonDownEii");
    f_keyDown = (KeyFn)dlsym(RTLD_DEFAULT, "_ZN4CApp9OnKeyDownE6SDLKey");
    f_keyUp = (KeyFn)dlsym(RTLD_DEFAULT, "_ZN4CApp7OnKeyUpE6SDLKey");
    f_textInput = (KeyFn)dlsym(RTLD_DEFAULT, "_ZN4CApp11OnTextInputEi");
    g_resolved = p_cApp && f_mouseMove && f_lDown && f_lUp && f_rDown && f_rUp && f_keyDown && f_keyUp;
    ensign::logf("game symbols %s (cApp=%p mouseMove=%p lDown=%p keyDown=%p)", g_resolved ? "resolved" : "MISSING",
                 (void*)p_cApp, (void*)f_mouseMove, (void*)f_lDown, (void*)f_keyDown);
    return g_resolved;
}

bool available() { return g_resolved && app() != nullptr; }

void logical_to_raw(int lx, int ly, int& rx, int& ry) {
    CApp* a = app();
    if (!a || a->mouseModifier_x == 0.f || a->mouseModifier_y == 0.f) { rx = lx; ry = ly; return; }
    rx = (int)((lx + a->modifier_x) / a->mouseModifier_x + 0.5f) + a->x_bar;
    ry = (int)((ly + a->modifier_y) / a->mouseModifier_y + 0.5f) + a->y_bar;
}
void raw_to_logical(int rx, int ry, int& lx, int& ly) {
    CApp* a = app();
    if (!a) { lx = rx; ly = ry; return; }
    lx = (int)((rx - a->x_bar) * a->mouseModifier_x) - a->modifier_x;
    ly = (int)((ry - a->y_bar) * a->mouseModifier_y) - a->modifier_y;
}

void mouse_move(int lx, int ly) {
    CApp* a = app(); if (!a) return;
    int rx, ry; logical_to_raw(lx, ly, rx, ry);
    int dx = rx - g_rawX, dy = ry - g_rawY;
    g_rawX = rx; g_rawY = ry;
    f_mouseMove(a, rx, ry, dx, dy, g_holdL, g_holdR, g_holdM);
}
void mouse_down(int button) {
    CApp* a = app(); if (!a) return;
    if (button == 3) { g_holdR = true; f_rDown(a, g_rawX, g_rawY); }
    else if (button == 2) { g_holdM = true; if (f_mDown) f_mDown(a, g_rawX, g_rawY); }
    else { g_holdL = true; f_lDown(a, g_rawX, g_rawY); }
}
void mouse_up(int button) {
    CApp* a = app(); if (!a) return;
    if (button == 3) { g_holdR = false; f_rUp(a, g_rawX, g_rawY); }
    else if (button == 2) { g_holdM = false; }
    else { g_holdL = false; f_lUp(a, g_rawX, g_rawY); }
}
void key_down(int k) { CApp* a = app(); if (a) f_keyDown(a, k); }
void key_up(int k) { CApp* a = app(); if (a) f_keyUp(a, k); }
void text_input(int ch) { CApp* a = app(); if (a && f_textInput) f_textInput(a, ch); }

std::string screen() {
    CApp* a = app();
    if (!a) return "none";
    if (is_open(a->langChooser._base)) return "language";
    if ((*(unsigned char*)&a->menu.bOpen == 1)) {
        MainMenu& m = a->menu;
        if (m.shipBuilder.bOpen) {
            if (m.shipBuilder.shipSelect.bOpen) return "shipselect";
            if (is_open(m.shipBuilder.introScreen._base)) return "shipbuilder_intro";
            if (m.shipBuilder.bRenaming) return "rename";
            return "shipbuilder";
        }
        if (is_open(m.optionScreen._base._base)) return "options";
        if (m.bCreditScreen) return "credits";
        if (m.bScoreScreen) return "scores";
        if (is_open(m.confirmNewGame._base)) return "confirm";
        if (is_open(m.changelog._base)) return "changelog";
        return "mainmenu";
    }
    CommandGui* gui = a->gui;
    if (!gui) return "none";
    if (is_open(gui->gameOverScreen._base)) return "gameover";
    if (is_open(gui->menuBox._base)) return is_open(gui->menuBox.confirmDialog._base) ? "confirm" : "pausemenu";
    if (is_open(gui->optionsBox._base._base)) return "options";
    if (is_open(gui->inputBox._base)) return "input";
    if (is_open(GUI_TAIL(gui, leaveCrewDialog)._base)) return "confirm";
    if (is_open(gui->choiceBox._base)) return "event";   // modal over everything else
    if (is_open(gui->storeScreens._base)) return "store";
    if (is_open(gui->shipScreens._base)) return "shipscreens";
    if (gui->starMap && gui->starMap->_base.bOpen) return "starmap";
    return "game";
}

void hitboxes(std::vector<Hit>& out) {
    out.clear();
    CApp* a = app();
    if (!a) return;
    if (is_open(a->langChooser._base)) {
        size_t n = vsize(a->langChooser.buttons);
        for (size_t i = 0; i < n; i++) if (a->langChooser.buttons._start[i]) add_textbutton(out, *a->langChooser.buttons._start[i], "button", (int)i);
        return;
    }
    if ((*(unsigned char*)&a->menu.bOpen == 1)) {
        MainMenu& m = a->menu;
        if (m.shipBuilder.bOpen) { add_shipbuilder(out, m.shipBuilder); return; }
        if (is_open(m.optionScreen._base._base)) { add_options(out, m.optionScreen); return; }
        if (is_open(m.confirmNewGame._base)) { add_confirm(out, m.confirmNewGame); return; }
        if (is_open(m.changelog._base)) { add_choicebox(out, m.changelog); return; }
        if (m.bCreditScreen || m.bScoreScreen) return;
        const Button* named[] = { &m.continueButton, &m.startButton, &m.helpButton, &m.statButton, &m.optionsButton, &m.creditsButton, &m.quitButton };
        const char* names[] = { "continue", "new game", "help", "stats", "options", "credits", "quit" };
        size_t n = vsize(m.buttons);
        for (size_t i = 0; i < n; i++) {
            Button* b = m.buttons._start[i];
            if (!b) continue;
            std::string label = "button";
            for (int k = 0; k < 7; k++) if (b == named[k]) label = names[k];
            add_button(out, b->_base, "button", (int)i, label);
        }
        return;
    }
    CommandGui* gui = a->gui;
    if (!gui) return;
    if (is_open(gui->gameOverScreen._base)) {
        size_t n = vsize(gui->gameOverScreen.buttons);
        for (size_t i = 0; i < n; i++) if (gui->gameOverScreen.buttons._start[i]) add_textbutton(out, *gui->gameOverScreen.buttons._start[i], "button", (int)i);
        return;
    }
    if (is_open(gui->menuBox._base)) {
        if (is_open(gui->menuBox.confirmDialog._base)) { add_confirm(out, gui->menuBox.confirmDialog); return; }
        size_t n = vsize(gui->menuBox.buttons);
        for (size_t i = 0; i < n; i++) if (gui->menuBox.buttons._start[i]) add_textbutton(out, *gui->menuBox.buttons._start[i], "button", (int)i);
        return;
    }
    if (is_open(gui->optionsBox._base._base)) { add_options(out, gui->optionsBox); return; }
    if (is_open(gui->inputBox._base)) return;
    if (is_open(GUI_TAIL(gui, leaveCrewDialog)._base)) { add_confirm(out, GUI_TAIL(gui, leaveCrewDialog)); return; }
    if (is_open(gui->choiceBox._base)) { add_choicebox(out, gui->choiceBox); return; }
    if (is_open(gui->storeScreens._base)) { add_store(out, gui); return; }
    if (is_open(gui->shipScreens._base)) { add_ship_screens(out, gui); return; }
    if (gui->starMap && gui->starMap->_base.bOpen) { add_starmap(out, *gui->starMap); return; }
    add_ingame(out, a);
}

bool mouse_is_hidden() { return false; }
int player_ship_x() { CApp* a = app(); return (a && a->gui) ? a->gui->shipPosition.x : 0; }
int player_ship_y() { CApp* a = app(); return (a && a->gui) ? a->gui->shipPosition.y : 0; }
bool enemy_ship_origin(int& x, int& y) {
    CApp* a = app();
    if (!a || !a->gui) return false;
    const CombatControl& c = a->gui->combatControl;
    if (!c.currentTarget || !c.open) return false;
    x = c.position.x + c.targetPosition.x; y = c.position.y + c.targetPosition.y;
    return true;
}
// dev probe: raw bytes of a door object (layout validation)
std::string door_bytes(int index, int from, int count) {
    CApp* a = app();
    if (!a || !a->world || !a->world->playerShip || !a->world->playerShip->shipManager) return "";
    const Ship& ship = a->world->playerShip->shipManager->ship;
    if (index < 0 || (size_t)index >= vsize(ship.vDoorList)) return "";
    const unsigned char* b = (const unsigned char*)ship.vDoorList._start[index];
    if (!sane_ptr(b) || from < 0 || count <= 0 || count > 1024) return "";
    std::string s; char buf[8];
    for (int i = 0; i < count; i++) { snprintf(buf, sizeof buf, "%02x", b[from + i]); s += buf; if (i % 4 == 3) s += " "; }
    return s;
}
// which crew member (index into the ship's crew list) a crew box shows; -1 when none
int crew_box_crew(int boxIndex) {
    CApp* a = app();
    if (!a || !a->gui) return -1;
    const CrewControl& cc = a->gui->crewControl;
    if (boxIndex < 0 || (size_t)boxIndex >= vsize(cc.crewBoxes)) return -1;
    CrewBox* b = cc.crewBoxes._start[boxIndex];
    if (!b || !sane_ptr(b->pCrew)) return -1;
    ShipManager* sm = cc.shipManager;
    if (!sane_ptr(sm)) return -1;
    size_t n = vsize(sm->vCrewList);
    for (size_t i = 0; i < n; i++) if (sm->vCrewList._start[i] == b->pCrew) return (int)i;
    return -1;
}
bool armament_hover(int systemId, int index) {
    CApp* a = app();
    if (!a || !a->gui) return false;
    const ArmamentControl& ac = systemId == 4 ? a->gui->combatControl.droneControl._base : a->gui->combatControl.weapControl._base;
    if (index < 0 || (size_t)index >= vsize(ac.boxes)) return false;
    ArmamentBox* b = ac.boxes._start[index];
    return b && b->mouseHover;
}
// Raise the subsystem group (pilot / sensors / doors / battery, and the frame it sits
// in) by `dy` pixels so the controller hints fit underneath. The game lays the boxes out
// once, so the original positions are remembered per box and re-applied every frame;
// dy = 0 restores the stock layout.
static std::map<void*, int> g_subBaseY;
static int g_subFrameBaseX = INT_MIN, g_subFrameBaseY = INT_MIN;
static int g_subLiftApplied = INT_MIN, g_subFrameDxApplied = 0, g_subFrameDyApplied = 0;
static GL_Primitive* g_origSubBox = nullptr;   // the game's own frame primitive
static GL_Primitive* g_ourSubBox = nullptr;    // our relocated copy
typedef GL_Primitive* (*CreateImagePrimitiveFn)(GL_Texture*, float, float, float, float, float, GL_Color);
typedef void (*DestroyPrimitiveFn)(GL_Primitive*);
// frameDx/frameDy: where the frame image sits relative to subSystemPosition (calibrated
// from screenshots; the game bakes the frame's coordinates into a primitive we cannot read)
void lift_subsystems(int dy, int frameDx, int frameDy) {
    CApp* a = app();
    if (!a || !a->gui) return;
    SystemControl& sc = a->gui->sysControl;
    if (g_subFrameBaseY == INT_MIN) { g_subFrameBaseX = sc.subSystemPosition.x; g_subFrameBaseY = sc.subSystemPosition.y; }
    sc.subSystemPosition.y = g_subFrameBaseY - dy;
    if (sc.sub_box != g_ourSubBox && sc.sub_box != g_origSubBox) {
        // the game rebuilt its frame (a system was added or removed): whatever primitive
        // was installed, ours included, has been destroyed by the game, so forget it
        g_origSubBox = sc.sub_box; g_ourSubBox = nullptr; g_subLiftApplied = INT_MIN;
    }
    if (dy != g_subLiftApplied || frameDx != g_subFrameDxApplied || frameDy != g_subFrameDyApplied) {
        static CreateImagePrimitiveFn create = (CreateImagePrimitiveFn)dlsym(RTLD_DEFAULT, "_ZN8CSurface23GL_CreateImagePrimitiveEP10GL_Texturefffff8GL_Color");
        static DestroyPrimitiveFn destroy = (DestroyPrimitiveFn)dlsym(RTLD_DEFAULT, "_ZN8CSurface19GL_DestroyPrimitiveEP12GL_Primitive");
        GL_Primitive* old = (sc.sub_box == g_ourSubBox) ? g_ourSubBox : nullptr;   // only destroy what is still installed
        g_ourSubBox = nullptr;
        if (dy == 0) {
            if (g_origSubBox) sc.sub_box = g_origSubBox;
        } else if (create && g_origSubBox && sane_ptr(g_origSubBox->texture)) {
            GL_Texture* tex = g_origSubBox->texture;
            GL_Color white; white.r = white.g = white.b = white.a = 1.0f;
            GL_Primitive* np = create(tex, (float)(g_subFrameBaseX + frameDx), (float)(g_subFrameBaseY - dy + frameDy),
                                      (float)tex->width_, (float)tex->height_, 0.0f, white);
            if (np) { g_ourSubBox = np; sc.sub_box = np; }
            else ensign::logf("lift_subsystems: could not create the relocated frame");
        } else if (dy != 0 && g_origSubBox) {
            ensign::logf("lift_subsystems: cannot rebuild the frame (create=%p); boxes move without it", (void*)create);
        } else if (dy != 0) {
            g_subLiftApplied = INT_MIN;   // the game has not built its frame yet (main menu); retry next frame
            return;
        }
        if (old && destroy) destroy(old);
        g_subLiftApplied = dy; g_subFrameDxApplied = frameDx; g_subFrameDyApplied = frameDy;
    }
    size_t n = vsize(sc.sysBoxes);
    for (size_t i = 0; i < n; i++) {
        SystemBox* b = sc.sysBoxes._start[i];
        if (!b || !b->pSystem) continue;
        int t = b->pSystem->iSystemType;
        if (t != 6 && t != 7 && t != 8 && t != 12) continue;   // pilot, sensors, doors, battery
        auto it = g_subBaseY.find(b);
        if (it == g_subBaseY.end()) it = g_subBaseY.emplace(b, b->location.y).first;
        b->location.y = it->second - dy;
    }
}

bool sysbox_hover(int systemId) {
    CApp* a = app();
    if (!a || !a->gui) return false;
    const SystemControl& sc = a->gui->sysControl;
    size_t n = vsize(sc.sysBoxes);
    for (size_t i = 0; i < n; i++) {
        SystemBox* b = sc.sysBoxes._start[i];
        if (b && b->pSystem && b->pSystem->iSystemType == systemId) return b->mouseHover;
    }
    return false;
}

}

// Developer probe: dump bytes around layout-sensitive fields so the struct
// hypotheses can be validated against the live process (ENSIGN_DEV only).
namespace game {
std::string dev_probe() {
    CApp* a = app();
    if (!a) return "no app";
    char buf[4096]; std::string s;
    auto dump = [&](const char* name, const void* p, size_t n) {
        int k = snprintf(buf, sizeof buf, "%s @%p:", name, p);
        const unsigned char* b = (const unsigned char*)p;
        for (size_t i = 0; i < n && k < (int)sizeof buf - 4; i++) k += snprintf(buf + k, sizeof buf - k, " %02x", b[i]);
        s += buf; s += "\n";
    };
    MainMenu& m = a->menu;
    const char* opt = (const char*)&m.optionScreen;
    dump("menu.bOpen", &m.bOpen, 4);
    dump("optionScreen+4352 (bSelectSave if additions present)", opt + 4352, 16);
    dump("optionScreen+4088 (bSelectSave if additions absent)", opt + 4088, 16);
    dump("confirmNewGame(+4352).bOpen", opt + 4352 + 8 + 8, 4);
    dump("confirmNewGame(+4088).bOpen", opt + 4088 + 8 + 8, 4);
    dump("optionScreen.closeButton.label", &m.optionScreen.closeButton.label, 8);
    dump("optionScreen.closeButton.label.str", m.optionScreen.closeButton.label.data.string, 16);
    if (a->gui) {
        const char* ob = (const char*)&a->gui->optionsBox;
        dump("gui.optionsBox+4352 (bPaused.. if additions)", ob + 4352, 16);
        dump("gui.optionsBox+4088 (bPaused.. if absent)", ob + 4088, 16);
        dump("gui.menuBox.bOpen", &a->gui->menuBox._base.bOpen, 4);
        dump("gui.optionsBox.closeButton.label.str", a->gui->optionsBox.closeButton.label.data.string, 16);
        dump("gui.leaveCrewDialog.bOpen", &a->gui->leaveCrewDialog._base.bOpen, 4);
        dump("gui.shipScreens.bOpen", &a->gui->shipScreens._base.bOpen, 4);
        CommandGui* g = a->gui;
        int k = snprintf(buf, sizeof buf, "upgradeButton pos=%d,%d hit=%d,%d,%d,%d active=%d | storeButton pos=%d,%d hit=%d,%d,%d,%d active=%d | optionsButton pos=%d,%d hit=%d,%d,%d,%d active=%d | weapControl.location=%d,%d autofire pos=%d,%d hit=%d,%d,%d,%d | droneControl.location=%d,%d | sysControl.position=%d,%d | spaceStatus.hitbox=%d,%d,%d,%d\n",
            g->upgradeButton._base.position.x, g->upgradeButton._base.position.y, g->upgradeButton._base.hitbox.x, g->upgradeButton._base.hitbox.y, g->upgradeButton._base.hitbox.w, g->upgradeButton._base.hitbox.h, (int)g->upgradeButton._base.bActive,
            g->storeButton._base.position.x, g->storeButton._base.position.y, g->storeButton._base.hitbox.x, g->storeButton._base.hitbox.y, g->storeButton._base.hitbox.w, g->storeButton._base.hitbox.h, (int)g->storeButton._base.bActive,
            g->optionsButton._base.position.x, g->optionsButton._base.position.y, g->optionsButton._base.hitbox.x, g->optionsButton._base.hitbox.y, g->optionsButton._base.hitbox.w, g->optionsButton._base.hitbox.h, (int)g->optionsButton._base.bActive,
            g->combatControl.weapControl._base.location.x, g->combatControl.weapControl._base.location.y,
            g->combatControl.weapControl.autoFireButton._base.position.x, g->combatControl.weapControl.autoFireButton._base.position.y, g->combatControl.weapControl.autoFireButton._base.hitbox.x, g->combatControl.weapControl.autoFireButton._base.hitbox.y, g->combatControl.weapControl.autoFireButton._base.hitbox.w, g->combatControl.weapControl.autoFireButton._base.hitbox.h,
            g->combatControl.droneControl._base.location.x, g->combatControl.droneControl._base.location.y,
            g->sysControl.position.x, g->sysControl.position.y,
            g->spaceStatus.hitbox.x, g->spaceStatus.hitbox.y, g->spaceStatus.hitbox.w, g->spaceStatus.hitbox.h);
        (void)k; s += buf;
        {
            const SystemControl& sc = g->sysControl;
            k = snprintf(buf, sizeof buf, "sysControl: position=%d,%d subSystemPosition=%d,%d systemPowerPosition=%d,%d sub_spacing=%d sub_box=%p tex=%p",
                sc.position.x, sc.position.y, sc.subSystemPosition.x, sc.subSystemPosition.y, sc.systemPowerPosition.x, sc.systemPowerPosition.y, sc.sub_spacing,
                (void*)sc.sub_box, sc.sub_box ? (void*)sc.sub_box->texture : nullptr);
            s += buf;
            if (sc.sub_box && sane_ptr(sc.sub_box->texture)) {
                k = snprintf(buf, sizeof buf, " tex=%dx%d type=%d", sc.sub_box->texture->width_, sc.sub_box->texture->height_, sc.sub_box->type);
                s += buf;
            }
            s += "\n";
            for (size_t i = 0; i < vsize(sc.sysBoxes); i++) {
                SystemBox* b = sc.sysBoxes._start[i];
                if (!b || !b->pSystem) continue;
                k = snprintf(buf, sizeof buf, "  sysbox %d loc=%d,%d hit=%d,%d,%d,%d top=%d\n", b->pSystem->iSystemType, b->location.x, b->location.y,
                    b->hitBox.x, b->hitBox.y, b->hitBox.w, b->hitBox.h, b->hitBoxTop);
                s += buf;
                if (b->pSystem->iSystemType == 8) {
                    const DoorBox* db = (const DoorBox*)b;
                    k = snprintf(buf, sizeof buf, "  doorbox open pos=%d,%d hit=%d,%d,%d,%d close pos=%d,%d hit=%d,%d,%d,%d offset=%d,%d\n",
                        db->openDoors._base.position.x, db->openDoors._base.position.y, db->openDoors._base.hitbox.x, db->openDoors._base.hitbox.y, db->openDoors._base.hitbox.w, db->openDoors._base.hitbox.h,
                        db->closeDoors._base.position.x, db->closeDoors._base.position.y, db->closeDoors._base.hitbox.x, db->closeDoors._base.hitbox.y, db->closeDoors._base.hitbox.w, db->closeDoors._base.hitbox.h,
                        db->buttonOffset.x, db->buttonOffset.y);
                    s += buf;
                }
            }
        }
        // ship screens internals
        const Upgrades& up = g->upgradeScreen;
        k = snprintf(buf, sizeof buf, "upgrades: open=%d boxes=%zu systemCount=%d\n", (int)is_open(up._base), vsize(up.vUpgradeBoxes), up.systemCount);
        s += buf;
        for (size_t i = 0; i < vsize(up.vUpgradeBoxes) && i < 12; i++) {
            UpgradeBox* b = up.vUpgradeBoxes._start[i];
            if (!b) continue;
            k = snprintf(buf, sizeof buf, "  ub%zu loc=%d,%d dummy=%d sub=%d cur=%p box.hit=%d,%d,%d,%d box.pos=%d,%d max.hit=%d,%d,%d,%d sys=%p\n", i, b->location.x, b->location.y, (int)b->isDummy, (int)b->subsystem, (void*)b->currentButton,
                b->boxButton._base.hitbox.x, b->boxButton._base.hitbox.y, b->boxButton._base.hitbox.w, b->boxButton._base.hitbox.h, b->boxButton._base.position.x, b->boxButton._base.position.y,
                b->maxButton._base.hitbox.x, b->maxButton._base.hitbox.y, b->maxButton._base.hitbox.w, b->maxButton._base.hitbox.h, (void*)b->system);
            s += buf;
        }
        k = snprintf(buf, sizeof buf, "equip: open=%d boxes=%zu storeMode=%d | crewScreen: open=%d boxes=%zu | shipScreens.windows=%zu tab=%u [%p %p %p] equip=%p up=%p crew=%p\n",
            (int)is_open(g->equipScreen._base), vsize(g->equipScreen.vEquipmentBoxes), (int)g->equipScreen.bStoreMode, (int)is_open(g->crewScreen._base), vsize(g->crewScreen.crewBoxes),
            vsize(g->shipScreens.windows), g->shipScreens.currentTab,
            vsize(g->shipScreens.windows) > 0 ? (void*)g->shipScreens.windows._start[0] : nullptr, vsize(g->shipScreens.windows) > 1 ? (void*)g->shipScreens.windows._start[1] : nullptr, vsize(g->shipScreens.windows) > 2 ? (void*)g->shipScreens.windows._start[2] : nullptr,
            (void*)&g->equipScreen, (void*)&g->upgradeScreen, (void*)&g->crewScreen);
        s += buf;
        {
            Store* st = nullptr;
            if (store_window(g, st) && st) {
                k = snprintf(buf, sizeof buf, "store: boxes=%zu items=%zu sectionCount=%d types=%d,%d,%d,%d bShowPage2=%d page1.active=%d page2.active=%d\n",
                    vsize(st->vStoreBoxes), vsize(st->vItemBoxes), st->sectionCount, st->types[0], st->types[1], st->types[2], st->types[3],
                    (int)st->bShowPage2, (int)st->page1._base.bActive, (int)st->page2._base.bActive);
                s += buf;
                dump("  store.sectionCount..", &st->sectionCount, 48);
            }
        }
        {
            CrewManifest& cm = GUI_TAIL(g, crewScreen);
            for (size_t i = 0; i < vsize(cm.crewBoxes) && i < 4; i++) {
                CrewEquipBox* b = cm.crewBoxes._start[i];
                if (!sane_ptr(b)) continue;
                k = snprintf(buf, sizeof buf, "  cb%zu hit=%d,%d,%d,%d slot=%d item=%p,%p,%p,%p dead=%d showDel=%d showRen=%d ship=%p\n", i,
                    b->_base.hitBox.x, b->_base.hitBox.y, b->_base.hitBox.w, b->_base.hitBox.h, b->_base.slot,
                    (void*)b->_base.item.pWeapon, (void*)b->_base.item.pDrone, (void*)b->_base.item.pCrew, (void*)b->_base.item.augment,
                    (int)b->bDead, (int)b->bShowDelete, (int)b->bShowRename, (void*)b->ship);
                s += buf;
                dump("  cb.item+", &b->_base.item, 64);
            }
        }
        for (size_t i = 0; i < vsize(g->equipScreen.vEquipmentBoxes) && i < 4; i++) {
            EquipmentBox* b = g->equipScreen.vEquipmentBoxes._start[i];
            if (!b) continue;
            k = snprintf(buf, sizeof buf, "  eq%zu loc=%d,%d hit=%d,%d,%d,%d slot=%d\n", i, b->location.x, b->location.y, b->hitBox.x, b->hitBox.y, b->hitBox.w, b->hitBox.h, b->slot);
            s += buf;
        }
    }
    return s;
}
}

