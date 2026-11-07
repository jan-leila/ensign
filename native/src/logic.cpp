#include "logic.h"
#include "log.h"
#include "ftl_structs_elf64.h"
#include <dlfcn.h>
#include <elf.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

inline bool sane(const void* p) { return (uintptr_t)p > 0x10000 && (uintptr_t)p < 0x800000000000ull; }
template <class V> size_t vsz(const V& v) { return (v._start && v._finish >= v._start) ? (size_t)(v._finish - v._start) : 0; }

std::map<std::string, void*> g_syms;
std::string g_status = "uninitialized";
CApp** p_cApp = nullptr;

CApp* app() { return (p_cApp && *p_cApp) ? *p_cApp : nullptr; }
CommandGui* gui() { CApp* a = app(); return (a && sane(a->gui)) ? a->gui : nullptr; }
ShipManager* player() { CommandGui* g = gui(); return (g && sane(g->combatControl.shipManager)) ? g->combatControl.shipManager : nullptr; }
ShipManager* enemy() {
    CommandGui* g = gui();
    if (!g) return nullptr;
    CompleteShip* t = g->combatControl.currentTarget;
    return (sane(t) && sane(t->shipManager)) ? t->shipManager : nullptr;
}
ShipManager* ship_by_id(int id) { return id == 0 ? player() : enemy(); }

// CommandGui members after `upgradeScreen` sit 8 bytes earlier than the header says
// (see game.cpp); measure the shift from the ship screens' own window pointers.
long tail_delta(CommandGui* g) {
    static long cached = 0; static CommandGui* cachedFor = nullptr;
    if (g == cachedFor) return cached;
    if (vsz(g->shipScreens.windows) >= 2 && g->shipScreens.windows._start[1]) {
        long d = (char*)g->shipScreens.windows._start[1] - (char*)&g->crewScreen;
        if (d > -64 && d < 64) { cached = d; cachedFor = g; }
    }
    return cached;
}
void* equip_screen(CommandGui* g) { return (char*)&g->equipScreen + tail_delta(g); }

// Read the running executable's .symtab once. The game is a non-PIE executable, so
// the recorded addresses are the real ones.
bool load_symbols() {
    FILE* f = fopen("/proc/self/exe", "rb");
    if (!f) { g_status = "cannot open /proc/self/exe"; return false; }
    Elf64_Ehdr eh;
    if (fread(&eh, sizeof eh, 1, f) != 1 || memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0 || eh.e_ident[EI_CLASS] != ELFCLASS64) {
        fclose(f); g_status = "not an ELF64 executable"; return false;
    }
    if (eh.e_type != ET_EXEC) ensign::logf("logic: executable type %d (expected ET_EXEC); symbol addresses may need relocation", (int)eh.e_type);
    std::vector<Elf64_Shdr> sh(eh.e_shnum);
    fseek(f, (long)eh.e_shoff, SEEK_SET);
    if (fread(sh.data(), sizeof(Elf64_Shdr), eh.e_shnum, f) != eh.e_shnum) { fclose(f); g_status = "bad section table"; return false; }
    bool any = false;
    for (const Elf64_Shdr& s : sh) {
        if (s.sh_type != SHT_SYMTAB) continue;
        if (s.sh_link >= sh.size()) continue;
        const Elf64_Shdr& str = sh[s.sh_link];
        std::vector<char> strtab(str.sh_size + 1, 0);
        fseek(f, (long)str.sh_offset, SEEK_SET);
        if (fread(strtab.data(), 1, str.sh_size, f) != str.sh_size) continue;
        size_t n = s.sh_size / sizeof(Elf64_Sym);
        std::vector<Elf64_Sym> syms(n);
        fseek(f, (long)s.sh_offset, SEEK_SET);
        if (fread(syms.data(), sizeof(Elf64_Sym), n, f) != n) continue;
        for (const Elf64_Sym& y : syms) {
            if (ELF64_ST_TYPE(y.st_info) != STT_FUNC || y.st_value == 0 || y.st_name >= str.sh_size) continue;
            g_syms.emplace(std::string(strtab.data() + y.st_name), (void*)(uintptr_t)y.st_value);
        }
        any = true;
    }
    fclose(f);
    if (!any) { g_status = "no .symtab in the executable"; return false; }
    return true;
}

