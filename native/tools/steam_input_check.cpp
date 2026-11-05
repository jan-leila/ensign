// Standalone check: does the real Steam client accept our ISteamInput vtable
// usage and our action manifest?  Usage:
//   steam_input_check <abs path to ensign_actions.vdf> [listen_seconds]
// Run from a directory containing steam_appid.txt (212680) and libsteam_api.so.
#include <dlfcn.h>
#include <unistd.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include "steam_input_min.h"

using namespace steam_input_min;

static int g_fail = 0;
static void PASS(const char* f, ...) __attribute__((format(printf, 1, 2)));
static void FAIL(const char* f, ...) __attribute__((format(printf, 1, 2)));
static void INFO(const char* f, ...) __attribute__((format(printf, 1, 2)));
#define DEFLOG(name, tag, cnt)                       \
    static void name(const char* f, ...) {           \
        char b[1024]; va_list a; va_start(a, f);     \
        vsnprintf(b, sizeof b, f, a); va_end(a);     \
        printf("%s %s\n", tag, b); fflush(stdout); cnt; }
#include <cstdarg>
DEFLOG(PASS, "[PASS]", (void)0)
DEFLOG(FAIL, "[FAIL]", g_fail++)
DEFLOG(INFO, "[INFO]", (void)0)

// ---- tiny VDF parser ----
struct Node { std::vector<std::pair<std::string, std::shared_ptr<Node>>> kids; std::string val; bool leaf = false; };
static std::vector<std::string> Tokenize(const std::string& s) {
    std::vector<std::string> t;
    for (size_t i = 0; i < s.size();) {
        char c = s[i];
        if (isspace((unsigned char)c)) { i++; continue; }
        if (c == '/' && i + 1 < s.size() && s[i + 1] == '/') { while (i < s.size() && s[i] != '\n') i++; continue; }
        if (c == '{' || c == '}') { t.push_back(std::string(1, c)); i++; continue; }
        if (c == '"') {
            std::string v; i++;
            while (i < s.size() && s[i] != '"') { if (s[i] == '\\' && i + 1 < s.size()) i++; v += s[i++]; }
            i++; t.push_back("\"" + v); continue;
        }
        i++;
    }
    return t;
}
static std::shared_ptr<Node> ParseBlock(const std::vector<std::string>& t, size_t& i) {
    auto n = std::make_shared<Node>();
    while (i < t.size() && t[i] != "}") {
        std::string key = t[i++].substr(1);
        if (i < t.size() && t[i] == "{") { i++; auto c = ParseBlock(t, i); if (i < t.size()) i++; n->kids.push_back({key, c}); }
        else if (i < t.size()) { auto c = std::make_shared<Node>(); c->leaf = true; c->val = t[i++].substr(1); n->kids.push_back({key, c}); }
    }
    return n;
}
static Node* Child(Node* n, const std::string& k) { for (auto& p : n->kids) if (p.first == k) return p.second.get(); return nullptr; }

