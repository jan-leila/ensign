// Access to the running game: CApp pointer, input injection through the
// game's own handlers (exported by Hyperspace), and read-only UI geometry.
#pragma once
#include <string>
#include <vector>

namespace game {

bool init();                       // resolve symbols; safe to call repeatedly
bool available();                  // CApp exists

// Input injection. Coordinates are in the game's logical 1280x720 space.
void mouse_move(int lx, int ly);
void mouse_down(int button);       // 1 = left, 2 = middle, 3 = right
void mouse_up(int button);
void key_down(int sdlkey);
void key_up(int sdlkey);
void text_input(int ch);
void logical_to_raw(int lx, int ly, int& rx, int& ry);
void raw_to_logical(int rx, int ry, int& lx, int& ly);

// UI state
std::string screen();              // see game.cpp for the list of names

struct Hit {
    std::string kind;              // "button","choice","sysbox","crewbox","armament","room","door","location","sector",...
    int id = 0;                    // index / room id / system id / location index
    int x = 0, y = 0, w = 0, h = 0;
    std::string label;
    bool enabled = true;
    int extra = 0;                 // shipId for rooms/doors, systemId for armaments, etc.
};
void hitboxes(std::vector<Hit>& out);

// Misc readers
bool mouse_is_hidden();
int  player_ship_x(); int player_ship_y();      // CommandGui.shipPosition
bool enemy_ship_origin(int& x, int& y);          // combatControl.position + targetPosition
bool armament_hover(int systemId, int index);     // ArmamentBox.mouseHover (calibration aid)
bool sysbox_hover(int systemId);
std::string dev_probe();
}
