# Ensign — controller support for FTL: Faster Than Light

Ensign adds full gamepad support to FTL (Linux, Steam build 1.6.13) through
**Steam Input**, so every binding can be remapped in Steam's controller
configurator and the same mod works on a Steam Deck, Xbox, PlayStation,
Switch Pro or generic pad. It is built on the
[Hyperspace](https://github.com/FTL-Hyperspace/FTL-Hyperspace) mod framework.

## What it does

* **A selection frame instead of a mouse.** The d-pad or left stick moves a
  frame between the things you can act on; the game's own pointer follows it
  (and is hidden), so hover highlights, tooltips and aiming previews behave
  exactly as with a mouse. Pushing past the edge of a group crosses into the
  neighbouring one (ship ↔ systems below, crew list left, controls above, enemy
  right), landing on the element in the direction of travel.
* **Groups, rotated with the bumpers** (or jumped to with their own
  actions): *crew* (the portraits), *power* (the reactor boxes), *weapons* and
  *drones* (their slots, empty ones skipped; each only while the ship has that
  system) and *ship* (rooms; the enemy ship joins the rotation when present and
  is forced while something is aimed).
* **Ship.** A on a room opens *detail mode*, which walks the units and doors:
  within a room between its units, out of a room through the door on that
  wall first and then into the next room. A toggles a unit in a persistent
  multi-selection or opens/closes a door; B returns to room mode. With units
  selected, A on a room sends them, B deselects all, X reopens detail mode to
  add more. Pointing freely with the touchpad or right stick works too: A over
  a room sends the selection there or opens that room. Y is always the FTL jump.
* **Systems.** On a reactor box A adds power, B removes it, X turns it off
  (the triggers add/remove too). On cloaking or the backup battery X fires
  them; on hacking or mind control X arms them and A on an enemy room picks
  the target; on the teleporter X arms a send, X again switches to return,
  and A on the enemy room beams the crew. B cancels any of these. On a weapon or drone slot A powers it up and,
  once powered, aims it (hold A and move to re-order); B cancels an aim and
  then powers the slot off; X powers and aims in one go. Aiming locks the
  frame to the enemy ship's rooms, beams take two points, bombs and the
  teleporter can swap ships.
* **Every verb is its own Steam action** (`room_open`, `detail_toggle_door`,
  `system_off`, `slot_retarget`, ...), all on the natural buttons by default,
  so any single one can be rebound without moving the others.
* **Screens**: Start opens the ship screens (systems / crew / inventory,
  bumpers switch tabs) and View goes straight to the inventory; A picks an
  item or crew member up and A drops it, B puts it back. Pause sits on a back
  button (Deck R5 / Steam Controller right grip; left stick click on pads
  without them). Event choices, the store, options, the hangar and the main
  menu use the same frame.
* **Star map.** Only beacons you can jump to are targets: the d-pad steps
  between them and the stick points at them (the beacon in the stick's
  direction from your current one lights up). A jumps, X waits a turn, Y
  toggles the distress beacon, B closes the map.
* **Feedback.** Rumble on hull hits, shield hits, weapon fire, jumps,
  boarders, crew deaths and low hull; trackpad haptic ticks on Deck / Steam
  Controller; glyph-based button hints in FTL's own style, drawn from the
  controller you are actually holding. The hints sit in the bottom-right
  corner; while they are visible the game's subsystem group is raised to make
  room (its frame is rebuilt at the new spot), and it drops back as soon as
  you pick up the mouse.

Default bindings and the action list are in [`steam_input/README.md`](steam_input/README.md).
Install instructions are in [`docs/INSTALL.md`](docs/INSTALL.md).

## How it works

```
Steam client ── Steam Input API ──┐
                                  ▼
FTL.amd64 ◄── LD_PRELOAD ── ensign.amd64.so  (native/)   reads UI geometry, calls the
     ▲                             │                      game's logic directly, talks
     │                             │                      to Steam Input
     └──── LD_PRELOAD ── Hyperspace.so  ◄── Lua `Ensign` table ──┘
                              │
                              └── mod/data/ensign/*.lua (Ensign.ftl)  navigation, panels,
                                                                       HUD, rumble policy
```

* `native/` builds `build/ensign.amd64.so`. It must be preloaded **before**
  Hyperspace: it interposes `luaL_newstate` to register an `Ensign` table in
  Hyperspace's Lua state, reads the UI structs (`native/third_party/`) to
  enumerate the elements on each screen, and drives `ISteamInput` through its
  vtable (`native/steam_input_min.h`, no SDK required) including rumble and
  haptics.
* **Actions are direct calls into the game's logic**, not emulated clicks
  (`native/src/logic.cpp`). FTL 1.6.13 for Linux is a fixed, non-PIE binary
  that still carries its symbol table, so the shim resolves functions such as
  `CrewMember::MoveToRoom`, `ShipManager::IncreaseSystemPower`,
  `WeaponSystem::PowerWeapon`, `WeaponControl::SelectArmament` / `Fire`,
  `Door::Open` / `Close`, `CommandGui::SetPaused`, `StarMap::MouseClick`,
  `ChoiceBox::MouseClick`, `Store::MouseClick`, `Equipment::MouseClick` /
  `MouseUp` and `TabbedWindow::SetTab` by mangled name at startup and calls
  them with the same arguments the game's own handlers would. The Lua side
  falls back to the game's mouse handlers (also called directly, in the
  logical 1280x720 space) only for plain UI buttons and the few screens that
  have no logic entry point.