struct SetDef { std::vector<std::string> digital, analog; };

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <manifest.vdf> [seconds]\n", argv[0]); return 64; }
    std::string manifest = argv[1];
    int listen = argc > 2 ? atoi(argv[2]) : 3;

    // Parse manifest.
    std::ifstream in(manifest);
    if (!in) { FAIL("cannot read manifest %s", manifest.c_str()); return 1; }
    std::stringstream ss; ss << in.rdbuf();
    auto toks = Tokenize(ss.str());
    size_t ti = 0;
    auto root = ParseBlock(toks, ti);
    Node* am = Child(root.get(), "Action Manifest");
    Node* actions = am ? Child(am, "actions") : nullptr;
    if (!actions) { FAIL("manifest has no Action Manifest/actions block"); return 1; }
    std::map<std::string, SetDef> sets;
    std::vector<std::string> setOrder;
    for (auto& p : actions->kids) {
        if (p.second->leaf) continue;
        SetDef d;
        if (Node* b = Child(p.second.get(), "Button")) for (auto& k : b->kids) d.digital.push_back(k.first);
        if (Node* s = Child(p.second.get(), "StickPadGyro")) for (auto& k : s->kids) d.analog.push_back(k.first);
        sets[p.first] = d; setOrder.push_back(p.first);
    }
    INFO("manifest %s: %zu sets", manifest.c_str(), sets.size());
    for (auto& n : setOrder) INFO("  set %s: %zu digital, %zu analog", n.c_str(), sets[n].digital.size(), sets[n].analog.size());

    // Load Steam API.
    void* lib = dlopen("libsteam_api.so", RTLD_NOW);
    if (!lib) { FAIL("dlopen libsteam_api.so: %s", dlerror()); return 1; }
    auto SteamAPI_Init = (bool (*)())dlsym(lib, "SteamAPI_Init");
    auto SteamAPI_Shutdown = (void (*)())dlsym(lib, "SteamAPI_Shutdown");
    auto RunCallbacks = (SteamAPI_RunCallbacks_t)dlsym(lib, "SteamAPI_RunCallbacks");
    auto GetUser = (SteamAPI_GetHSteamUser_t)dlsym(lib, "SteamAPI_GetHSteamUser");
    auto FindIface = (SteamInternal_FindOrCreateUserInterface_t)dlsym(lib, "SteamInternal_FindOrCreateUserInterface");
    if (!SteamAPI_Init || !SteamAPI_Shutdown || !RunCallbacks || !GetUser || !FindIface) {
        FAIL("missing symbols in libsteam_api.so (Init=%p Shutdown=%p RunCallbacks=%p GetHSteamUser=%p FindOrCreate=%p)",
             (void*)SteamAPI_Init, (void*)SteamAPI_Shutdown, (void*)RunCallbacks, (void*)GetUser, (void*)FindIface);
        return 1;
    }
    PASS("dlopen + dlsym of all 5 entry points");

    if (!SteamAPI_Init()) {
        FAIL("SteamAPI_Init() returned false. Steam must be running and the logged-in account must own FTL (AppID 212680; steam_appid.txt must be in the cwd).");
        return 2;
    }
    PASS("SteamAPI_Init()");

    HSteamUser user = GetUser();
    INFO("HSteamUser = %d", user);
    ISteamInput* in006 = (ISteamInput*)FindIface(user, STEAMINPUT_INTERFACE_VERSION_006);
    ISteamInput* in007 = (ISteamInput*)FindIface(user, STEAMINPUT_INTERFACE_VERSION_007);
    if (in006) PASS("FindOrCreateUserInterface(\"SteamInput006\") = %p", (void*)in006); else FAIL("SteamInput006 is null");
    if (in007) PASS("FindOrCreateUserInterface(\"SteamInput007\") = %p", (void*)in007);
    else INFO("SteamInput007 is null (not supported by this Steam client/lib)");
    ISteamInput* si = in006 ? in006 : in007;
    if (!si) { SteamAPI_Shutdown(); return 1; }

    bool r = si->SetInputActionManifestFilePath(manifest.c_str());
    if (r) PASS("SetInputActionManifestFilePath -> true"); else FAIL("SetInputActionManifestFilePath -> false");
    r = si->Init(true);
    if (r) PASS("ISteamInput::Init(true) -> true"); else FAIL("ISteamInput::Init(true) -> false");

    auto pump = [&](int ms) {
        auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        while (std::chrono::steady_clock::now() < end) {
            si->RunFrame(true); RunCallbacks();
            std::this_thread::sleep_for(std::chrono::milliseconds(16));
        }
    };
    pump(2000);

    // Vtable sanity.
    const char* s = si->GetStringForActionOrigin(k_EInputActionOrigin_XBox360_A);
    INFO("GetStringForActionOrigin(XBox360_A) = \"%s\"", s ? s : "(null)");
    if (s && *s) PASS("origin string non-empty"); else FAIL("origin string empty/null (vtable order wrong?)");
    s = si->GetStringForXboxOrigin(k_EXboxOrigin_A);
    INFO("GetStringForXboxOrigin(A) = \"%s\"", s ? s : "(null)");
    if (s && *s) PASS("xbox origin string non-empty"); else FAIL("xbox origin string empty/null (vtable order wrong?)");

    // Handles.
    std::map<std::string, InputActionSetHandle_t> setH;
    std::map<std::string, InputDigitalActionHandle_t> digH;
    std::map<std::string, InputAnalogActionHandle_t> anaH;
    for (auto& n : setOrder) {
        setH[n] = si->GetActionSetHandle(n.c_str());
        if (setH[n]) PASS("action set %s handle = %llu", n.c_str(), (unsigned long long)setH[n]);
        else FAIL("action set %s handle = 0", n.c_str());
    }
    int total = 0, zero = 0;
    for (auto& n : setOrder) {
        for (auto& a : sets[n].digital) {
            auto h = si->GetDigitalActionHandle(a.c_str()); digH[a] = h; total++;
            if (h) INFO("digital %-16s handle=%llu", a.c_str(), (unsigned long long)h);
            else { FAIL("digital %s handle = 0", a.c_str()); zero++; }
        }
        for (auto& a : sets[n].analog) {
            auto h = si->GetAnalogActionHandle(a.c_str()); anaH[a] = h; total++;
            if (h) INFO("analog  %-16s handle=%llu", a.c_str(), (unsigned long long)h);
            else { FAIL("analog %s handle = 0", a.c_str()); zero++; }
        }
    }
    INFO("action handles: %d total, %d zero", total, zero);
    if (!zero) PASS("all %d action handles non-zero", total);

    // Controllers.
    InputHandle_t hs[16] = {};
    int nc = si->GetConnectedControllers(hs);
    for (int w = 0; nc == 0 && w < listen * 60; w++) {  // wait up to `listen` s for a controller to show up
        pump(16); nc = si->GetConnectedControllers(hs);
    }
    INFO("GetConnectedControllers = %d", nc);
    std::set<std::string> fired;
    if (nc > 0) {
        for (int i = 0; i < nc; i++) {
            int maj = -1, min = -1;
            bool ok = si->GetDeviceBindingRevision(hs[i], &maj, &min);
            INFO("controller[%d] handle=%llu inputType=%d bindingRevision=%s %d.%d", i, (unsigned long long)hs[i],
                 (int)si->GetInputTypeForHandle(hs[i]), ok ? "ok" : "none", maj, min);
        }
        InputActionSetHandle_t ig = setH.count("InGame") ? setH["InGame"] : 0;
        const char* origNames[] = {"select", "back", "nav_up"};
        for (int i = 0; i < nc; i++) {
            si->ActivateActionSet(hs[i], ig);
            pump(300);
            for (const char* an : origNames) {
                EInputActionOrigin o[STEAM_INPUT_MAX_ORIGINS] = {};
                int n = si->GetDigitalActionOrigins(hs[i], ig, digH[an], o);
                INFO("controller[%d] origins for %s: %d", i, an, n);
                for (int k = 0; k < n && k < STEAM_INPUT_MAX_ORIGINS; k++) {
                    const char* str = si->GetStringForActionOrigin(o[k]);
                    INFO("    origin %d = \"%s\"", (int)o[k], str ? str : "(null)");
                }
            }
            si->TriggerVibration(hs[i], 20000, 20000);
        }
        INFO("rumble 20000/20000 for 200ms");
        pump(200);
        for (int i = 0; i < nc; i++) si->TriggerVibration(hs[i], 0, 0);
        INFO("rumble stopped");
        // Listen.
        auto end = std::chrono::steady_clock::now() + std::chrono::seconds(listen);
        std::map<std::string, bool> prev;
        while (std::chrono::steady_clock::now() < end) {
            si->RunFrame(true); RunCallbacks();
            for (int i = 0; i < nc; i++) {
                si->ActivateActionSet(hs[i], ig);
                for (auto& n : sets["InGame"].digital) {
                    auto d = si->GetDigitalActionData(hs[i], digH[n]);
                    bool on = d.bActive && d.bState;
                    if (on != prev[n]) { INFO("digital %s %s", n.c_str(), on ? "DOWN" : "up"); }
                    if (on) fired.insert(n);
                    prev[n] = on;
                }
                for (auto& n : sets["InGame"].analog) {
                    auto a = si->GetAnalogActionData(hs[i], anaH[n]);
                    if (a.bActive && (std::fabs(a.x) > 0.01f || std::fabs(a.y) > 0.01f)) {
                        INFO("analog %s = (%.3f, %.3f) mode=%d", n.c_str(), a.x, a.y, (int)a.eMode);
                        fired.insert(n);
                    }
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(16));
        }
        std::string f;
        for (auto& n : fired) f += n + " ";
        INFO("actions that fired: %s", f.empty() ? "(none)" : f.c_str());
    } else {
        INFO("no controllers connected; skipped controller checks");
    }

    si->Shutdown();
    SteamAPI_Shutdown();
    PASS("Shutdown");
    printf("%s (%d FAIL)\n", g_fail ? "RESULT: FAIL" : "RESULT: OK", g_fail);
    return g_fail ? 1 : 0;
}
