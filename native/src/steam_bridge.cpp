#include "steam_bridge.h"
#include "steam_input_min.h"
#include "log.h"
#include <dlfcn.h>
#include <map>
#include <cstring>

using namespace steam_input_min;

namespace steam {

static Config g_cfg;
static bool g_configured = false;
static ISteamInput* g_in = nullptr;
static std::string g_status = "uninitialized";
static bool g_initCalled = false;
static bool g_manifestSet = false;

typedef HSteamUser (*GetHSteamUser_t)();
typedef void* (*FindOrCreateUserInterface_t)(HSteamUser, const char*);

static GetHSteamUser_t p_GetHSteamUser = nullptr;
static FindOrCreateUserInterface_t p_FindOrCreate = nullptr;

static InputHandle_t g_handle = 0;
static int g_type = k_ESteamInputType_Unknown;
static std::map<std::string, InputActionSetHandle_t> g_setHandles;
static std::map<std::string, InputDigitalActionHandle_t> g_digHandles;
static std::map<std::string, InputAnalogActionHandle_t> g_anaHandles;
static std::map<std::string, DigitalState> g_dig;
static std::map<std::string, AnalogState> g_ana;
static std::string g_currentSet;            // requested set name (kept even while its handle is unknown)
static InputActionSetHandle_t g_currentSetHandle = 0;
static bool g_handlesPending = false;
static double g_nextHandleRetry = 0;

// Steam parses the manifest asynchronously: handles can be 0 for a while after
// Init. Resolve what is missing and report whether anything is still pending.
static bool resolve_handles() {
    int missing = 0;
    for (auto& s : g_cfg.sets) { if (!g_setHandles[s]) g_setHandles[s] = g_in->GetActionSetHandle(s.c_str()); if (!g_setHandles[s]) missing++; }
    for (auto& d : g_cfg.digital) { if (!g_digHandles[d]) g_digHandles[d] = g_in->GetDigitalActionHandle(d.c_str()); if (!g_digHandles[d]) missing++; }
    for (auto& a : g_cfg.analog) { if (!g_anaHandles[a]) g_anaHandles[a] = g_in->GetAnalogActionHandle(a.c_str()); if (!g_anaHandles[a]) missing++; }
    if (!g_currentSet.empty() && !g_currentSetHandle && g_setHandles[g_currentSet]) {
        g_currentSetHandle = g_setHandles[g_currentSet];
        if (g_handle) g_in->ActivateActionSet(g_handle, g_currentSetHandle);
    }
    return missing == 0;
}

// rumble
static float g_rumbleL = 0, g_rumbleR = 0;
static double g_rumbleEnd = 0, g_rumbleLastSent = 0;
static bool g_rumbleActive = false;
static int g_originLogBudget = 0;   // log the first origin lookups after a connect (diagnostics)

static bool resolve_steam_api() {
    if (p_GetHSteamUser && p_FindOrCreate) return true;
    void* h = dlopen("libsteam_api.so", RTLD_NOW | RTLD_NOLOAD);
    if (!h) h = dlopen("amd64/libsteam_api.so", RTLD_NOW | RTLD_NOLOAD);
    void* base = h ? h : RTLD_DEFAULT;
    p_GetHSteamUser = (GetHSteamUser_t)dlsym(base, "SteamAPI_GetHSteamUser");
    p_FindOrCreate = (FindOrCreateUserInterface_t)dlsym(base, "SteamInternal_FindOrCreateUserInterface");
    if (!p_GetHSteamUser || !p_FindOrCreate) {
        g_status = "libsteam_api.so not loaded (game not started through Steam?)";
        return false;
    }
    return true;
}

bool configure(const Config& cfg) {
    g_cfg = cfg;
    g_configured = true;
    if (g_in) {  // re-resolve handles with the new names
        g_setHandles.clear(); g_digHandles.clear(); g_anaHandles.clear();
        for (auto& s : g_cfg.sets) g_setHandles[s] = g_in->GetActionSetHandle(s.c_str());
        for (auto& d : g_cfg.digital) g_digHandles[d] = g_in->GetDigitalActionHandle(d.c_str());
        for (auto& a : g_cfg.analog) g_anaHandles[a] = g_in->GetAnalogActionHandle(a.c_str());
    }
    return true;
}

bool ready() { return g_in != nullptr && g_initCalled; }
const char* status() { return g_status.c_str(); }

bool try_init() {
    if (ready()) return true;
    if (!g_configured) { g_status = "not configured"; return false; }
    if (!resolve_steam_api()) return false;
    HSteamUser user = p_GetHSteamUser();
    if (user == 0) { g_status = "SteamAPI not initialized yet"; return false; }
    if (!g_in) {
        g_in = (ISteamInput*)p_FindOrCreate(user, STEAMINPUT_INTERFACE_VERSION_006);
        if (!g_in) g_in = (ISteamInput*)p_FindOrCreate(user, STEAMINPUT_INTERFACE_VERSION_007);
        if (!g_in) { g_status = "ISteamInput interface unavailable (old Steam client?)"; return false; }
    }
    if (!g_manifestSet && !g_cfg.manifestPath.empty()) {
        bool ok = g_in->SetInputActionManifestFilePath(g_cfg.manifestPath.c_str());
        ensign::logf("SetInputActionManifestFilePath(%s) -> %s", g_cfg.manifestPath.c_str(), ok ? "ok" : "FAILED");
        g_manifestSet = true;
    }
    g_in->Init(true);
    g_initCalled = true;
    g_in->RunFrame(true);
    bool complete = resolve_handles();
    g_handlesPending = !complete;
    g_nextHandleRetry = ensign::now_seconds() + 0.5;
    g_status = complete ? "ok" : "waiting for Steam to load the action manifest";
    ensign::logf("Steam Input initialized: %s (%zu sets, %zu digital, %zu analog)", g_status.c_str(),
                 g_setHandles.size(), g_digHandles.size(), g_anaHandles.size());
    return true;
}

// Does this controller currently have any action pressed / any stick deflected?
static bool has_input(InputHandle_t h) {
    for (auto& kv : g_digHandles) {
        if (!kv.second) continue;
        InputDigitalActionData_t d = g_in->GetDigitalActionData(h, kv.second);
        if (d.bActive && d.bState) return true;
    }
    for (auto& kv : g_anaHandles) {
        if (!kv.second) continue;
        InputAnalogActionData_t a = g_in->GetAnalogActionData(h, kv.second);
        if (a.bActive && (a.x > 0.2f || a.x < -0.2f || a.y > 0.2f || a.y < -0.2f)) return true;
    }
    return false;
}

static void adopt_controller(InputHandle_t h, const char* why) {
    g_handle = h;
    g_type = g_in->GetInputTypeForHandle(g_handle);
    ensign::logf("controller %s: handle=%llu type=%d (%s) set=%s", why, (unsigned long long)g_handle, g_type, controller_type_name(), g_currentSet.c_str());
    g_originLogBudget = 12;
    if (g_currentSetHandle) g_in->ActivateActionSet(g_handle, g_currentSetHandle);
}

// Follow the controller the player is actually using. Steam may report several
// (a stray virtual pad, a second player's pad, a dock): keep the current one
// while it is connected, but switch to any other that shows input.
static void pick_controller() {
    InputHandle_t handles[STEAM_INPUT_MAX_COUNT];
    int n = g_in->GetConnectedControllers(handles);
    if (n <= 0) {
        if (g_handle) ensign::logf("controller disconnected");
        g_handle = 0; g_type = k_ESteamInputType_Unknown;
        return;
    }
    bool keep = false;
    for (int i = 0; i < n; i++) if (handles[i] == g_handle) keep = true;
    if (!keep) { adopt_controller(handles[0], "connected"); }
    if (n < 2) return;
    // keep our set active on the others too, otherwise their actions never report
    for (int i = 0; i < n; i++)
        if (handles[i] != g_handle && g_currentSetHandle) g_in->ActivateActionSet(handles[i], g_currentSetHandle);
    for (int i = 0; i < n; i++)
        if (handles[i] != g_handle && has_input(handles[i])) { adopt_controller(handles[i], "switched to active"); break; }
}

void poll() {
    if (!ready()) { try_init(); if (!ready()) return; }
    g_in->RunFrame(true);
    if (g_handlesPending && ensign::now_seconds() >= g_nextHandleRetry) {
        g_nextHandleRetry = ensign::now_seconds() + 0.5;
        if (resolve_handles()) {
            g_handlesPending = false;
            g_status = "ok";
            ensign::logf("action manifest handles resolved (set %s)", g_currentSet.c_str());
        }
    }
    pick_controller();
    if (!g_handle) return;
    if (g_currentSetHandle) g_in->ActivateActionSet(g_handle, g_currentSetHandle); // cheap, keeps the set sticky
    for (auto& kv : g_digHandles) {
        if (!kv.second) continue;
        InputDigitalActionData_t d = g_in->GetDigitalActionData(g_handle, kv.second);
        DigitalState& s = g_dig[kv.first];
        s.state = d.bState; s.active = d.bActive;
    }
    for (auto& kv : g_anaHandles) {
        if (!kv.second) continue;
        InputAnalogActionData_t a = g_in->GetAnalogActionData(g_handle, kv.second);
        AnalogState& s = g_ana[kv.first];
        s.x = a.x; s.y = a.y; s.active = a.bActive; s.mode = (int)a.eMode;
    }
    // rumble upkeep: resend periodically, stop at expiry
    double t = ensign::now_seconds();
    if (g_rumbleActive) {
        if (t >= g_rumbleEnd) {
            g_in->TriggerVibration(g_handle, 0, 0);
            g_rumbleActive = false;
        } else if (t - g_rumbleLastSent > 0.05) {
            g_in->TriggerVibration(g_handle, (unsigned short)(g_rumbleL * 65535), (unsigned short)(g_rumbleR * 65535));
            g_rumbleLastSent = t;
        }
    }
}

bool connected() { return ready() && g_handle != 0; }
uint64_t handle() { return g_handle; }
int controller_type() { return g_type; }

const char* controller_type_name() {
    switch (g_type) {
        case k_ESteamInputType_SteamController: return "SteamController";
        case k_ESteamInputType_XBox360Controller: return "XBox360";
        case k_ESteamInputType_XBoxOneController: return "XBoxOne";
        case k_ESteamInputType_GenericGamepad: return "Generic";
        case k_ESteamInputType_PS4Controller: return "PS4";
        case k_ESteamInputType_PS3Controller: return "PS3";
        case k_ESteamInputType_PS5Controller: return "PS5";
        case k_ESteamInputType_SwitchProController: return "SwitchPro";
        case k_ESteamInputType_SwitchJoyConPair: return "JoyConPair";
        case k_ESteamInputType_SwitchJoyConSingle: return "JoyCon";
        case k_ESteamInputType_SteamDeckController: return "SteamDeck";
        case k_ESteamInputType_SteamOSHandheld: return "SteamOSHandheld";
        case k_ESteamInputType_Switch2ProController: return "Switch2Pro";
        case k_ESteamInputType_SteamController2026: return "SteamController2026";
        case k_ESteamInputType_MobileTouch: return "MobileTouch";
        default: return "Unknown";
    }
}

const char* controller_family() {
    switch (g_type) {
        case k_ESteamInputType_XBox360Controller:
        case k_ESteamInputType_XBoxOneController: return "xbox";
        case k_ESteamInputType_PS3Controller:
        case k_ESteamInputType_PS4Controller:
        case k_ESteamInputType_PS5Controller: return "ps";
        case k_ESteamInputType_SwitchProController:
        case k_ESteamInputType_SwitchJoyConPair:
        case k_ESteamInputType_SwitchJoyConSingle:
        case k_ESteamInputType_Switch2ProController: return "nin";
        case k_ESteamInputType_SteamDeckController:
        case k_ESteamInputType_SteamOSHandheld: return "deck";
        case k_ESteamInputType_SteamController:
        case k_ESteamInputType_SteamController2026:
        case k_ESteamInputType_SteamFrameControllerPair: return "steam";
        default: return "generic";
    }
}

bool set_action_set(const std::string& name) {
    if (name == g_currentSet) return g_currentSetHandle != 0;
    g_currentSet = name;                       // remembered even if the handle is not known yet
    auto it = g_setHandles.find(name);
    g_currentSetHandle = (it == g_setHandles.end()) ? 0 : it->second;
    if (!g_currentSetHandle) return false;
    if (ready() && g_handle) g_in->ActivateActionSet(g_handle, g_currentSetHandle);
    return true;
}
const char* current_action_set() { return g_currentSet.c_str(); }

DigitalState digital(const std::string& name) {
    auto it = g_dig.find(name);
    return it == g_dig.end() ? DigitalState{} : it->second;
}
AnalogState analog(const std::string& name) {
    auto it = g_ana.find(name);
    return it == g_ana.end() ? AnalogState{} : it->second;
}

// ---- origin -> glyph name -------------------------------------------------
// Each family's origins appear in a fixed order in EInputActionOrigin; we index
// into per-family tables starting at the family's first value.
static const char* const kXBox360[] = { "xbox_a","xbox_b","xbox_x","xbox_y","xbox_lb","xbox_rb","xbox_menu","xbox_view",
    "xbox_lt","xbox_lt","xbox_rt","xbox_rt","stick_l","stick_l_click","stick_l","stick_l","stick_l","stick_l",
    "stick_r","stick_r_click","stick_r","stick_r","stick_r","stick_r","dpad_up","dpad_down","dpad_left","dpad_right","dpad" };
static const char* const kXBoxOne[] = { "xbox_a","xbox_b","xbox_x","xbox_y","xbox_lb","xbox_rb","xbox_menu","xbox_view",
    "xbox_lt","xbox_lt","xbox_rt","xbox_rt","stick_l","stick_l_click","stick_l","stick_l","stick_l","stick_l",
    "stick_r","stick_r_click","stick_r","stick_r","stick_r","stick_r","dpad_up","dpad_down","dpad_left","dpad_right","dpad",
    "deck_l5","deck_l4","deck_r5","deck_r4","ps_share" };
static const char* const kPS4[] = { "ps_cross","ps_circle","ps_triangle","ps_square","ps_l1","ps_r1","ps_options","ps_share",
    "pad_l","pad_l","pad_l_click","pad_l","pad_l","pad_l","pad_l", "pad_r","pad_r","pad_r_click","pad_r","pad_r","pad_r","pad_r",
    "pad_l","pad_l","pad_l_click","pad_l","pad_l","pad_l","pad_l", "ps_l2","ps_l2","ps_r2","ps_r2",
    "stick_l","stick_l_click","stick_l","stick_l","stick_l","stick_l","stick_r","stick_r_click","stick_r","stick_r","stick_r","stick_r",
    "dpad_up","dpad_down","dpad_left","dpad_right" };
static const char* const kPS5[] = { "ps_cross","ps_circle","ps_triangle","ps_square","ps_l1","ps_r1","ps_options","ps_share","ps_share",
    "pad_l","pad_l","pad_l_click","pad_l","pad_l","pad_l","pad_l", "pad_r","pad_r","pad_r_click","pad_r","pad_r","pad_r","pad_r",
    "pad_l","pad_l","pad_l_click","pad_l","pad_l","pad_l","pad_l", "ps_l2","ps_l2","ps_r2","ps_r2",
    "stick_l","stick_l_click","stick_l","stick_l","stick_l","stick_l","stick_r","stick_r_click","stick_r","stick_r","stick_r","stick_r",
    "dpad_up","dpad_down","dpad_left","dpad_right" };
static const char* const kSwitch[] = { "nin_a","nin_b","nin_x","nin_y","nin_l","nin_r","nin_plus","nin_minus","nin_minus",
    "nin_zl","nin_zl","nin_zr","nin_zr","stick_l","stick_l_click","stick_l","stick_l","stick_l","stick_l",
    "stick_r","stick_r_click","stick_r","stick_r","stick_r","stick_r","dpad_up","dpad_down","dpad_left","dpad_right" };
static const char* const kDeck[] = { "deck_a","deck_b","deck_x","deck_y","deck_l1","deck_r1","deck_menu","deck_view",
    "pad_l","pad_l","pad_l_click","pad_l","pad_l","pad_l","pad_l", "pad_r","pad_r","pad_r_click","pad_r","pad_r","pad_r","pad_r",
    "deck_l2","deck_l2","deck_r2","deck_r2","stick_l","stick_l_click","stick_l","stick_l","stick_l","stick_l","stick_l",
    "stick_r","stick_r_click","stick_r","stick_r","stick_r","stick_r","stick_r","deck_l4","deck_r4","deck_l5","deck_r5",
    "dpad","dpad_up","dpad_down","dpad_left","dpad_right" };
static const char* const kSteamCtl[] = { "deck_a","deck_b","deck_x","deck_y","deck_l1","deck_r1","deck_l4","deck_r4","deck_menu","deck_view",
    "pad_l","pad_l","pad_l_click","pad_l","pad_l","pad_l","pad_l", "pad_r","pad_r","pad_r_click","pad_r","pad_r","pad_r","pad_r",
    "deck_l2","deck_l2","deck_r2","deck_r2","stick_l","stick_l_click","stick_l","stick_l","stick_l","stick_l" };

template <size_t N>
static const char* lookup(int o, int first, const char* const (&tab)[N]) {
    int i = o - first;
    if (i < 0 || (size_t)i >= N) return nullptr;
    return tab[i];
}

// Origins outside the per-family tables: back buttons / grips (drawn with the
// Deck's L4/L5/R4/R5 glyphs), Switch 2, Legion Go. Steam Controller 2026
// origins share the Deck's order, so they use kDeck.
static const char* origin_extra(int o) {
    typedef EInputActionOrigin O;
    switch ((O)o) {
        case k_EInputActionOrigin_PS5_LeftGrip: return "deck_l5";
        case k_EInputActionOrigin_PS5_RightGrip: return "deck_r5";
        case k_EInputActionOrigin_PS5_LeftFn: return "deck_l4";
        case k_EInputActionOrigin_PS5_RightFn: return "deck_r4";
        case k_EInputActionOrigin_Switch_LeftGrip_Lower: return "deck_l5";
        case k_EInputActionOrigin_Switch_LeftGrip_Upper: return "deck_l4";
        case k_EInputActionOrigin_Switch_RightGrip_Lower: return "deck_r5";
        case k_EInputActionOrigin_Switch_RightGrip_Upper: return "deck_r4";
        case k_EInputActionOrigin_Switch2_A: return "nin_a";
        case k_EInputActionOrigin_Switch2_B: return "nin_b";
        case k_EInputActionOrigin_Switch2_X: return "nin_x";
        case k_EInputActionOrigin_Switch2_Y: return "nin_y";
        case k_EInputActionOrigin_Switch2_LeftBumper: return "nin_l";
        case k_EInputActionOrigin_Switch2_RightBumper: return "nin_r";
        case k_EInputActionOrigin_Switch2_Plus: return "nin_plus";
        case k_EInputActionOrigin_Switch2_Minus: return "nin_minus";
        case k_EInputActionOrigin_Switch2_LeftTrigger_Pull:
        case k_EInputActionOrigin_Switch2_LeftTrigger_Click: return "nin_zl";
        case k_EInputActionOrigin_Switch2_RightTrigger_Pull:
        case k_EInputActionOrigin_Switch2_RightTrigger_Click: return "nin_zr";
        case k_EInputActionOrigin_Switch2_LeftStick_Move: return "stick_l";
        case k_EInputActionOrigin_Switch2_LeftStick_Click: return "stick_l_click";
        case k_EInputActionOrigin_Switch2_RightStick_Move: return "stick_r";
        case k_EInputActionOrigin_Switch2_RightStick_Click: return "stick_r_click";
        case k_EInputActionOrigin_Switch2_DPad_Move: return "dpad";
        case k_EInputActionOrigin_Switch2_DPad_North: return "dpad_up";
        case k_EInputActionOrigin_Switch2_DPad_South: return "dpad_down";
        case k_EInputActionOrigin_Switch2_DPad_West: return "dpad_left";
        case k_EInputActionOrigin_Switch2_DPad_East: return "dpad_right";
        case k_EInputActionOrigin_Switch2_GL: return "deck_l5";
        case k_EInputActionOrigin_Switch2_GR: return "deck_r5";
        case k_EInputActionOrigin_LenovoLegionGo_A: return "xbox_a";
        case k_EInputActionOrigin_LenovoLegionGo_B: return "xbox_b";
        case k_EInputActionOrigin_LenovoLegionGo_X: return "xbox_x";
        case k_EInputActionOrigin_LenovoLegionGo_Y: return "xbox_y";
        case k_EInputActionOrigin_LenovoLegionGo_LB: return "xbox_lb";
        case k_EInputActionOrigin_LenovoLegionGo_RB: return "xbox_rb";
        case k_EInputActionOrigin_LenovoLegionGo_Menu: return "xbox_menu";
        case k_EInputActionOrigin_LenovoLegionGo_View: return "xbox_view";
        case k_EInputActionOrigin_LenovoLegionGo_LT_SoftPull:
        case k_EInputActionOrigin_LenovoLegionGo_LT: return "xbox_lt";
        case k_EInputActionOrigin_LenovoLegionGo_RT_SoftPull:
        case k_EInputActionOrigin_LenovoLegionGo_RT: return "xbox_rt";
        case k_EInputActionOrigin_LenovoLegionGo_LeftStick_Move: return "stick_l";
        case k_EInputActionOrigin_LenovoLegionGo_LS: return "stick_l_click";
        case k_EInputActionOrigin_LenovoLegionGo_RightStick_Move: return "stick_r";
        case k_EInputActionOrigin_LenovoLegionGo_RS: return "stick_r_click";
        case k_EInputActionOrigin_LenovoLegionGo_RightPad_Touch:
        case k_EInputActionOrigin_LenovoLegionGo_RightPad_Swipe: return "pad_r";
        case k_EInputActionOrigin_LenovoLegionGo_RightPad_Click: return "pad_r_click";
        case k_EInputActionOrigin_LenovoLegionGo_DPad_Move: return "dpad";
        case k_EInputActionOrigin_LenovoLegionGo_DPad_North: return "dpad_up";
        case k_EInputActionOrigin_LenovoLegionGo_DPad_South: return "dpad_down";
        case k_EInputActionOrigin_LenovoLegionGo_DPad_West: return "dpad_left";
        case k_EInputActionOrigin_LenovoLegionGo_DPad_East: return "dpad_right";
        case k_EInputActionOrigin_Generic_L4: return "deck_l4";
        case k_EInputActionOrigin_Generic_R4: return "deck_r4";
        case k_EInputActionOrigin_Generic_L5: return "deck_l5";
        case k_EInputActionOrigin_Generic_R5: return "deck_r5";
        default: return nullptr;
    }
}

static const char* origin_glyph(int o) {
    const char* g = origin_extra(o);
    if (!g) g = lookup(o, k_EInputActionOrigin_XBox360_A, kXBox360);
    if (!g) g = lookup(o, k_EInputActionOrigin_XBoxOne_A, kXBoxOne);
    if (!g) g = lookup(o, k_EInputActionOrigin_PS4_X, kPS4);
    if (!g) g = lookup(o, k_EInputActionOrigin_PS5_X, kPS5);
    if (!g) g = lookup(o, k_EInputActionOrigin_Switch_A, kSwitch);
    if (!g) g = lookup(o, k_EInputActionOrigin_SteamDeck_A, kDeck);
    if (!g) g = lookup(o, k_EInputActionOrigin_SteamController_A, kSteamCtl);
    if (!g) g = lookup(o, k_EInputActionOrigin_SteamController2026_A, kDeck);
    return g ? g : "unknown";
}

bool origin(const std::string& name, int& originOut, std::string& textOut, std::string& glyphOut) {
    originOut = 0; textOut.clear(); glyphOut = "unknown";
    if (!connected() || !g_currentSetHandle) return false;
    EInputActionOrigin origins[STEAM_INPUT_MAX_ORIGINS];
    int n = 0;
    auto d = g_digHandles.find(name);
    if (d != g_digHandles.end() && d->second) {
        n = g_in->GetDigitalActionOrigins(g_handle, g_currentSetHandle, d->second, origins);
    } else {
        auto a = g_anaHandles.find(name);
        if (a != g_anaHandles.end() && a->second)
            n = g_in->GetAnalogActionOrigins(g_handle, g_currentSetHandle, a->second, origins);
    }
    if (g_originLogBudget > 0) {
        g_originLogBudget--;
        ensign::logf("origins for %s in set %s: %d%s%s", name.c_str(), g_currentSet.c_str(), n, n > 0 ? " first=" : "", n > 0 ? (g_in->GetStringForActionOrigin(origins[0]) ? g_in->GetStringForActionOrigin(origins[0]) : "?") : "");
    }
    if (n <= 0) return false;
    originOut = (int)origins[0];
    const char* s = g_in->GetStringForActionOrigin(origins[0]);
    textOut = s ? s : "";
    glyphOut = origin_glyph(originOut);
    return true;
}

void rumble(float l, float r, int ms) {
    if (!connected()) return;
    g_rumbleL = l < 0 ? 0 : (l > 1 ? 1 : l);
    g_rumbleR = r < 0 ? 0 : (r > 1 ? 1 : r);
    g_rumbleEnd = ensign::now_seconds() + ms / 1000.0;
    g_rumbleActive = true;
    g_in->TriggerVibration(g_handle, (unsigned short)(g_rumbleL * 65535), (unsigned short)(g_rumbleR * 65535));
    g_rumbleLastSent = ensign::now_seconds();
}
void stop_rumble() {
    if (!connected()) return;
    g_rumbleActive = false;
    g_in->TriggerVibration(g_handle, 0, 0);
}
void haptic(int location, int intensity, int gainDb) {
    if (!connected()) return;
    EControllerHapticLocation loc = location == 1 ? k_EControllerHapticLocation_Left
                                  : location == 2 ? k_EControllerHapticLocation_Right : k_EControllerHapticLocation_Both;
    if (intensity < 0) intensity = 0;
    if (intensity > 255) intensity = 255;
    if (g_type == k_ESteamInputType_SteamController) {
        // the original Steam Controller only has the legacy trackpad pulses
        ESteamControllerPad pad = location == 1 ? k_ESteamControllerPad_Left : k_ESteamControllerPad_Right;
        g_in->Legacy_TriggerHapticPulse(g_handle, pad, (unsigned short)(200 + intensity * 10));
        return;
    }
    g_in->TriggerSimpleHapticEvent(g_handle, loc, (uint8)intensity, (char)gainDb, (uint8)intensity, (char)gainDb);
}
void show_binding_panel() { if (connected()) g_in->ShowBindingPanel(g_handle); }

}