template <class F> F sym(const char* name) {
    auto it = g_syms.find(name);
    if (it == g_syms.end()) { ensign::logf("logic: symbol %s not found", name); return nullptr; }
    return (F)it->second;
}
#define SYM(var, type, name) using var##_t = type; static var##_t var = sym<var##_t>(name); if (!var) return false

struct VecPointf { Pointf* b; Pointf* e; Pointf* c; };

} // namespace

namespace logic {

bool init() {
    if (!g_syms.empty()) return true;
    p_cApp = (CApp**)dlsym(RTLD_DEFAULT, "_ZN6Global6__cAppE");
    if (!load_symbols()) { ensign::logf("logic: %s", g_status.c_str()); return false; }
    const char* required[] = {
        "_ZN11ShipManager19IncreaseSystemPowerEi", "_ZN13SystemControl7RButtonEiib",
        "_ZN12WeaponSystem11PowerWeaponEP17ProjectileFactorybb", "_ZN12WeaponSystem13DePowerWeaponEP17ProjectileFactoryb",
        "_ZN11DroneSystem10PowerDroneEP5Dronebb", "_ZN11DroneSystem12DePowerDroneEP5Droneb",
        "_ZN13WeaponControl14SelectArmamentEj", "_ZN13CombatControl9DisarmAllEv", "_ZN13WeaponControl4FireESt6vectorI6PointfSaIS1_EEib",
        "_ZN11ShipManager13GetRoomCenterEi", "_ZN13WeaponControl13SwapArmamentsEjj", "_ZN12DroneControl13SwapArmamentsEjj",
        "_ZN10CrewMember10MoveToRoomEiib", "_ZN4Door4OpenEv", "_ZN4Door5CloseEv", "_ZN10CommandGui9SetPausedEbb",
        "_ZN7StarMap10MouseClickEii", "_ZN7StarMap5CloseEv", "_ZN9ChoiceBox10MouseClickEii", "_ZN5Store10MouseClickEii",
        "_ZN9Equipment10MouseClickEii", "_ZN9Equipment7MouseUpEii", "_ZN12TabbedWindow6SetTabEj",
    };
    int missing = 0;
    for (const char* r : required) if (!g_syms.count(r)) { missing++; ensign::logf("logic: missing %s", r); }
    char buf[128]; snprintf(buf, sizeof buf, "%zu symbols loaded, %d of %zu required missing", g_syms.size(), missing, sizeof(required) / sizeof(required[0]));
    g_status = buf;
    ensign::logf("logic: %s", buf);
    return missing == 0;
}
const char* status() { return g_status.c_str(); }

bool sys_power(int systemId, int delta) {
    ShipManager* sm = player();
    if (!sm) return false;
    if (delta > 0) {
        SYM(inc, bool (*)(ShipManager*, int), "_ZN11ShipManager19IncreaseSystemPowerEi");
        return inc(sm, systemId);
    }
    // Removing a bar goes through the system panel's own right-button handler (the
    // plain ShipSystem::DecreasePower call reports success without changing anything).
    CommandGui* g = gui();
    if (!g) return false;
    SYM(rb, void (*)(SystemControl*, int, int, bool), "_ZN13SystemControl7RButtonEiib");
    SystemControl& sc = g->sysControl;
    for (size_t i = 0; i < vsz(sc.sysBoxes); i++) {
        SystemBox* b = sc.sysBoxes._start[i];
        if (!sane(b) || !sane(b->pSystem) || b->pSystem->iSystemType != systemId) continue;
        int x = sc.position.x + b->hitBox.x + 8, y = sc.position.y + b->hitBox.y + b->hitBox.h + 1;   // the icon band (see game.cpp)
        rb(&sc, x, y, false);
        return true;
    }
    return false;
}

bool weapon_power(int slot, bool on) {
    ShipManager* sm = player();
    if (!sm || !sane(sm->weaponSystem)) return false;
    if (slot < 0 || (size_t)slot >= vsz(sm->weaponSystem->weapons)) return false;
    ProjectileFactory* w = sm->weaponSystem->weapons._start[slot];
    if (!sane(w)) return false;
    if (on) { SYM(pw, bool (*)(WeaponSystem*, ProjectileFactory*, bool, bool), "_ZN12WeaponSystem11PowerWeaponEP17ProjectileFactorybb"); return pw(sm->weaponSystem, w, true, false); }
    SYM(dp, bool (*)(WeaponSystem*, ProjectileFactory*, bool), "_ZN12WeaponSystem13DePowerWeaponEP17ProjectileFactoryb");
    return dp(sm->weaponSystem, w, true);
}

bool drone_power(int slot, bool on) {
    ShipManager* sm = player();
    if (!sm || !sane(sm->droneSystem)) return false;
    if (slot < 0 || (size_t)slot >= vsz(sm->droneSystem->drones)) return false;
    Drone* d = sm->droneSystem->drones._start[slot];
    if (!sane(d)) return false;
    if (on) { SYM(pd, bool (*)(DroneSystem*, Drone*, bool, bool), "_ZN11DroneSystem10PowerDroneEP5Dronebb"); return pd(sm->droneSystem, d, true, false); }
    SYM(dd, bool (*)(DroneSystem*, Drone*, bool), "_ZN11DroneSystem12DePowerDroneEP5Droneb");
    return dd(sm->droneSystem, d, true);
}

bool arm_weapon(int slot) {
    CommandGui* g = gui();
    if (!g) return false;
    if (slot < 0) { SYM(disarm, void (*)(CombatControl*), "_ZN13CombatControl9DisarmAllEv"); disarm(&g->combatControl); return true; }
    SYM(sel, void (*)(WeaponControl*, unsigned), "_ZN13WeaponControl14SelectArmamentEj");
    sel(&g->combatControl.weapControl, (unsigned)slot);
    return g->combatControl.weapControl.armedWeapon != nullptr;
}

bool room_center(int shipId, int roomId, float& x, float& y) {
    ShipManager* sm = ship_by_id(shipId);
    if (!sm) return false;
    SYM(rc, Pointf (*)(ShipManager*, int), "_ZN11ShipManager13GetRoomCenterEi");
    Pointf p = rc(sm, roomId);
    x = p.x; y = p.y;
    return true;
}

bool fire_at(int targetShipId, int npoints, const float* xy) {
    CommandGui* g = gui();
    if (!g || npoints < 1 || npoints > 2) return false;
    if (!g->combatControl.weapControl.armedWeapon) return false;
    SYM(fire, void (*)(WeaponControl*, VecPointf*, int, bool), "_ZN13WeaponControl4FireESt6vectorI6PointfSaIS1_EEib");
    Pointf pts[2];
    for (int i = 0; i < npoints; i++) { pts[i].x = xy[i * 2]; pts[i].y = xy[i * 2 + 1]; }
    // std::vector<Pointf> by value: the ABI passes the address of a temporary
    Pointf* buf = (Pointf*)malloc(sizeof(Pointf) * 2);
    memcpy(buf, pts, sizeof(Pointf) * npoints);
    VecPointf v = { buf, buf + npoints, buf + 2 };
    fire(&g->combatControl.weapControl, &v, targetShipId, false);
    if (v.b == buf) free(buf);   // untouched: still ours (a swap would have handed it to the game)
    return true;
}

bool swap_weapons(int a, int b) {
    CommandGui* g = gui();
    if (!g) return false;
    SYM(sw, void (*)(WeaponControl*, unsigned, unsigned), "_ZN13WeaponControl13SwapArmamentsEjj");
    sw(&g->combatControl.weapControl, (unsigned)a, (unsigned)b);
    return true;
}
bool swap_drones(int a, int b) {
    CommandGui* g = gui();
    if (!g) return false;
    SYM(sw, void (*)(DroneControl*, unsigned, unsigned), "_ZN12DroneControl13SwapArmamentsEjj");
    sw(&g->combatControl.droneControl, (unsigned)a, (unsigned)b);
    return true;
}

bool move_crew(int crewIndex, int roomId) {
    ShipManager* sm = player();
    if (!sm) return false;
    if (crewIndex < 0 || (size_t)crewIndex >= vsz(sm->vCrewList)) return false;
    CrewMember* c = sm->vCrewList._start[crewIndex];
    if (!sane(c)) return false;
    SYM(mv, bool (*)(CrewMember*, int, int, bool), "_ZN10CrewMember10MoveToRoomEiib");
    return mv(c, roomId, -1, false);
}

bool door(bool airlock, int index, bool open) {
    ShipManager* sm = player();
    if (!sm) return false;
    const std__vector_6DoorZ1& list = airlock ? sm->ship.vOuterAirlocks : sm->ship.vDoorList;
    if (index < 0 || (size_t)index >= vsz(list)) return false;
    Door* d = list._start[index];
    if (!sane(d)) return false;
    if (open) { SYM(op, void (*)(Door*), "_ZN4Door4OpenEv"); op(d); }
    else { SYM(cl, void (*)(Door*), "_ZN4Door5CloseEv"); cl(d); }
    return true;
}

bool set_paused(bool p) {
    CommandGui* g = gui();
    if (!g) return false;
    SYM(sp, void (*)(CommandGui*, bool, bool), "_ZN10CommandGui9SetPausedEbb");
    sp(g, p, false);
    return true;
}
bool paused() { CommandGui* g = gui(); return g && g->bPaused; }

bool map_click(int x, int y) {
    CommandGui* g = gui();
    if (!g || !sane(g->starMap)) return false;
    SYM(mc, void (*)(StarMap*, int, int), "_ZN7StarMap10MouseClickEii");
    mc(g->starMap, x, y);
    return true;
}
bool map_close() {
    CommandGui* g = gui();
    if (!g || !sane(g->starMap)) return false;
    SYM(cl, void (*)(StarMap*), "_ZN7StarMap5CloseEv");
    cl(g->starMap);
    return true;
}
bool choice_click(int x, int y) {
    CommandGui* g = gui();
    if (!g) return false;
    SYM(mc, void (*)(ChoiceBox*, int, int), "_ZN9ChoiceBox10MouseClickEii");
    mc(&g->choiceBox, x, y);
    return true;
}
bool store_click(int x, int y) {
    CommandGui* g = gui();
    if (!g) return false;
    SYM(mc, void (*)(TabbedWindow*, int, int), "_ZN5Store10MouseClickEii");
    // the store is one of the tabbed window's pages; its MouseClick expects the Store itself
    const TabbedWindow& tw = g->storeScreens;
    for (size_t i = 0; i < vsz(tw.windows); i++) {
        FocusWindow* w = tw.windows._start[i];
        if (!sane(w) || w == (FocusWindow*)&g->upgradeScreen) continue;
        // the equipment and crew pages sit inside CommandGui; anything else is the Store
        if ((char*)w >= (char*)g && (char*)w < (char*)g + sizeof(CommandGui)) continue;
        mc((TabbedWindow*)w, x, y);
        return true;
    }
    return false;
}
bool equip_click(int x, int y) {
    CommandGui* g = gui();
    if (!g) return false;
    SYM(mc, void (*)(void*, int, int), "_ZN9Equipment10MouseClickEii");
    mc(equip_screen(g), x, y);
    return true;
}
bool equip_up(int x, int y) {
    CommandGui* g = gui();
    if (!g) return false;
    SYM(mu, void (*)(void*, int, int), "_ZN9Equipment7MouseUpEii");
    mu(equip_screen(g), x, y);
    return true;
}
bool tab_set(int which, int index) {
    CommandGui* g = gui();
    if (!g || index < 0) return false;
    SYM(st, void (*)(TabbedWindow*, unsigned), "_ZN12TabbedWindow6SetTabEj");
    st(which == 0 ? &g->shipScreens : &g->storeScreens, (unsigned)index);
    return true;
}

} // namespace logic