* `mod/` is the `.ftl` mod (packed to `dist/Ensign.ftl`): Lua scripts loaded
  through `hyperspace.xml`, plus FTL-style glyph art in `img/ensign/`.
* `steam_input/` holds the Steam Input action manifest and default
  configurations per controller type. The shim registers the manifest with
  `SetInputActionManifestFilePath`, so no Steamworks upload is needed.
* `tools/` has the headless ftl.dat patcher (`ftldat.py`, Slipstream-compatible
  append semantics), the installer, and `run-headless.sh`, which runs the game
  under Xvfb with a scripted driver for automated UI tests.

## Building and testing (NixOS)

```sh
nix develop                      # toolchain, lua/luacheck, python, imagemagick, xvfb-run, steam-run
make -C native                   # -> build/ensign.amd64.so
tools/build-ftl.sh               # -> dist/Ensign.ftl
luacheck mod/data/ensign         # lint the Lua
tools/run-headless.sh --seconds 60 --script tests/flight.txt   # scripted smoke test
tools/install.sh                 # install into the Steam FTL directory (reversible)
tools/uninstall.sh
```

The headless runner builds a replica of the game directory in
`~/.cache/ensign/replica` (override with `ENSIGN_REPLICA` to run several in
parallel), never touching the real install, and reports the native log
(`ensign.log`), the driver output (`ensign_test_out.txt`) and screenshots
requested by the script (`shot <name>`). The driver can force game states
(`event PIRATE`, `event STORE`, `addweapon BEAM_1 2`, `power 3 2`, `panel
weapons`, `fakepad xbox`); see `mod/data/ensign/80_dev.lua`. `tools/check-steam-input.sh`
talks to the running Steam client with the real manifest (optionally with a
virtual Xbox pad); see `docs/TESTING.md`. Steam Input inside the game only
works when it is launched through Steam.

## Repository layout

| Path | Contents |
| --- | --- |
| `native/src/` | shim sources: `ensign.cpp` (Lua API), `steam_bridge.cpp`, `game.cpp` (readers + injection), `lua_shim*` |
| `native/third_party/` | FTL struct layouts (from Hyperspace, GPL-3.0-or-later) and verified offsets |
| `mod/data/ensign/` | Lua: `00_core`, `10_input`, `20_nav`, `30_cursor`, `40_menus`, `50_game`, `60_hud`, `70_feedback`, `80_dev`, `99_main` |
| `mod/img/ensign/` | generated glyphs and UI pieces (`tools/gen-glyphs.py`) |
| `steam_input/` | action manifest, per-controller default configs |
| `tools/` | `ftldat.py`, `install.sh`, `uninstall.sh`, `build-ftl.sh`, `run-headless.sh` |
| `tests/` | driver scripts for `run-headless.sh` |
| `docs/` | install guide |

## License

GPL-3.0-or-later (the game struct header is derived from Hyperspace, which is
GPL-3.0-or-later; Steam Input interface declarations are reproduced for ABI
compatibility, Steamworks is a trademark of Valve Corporation).
