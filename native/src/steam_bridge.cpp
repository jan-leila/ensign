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
static std::string g_currentSet;
static InputActionSetHandle_t g_currentSetHandle = 0;

// rumble
static float g_rumbleL = 0, g_rumbleR = 0;
static double g_rumbleEnd = 0, g_rumbleLastSent = 0;
static bool g_rumbleActive = false;

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
    for (auto& s : g_cfg.sets) g_setHandles[s] = g_in->GetActionSetHandle(s.c_str());
    for (auto& d : g_cfg.digital) g_digHandles[d] = g_in->GetDigitalActionHandle(d.c_str());
    for (auto& a : g_cfg.analog) g_anaHandles[a] = g_in->GetAnalogActionHandle(a.c_str());
    int unresolved = 0;
    for (auto& kv : g_setHandles) if (!kv.second) { ensign::logf("action set '%s' has no handle", kv.first.c_str()); unresolved++; }
    for (auto& kv : g_digHandles) if (!kv.second) unresolved++;
    for (auto& kv : g_anaHandles) if (!kv.second) unresolved++;
    g_status = unresolved ? "initialized (some actions unresolved; manifest missing?)" : "ok";
    ensign::logf("Steam Input initialized: %s (%zu sets, %zu digital, %zu analog)", g_status.c_str(),
                 g_setHandles.size(), g_digHandles.size(), g_anaHandles.size());
    return true;
}

static void pick_controller() {
    InputHandle_t handles[STEAM_INPUT_MAX_COUNT];
    int n = g_in->GetConnectedControllers(handles);
    if (n <= 0) {
        if (g_handle) ensign::logf("controller disconnected");
        g_handle = 0; g_type = k_ESteamInputType_Unknown;
        return;
    }
    // keep the current one if still present, else take the first
    bool keep = false;
    for (int i = 0; i < n; i++) if (handles[i] == g_handle) keep = true;
    if (!keep) {
        g_handle = handles[0];
        g_type = g_in->GetInputTypeForHandle(g_handle);
        ensign::logf("controller connected: handle=%llu type=%d (%s)", (unsigned long long)g_handle, g_type, controller_type_name());
        if (g_currentSetHandle) g_in->ActivateActionSet(g_handle, g_currentSetHandle);
    }
}

void poll() {
    if (!ready()) { try_init(); if (!ready()) return; }
    g_in->RunFrame(true);
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
        case k_ESteamInputType_SteamController2026: return "steam";
        default: return "generic";
    }
}

bool set_action_set(const std::string& name) {
    if (name == g_currentSet) return true;
    auto it = g_setHandles.find(name);
    if (it == g_setHandles.end() || !it->second) return false;
    g_currentSet = name;
    g_currentSetHandle = it->second;
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

static const char* origin_glyph(int o) {
    const char* g = nullptr;
    if (!g) g = lookup(o, k_EInputActionOrigin_XBox360_A, kXBox360);
    if (!g) g = lookup(o, k_EInputActionOrigin_XBoxOne_A, kXBoxOne);
    if (!g) g = lookup(o, k_EInputActionOrigin_PS4_X, kPS4);
    if (!g) g = lookup(o, k_EInputActionOrigin_PS5_X, kPS5);
    if (!g) g = lookup(o, k_EInputActionOrigin_Switch_A, kSwitch);
    if (!g) g = lookup(o, k_EInputActionOrigin_SteamDeck_A, kDeck);
    if (!g) g = lookup(o, k_EInputActionOrigin_SteamController_A, kSteamCtl);
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
