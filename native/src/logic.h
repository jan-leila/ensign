// Direct calls into the game's own logic (no mouse or keyboard emulation).
//
// FTL 1.6.13 for Linux is a fixed, non-PIE executable that still carries its
// symbol table, so every function is resolved by mangled name from the running
// binary at startup. Each operation returns false when the game state does not
// allow it (no ship, slot out of range, symbol missing) so the Lua side can fall
// back to the screen path.
#pragma once

namespace logic {

bool init();                                   // resolve symbols; logs what is missing
const char* status();                          // "ok" or a short description of what failed

// in flight -----------------------------------------------------------------
bool sys_power(int systemId, int delta);       // +1 adds a bar (reactor permitting), -1 removes one
bool weapon_power(int slot, bool on);          // WeaponSystem::PowerWeapon / DePowerWeapon
bool drone_power(int slot, bool on);           // DroneSystem::PowerDrone / DePowerDrone
bool arm_weapon(int slot);                     // slot >= 0 arms it; -1 disarms everything
bool room_center(int shipId, int roomId, float& x, float& y);   // world coordinates for aiming
bool fire_at(int targetShipId, int npoints, const float* xy);  // armed weapon -> points (1, or 2 for beams)
bool swap_weapons(int a, int b);
bool swap_drones(int a, int b);
bool move_crew(int crewIndex, int roomId);     // index into ShipManager::vCrewList
bool door(bool airlock, int index, bool open); // index into vDoorList / vOuterAirlocks
bool set_paused(bool paused);
bool paused();

// screens --------------------------------------------------------------------
bool map_click(int x, int y);                  // StarMap::MouseClick (beacon / button centres)
bool map_close();
bool choice_click(int x, int y);               // ChoiceBox::MouseClick
bool store_click(int x, int y);                // Store::MouseClick
bool equip_click(int x, int y);                // Equipment::MouseClick (start of a pick-up)
bool equip_up(int x, int y);                   // Equipment::MouseUp (drop)
bool tab_set(int which, int index);            // 0 = ship screens, 1 = store screens
}
