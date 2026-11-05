// Ensign: controller support for FTL: Faster Than Light, built on Hyperspace.
//
// This shared object is LD_PRELOADed *before* Hyperspace. It interposes
// luaL_newstate so it can register an `Ensign` table into Hyperspace's Lua
// state, and exposes Steam Input, input injection and UI geometry to Lua.
// Everything user-facing (navigation, drawing, rumble policy) lives in Lua.
#include "lua_shim.h"
#include "steam_bridge.h"
#include "game.h"
#include "log.h"
#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>

#ifndef ENSIGN_VERSION
#define ENSIGN_VERSION "dev"
#endif

namespace {

lua_State* g_L = nullptr;
bool g_trace = getenv("ENSIGN_TRACE") != nullptr;
#define TRACE(...) do { if (g_trace) ensign::logf(__VA_ARGS__); } while (0)

bool file_exists(const std::string& p) { struct stat st; return stat(p.c_str(), &st) == 0; }

// ---- Lua bindings -------------------------------------------------------

int l_version(lua_State* L) { lua_pushstring(L, ENSIGN_VERSION); return 1; }

int l_log(lua_State* L) {
    std::string msg;
    int n = lua_gettop(L);
    for (int i = 1; i <= n; i++) {
        size_t len = 0;
        const char* s = lua_tolstring(L, i, &len);
        if (s) msg.append(s, len); else msg += lua_typename(L, lua_type(L, i));
        if (i < n) msg += "\t";
    }
    ensign::logf("[lua] %s", msg.c_str());
    return 0;
}

int l_poll(lua_State* L) {
    steam::poll();
    lua_pushboolean(L, steam::connected());
    return 1;
}
int l_ready(lua_State* L) { lua_pushboolean(L, steam::ready()); return 1; }
int l_status(lua_State* L) { lua_pushstring(L, steam::status()); return 1; }
int l_connected(lua_State* L) { lua_pushboolean(L, steam::connected()); return 1; }
int l_controllerType(lua_State* L) {
    lua_pushinteger(L, steam::controller_type());
    lua_pushstring(L, steam::controller_type_name());
    lua_pushstring(L, steam::controller_family());
    return 3;
}

void read_string_array(lua_State* L, int idx, const char* field, std::vector<std::string>& out) {
    lua_getfield(L, idx, field);
    if (lua_type(L, -1) == LUA_TTABLE) {
        int n = (int)lua_rawlen(L, -1);
        for (int i = 1; i <= n; i++) {
            lua_rawgeti(L, -1, i);
            if (lua_isstring(L, -1)) out.push_back(lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
}

int l_registerActions(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    steam::Config cfg;
    read_string_array(L, 1, "sets", cfg.sets);
    read_string_array(L, 1, "digital", cfg.digital);
    read_string_array(L, 1, "analog", cfg.analog);
    lua_getfield(L, 1, "manifest");
    if (lua_isstring(L, -1)) cfg.manifestPath = lua_tostring(L, -1);
    lua_pop(L, 1);
    if (cfg.manifestPath.empty()) {
        const char* env = getenv("ENSIGN_MANIFEST");
        if (env && *env) cfg.manifestPath = env;
        else {
            std::string p = ensign::self_dir() + "/ensign_steam_input/ensign_actions.vdf";
            if (file_exists(p)) cfg.manifestPath = p;
            else ensign::logf("no action manifest found at %s (relying on Steam's controller_config fallback)", p.c_str());
        }
    }
    steam::configure(cfg);
    bool ok = steam::try_init();
    lua_pushboolean(L, ok);
    lua_pushstring(L, steam::status());
    return 2;
}

int l_setActionSet(lua_State* L) { lua_pushboolean(L, steam::set_action_set(luaL_checkstring(L, 1))); return 1; }
int l_actionSet(lua_State* L) { lua_pushstring(L, steam::current_action_set()); return 1; }

int l_digital(lua_State* L) {
    steam::DigitalState s = steam::digital(luaL_checkstring(L, 1));
    lua_pushboolean(L, s.state);
    lua_pushboolean(L, s.active);
    return 2;
}
int l_analog(lua_State* L) {
    steam::AnalogState s = steam::analog(luaL_checkstring(L, 1));
    lua_pushnumber(L, s.x);
    lua_pushnumber(L, s.y);
    lua_pushboolean(L, s.active);
    lua_pushinteger(L, s.mode);
    return 4;
}
int l_origin(lua_State* L) {
    int o; std::string text, glyph;
    if (!steam::origin(luaL_checkstring(L, 1), o, text, glyph)) { lua_pushnil(L); return 1; }
    lua_pushinteger(L, o);
    lua_pushstring(L, text.c_str());
    lua_pushstring(L, glyph.c_str());
    return 3;
}
int l_rumble(lua_State* L) {
    steam::rumble((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2), (int)luaL_optinteger(L, 3, 100));
    return 0;
}
int l_stopRumble(lua_State* L) { steam::stop_rumble(); return 0; }
int l_haptic(lua_State* L) {
    steam::haptic((int)luaL_optinteger(L, 1, 3), (int)luaL_optinteger(L, 2, 120), (int)luaL_optinteger(L, 3, 0));
    return 0;
}
int l_showBindingPanel(lua_State* L) { steam::show_binding_panel(); return 0; }

int l_mouseMove(lua_State* L) { TRACE("mouseMove %d %d", (int)luaL_checknumber(L, 1), (int)luaL_checknumber(L, 2)); game::mouse_move((int)luaL_checknumber(L, 1), (int)luaL_checknumber(L, 2)); return 0; }
int l_mouseDown(lua_State* L) { TRACE("mouseDown"); game::mouse_down((int)luaL_optinteger(L, 1, 1)); return 0; }
int l_mouseUp(lua_State* L) { TRACE("mouseUp"); game::mouse_up((int)luaL_optinteger(L, 1, 1)); return 0; }
int l_keyDown(lua_State* L) { TRACE("keyDown %d", (int)luaL_checkinteger(L, 1)); game::key_down((int)luaL_checkinteger(L, 1)); return 0; }
int l_keyUp(lua_State* L) { game::key_up((int)luaL_checkinteger(L, 1)); return 0; }
int l_textInput(lua_State* L) { game::text_input((int)luaL_checkinteger(L, 1)); return 0; }

int l_screen(lua_State* L) { TRACE("screen()"); lua_pushstring(L, game::screen().c_str()); TRACE("screen -> %s", lua_tostring(L, -1)); return 1; }

int l_hitboxes(lua_State* L) {
    std::vector<game::Hit> hits;
    TRACE("hitboxes()");
    game::hitboxes(hits);
    TRACE("hitboxes -> %zu", hits.size());
    lua_createtable(L, (int)hits.size(), 0);
    int i = 1;
    for (auto& h : hits) {
        lua_createtable(L, 0, 8);
        lua_pushstring(L, h.kind.c_str()); lua_setfield(L, -2, "kind");
        lua_pushinteger(L, h.id); lua_setfield(L, -2, "id");
        lua_pushinteger(L, h.x); lua_setfield(L, -2, "x");
        lua_pushinteger(L, h.y); lua_setfield(L, -2, "y");
        lua_pushinteger(L, h.w); lua_setfield(L, -2, "w");
        lua_pushinteger(L, h.h); lua_setfield(L, -2, "h");
        lua_pushstring(L, h.label.c_str()); lua_setfield(L, -2, "label");
        lua_pushboolean(L, h.enabled); lua_setfield(L, -2, "enabled");
        lua_pushinteger(L, h.extra); lua_setfield(L, -2, "extra");
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

int l_shipOrigins(lua_State* L) {
    TRACE("shipOrigins");
    lua_pushinteger(L, game::player_ship_x());
    lua_pushinteger(L, game::player_ship_y());
    int ex = 0, ey = 0;
    bool has = game::enemy_ship_origin(ex, ey);
    if (has) { lua_pushinteger(L, ex); lua_pushinteger(L, ey); } else { lua_pushnil(L); lua_pushnil(L); }
    return 4;
}
int l_armamentHover(lua_State* L) { lua_pushboolean(L, game::armament_hover((int)luaL_checkinteger(L, 1), (int)luaL_checkinteger(L, 2))); return 1; }
int l_sysboxHover(lua_State* L) { lua_pushboolean(L, game::sysbox_hover((int)luaL_checkinteger(L, 1))); return 1; }
int l_time(lua_State* L) { lua_pushnumber(L, ensign::now_seconds()); return 1; }

// Developer helpers, enabled only with ENSIGN_DEV=1 (used by the headless test harness).
int l_devReadFile(lua_State* L) {
    if (!getenv("ENSIGN_DEV")) { lua_pushnil(L); return 1; }
    FILE* f = fopen(luaL_checkstring(L, 1), "rb");
    if (!f) { lua_pushnil(L); return 1; }
    std::string data; char buf[4096]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) data.append(buf, n);
    fclose(f);
    lua_pushlstring(L, data.data(), data.size());
    return 1;
}
int l_devWriteFile(lua_State* L) {
    if (!getenv("ENSIGN_DEV")) { lua_pushboolean(L, false); return 1; }
    size_t len = 0;
    const char* s = luaL_checklstring(L, 2, &len);
    FILE* f = fopen(luaL_checkstring(L, 1), "wb");
    if (!f) { lua_pushboolean(L, false); return 1; }
    fwrite(s, 1, len, f); fclose(f);
    lua_pushboolean(L, true);
    return 1;
}
int l_devProbe(lua_State* L) { if (!getenv("ENSIGN_DEV")) { lua_pushnil(L); return 1; } std::string s = game::dev_probe(); ensign::logf("probe:\n%s", s.c_str()); lua_pushstring(L, s.c_str()); return 1; }
int l_devEnabled(lua_State* L) { lua_pushboolean(L, getenv("ENSIGN_DEV") != nullptr); return 1; }
int l_devEnv(lua_State* L) {
    if (!getenv("ENSIGN_DEV")) { lua_pushnil(L); return 1; }
    const char* v = getenv(luaL_checkstring(L, 1));
    if (v) lua_pushstring(L, v); else lua_pushnil(L);
    return 1;
}

const luaL_Reg kFuncs[] = {
    {"version", l_version}, {"log", l_log},
    {"poll", l_poll}, {"ready", l_ready}, {"status", l_status}, {"connected", l_connected},
    {"controllerType", l_controllerType}, {"registerActions", l_registerActions},
    {"setActionSet", l_setActionSet}, {"actionSet", l_actionSet},
    {"digital", l_digital}, {"analog", l_analog}, {"origin", l_origin},
    {"rumble", l_rumble}, {"stopRumble", l_stopRumble}, {"haptic", l_haptic}, {"showBindingPanel", l_showBindingPanel},
    {"mouseMove", l_mouseMove}, {"mouseDown", l_mouseDown}, {"mouseUp", l_mouseUp},
    {"keyDown", l_keyDown}, {"keyUp", l_keyUp}, {"textInput", l_textInput},
    {"screen", l_screen}, {"hitboxes", l_hitboxes}, {"shipOrigins", l_shipOrigins},
    {"armamentHover", l_armamentHover}, {"sysboxHover", l_sysboxHover}, {"time", l_time},
    {"devReadFile", l_devReadFile}, {"devWriteFile", l_devWriteFile}, {"devEnabled", l_devEnabled}, {"devEnv", l_devEnv}, {"devProbe", l_devProbe},
    {nullptr, nullptr}
};

void on_new_state(lua_State* L) {
    if (!luashim::resolve()) {
        ensign::logf("Lua API could not be resolved from the host; Ensign is disabled");
        return;
    }
    g_L = L;
    game::init();
    lua_createtable(L, 0, 40);
    luaL_setfuncs(L, kFuncs, 0);
    lua_pushstring(L, ENSIGN_VERSION); lua_setfield(L, -2, "VERSION");
    lua_setglobal(L, "Ensign");
    ensign::logf("registered Ensign %s into Lua state %p", ENSIGN_VERSION, (void*)L);
}

} // namespace

// Interposed: Hyperspace calls luaL_newstate through the PLT, and because this
// library is preloaded first, the dynamic linker resolves it here.
extern "C" __attribute__((visibility("default"))) lua_State* luaL_newstate(void) {
    typedef lua_State* (*fn_t)(void);
    static fn_t real = nullptr;
    if (!real) real = (fn_t)dlsym(RTLD_NEXT, "luaL_newstate");
    if (!real) {
        ensign::logf("luaL_newstate: no next definition found (is Hyperspace loaded after Ensign?)");
        return nullptr;
    }
    lua_State* L = real();
    if (L) on_new_state(L);
    return L;
}

__attribute__((constructor)) static void ensign_ctor() {
    ensign::log_init(ensign::self_dir());
    ensign::logf("Ensign %s loaded from %s", ENSIGN_VERSION, ensign::self_dir().c_str());
}
