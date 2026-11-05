// Steam Input bridge: talks to the Steam client through the libsteam_api.so the
// game already loaded, using the ISteamInput vtable (no SDK needed).
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace steam {

struct DigitalState { bool state = false; bool active = false; };
struct AnalogState  { float x = 0, y = 0; bool active = false; int mode = 0; };

struct Config {
    std::string manifestPath;           // absolute path to ensign_actions.vdf ("" = don't set)
    std::vector<std::string> sets;      // action set names
    std::vector<std::string> digital;   // digital action names
    std::vector<std::string> analog;    // analog action names
};

// Lifecycle
bool configure(const Config& cfg);      // may be called before Steam is ready; stores config
bool try_init();                        // idempotent; returns true once ISteamInput is usable
const char* status();                   // human readable state
bool ready();

// Per frame
void poll();                            // RunFrame + refresh cached action data + rumble upkeep
bool connected();
uint64_t handle();                      // current controller handle (0 if none)
int controller_type();                  // ESteamInputType
const char* controller_type_name();
const char* controller_family();        // "xbox" | "ps" | "nin" | "deck" | "steam" | "generic"

// Actions
bool set_action_set(const std::string& name);
const char* current_action_set();
DigitalState digital(const std::string& name);
AnalogState analog(const std::string& name);
// First origin bound to the action in the current set: enum value, Steam's string, our glyph name.
bool origin(const std::string& name, int& originOut, std::string& textOut, std::string& glyphOut);

// Feedback
void rumble(float left01, float right01, int ms);
void stop_rumble();
void haptic(int location, int intensity, int gainDb);
void show_binding_panel();

}
