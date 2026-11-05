# Ensign — controller support for FTL: Faster Than Light

Ensign adds full gamepad support to FTL (Linux, Steam build 1.6.13) through
**Steam Input**, so every binding can be remapped in Steam's controller
configurator and the same mod works on a Steam Deck, Xbox, PlayStation,
Switch Pro or generic pad. It is built on the
[Hyperspace](https://github.com/FTL-Hyperspace/FTL-Hyperspace) mod framework.

## What it does

* **A selection frame instead of a mouse.** The d-pad or left stick moves a
  frame between the things you can act on; the game's own pointer follows it,
  so hover highlights, tooltips and aiming previews look exactly as with a mouse.
* **Panels** (bumpers cycle them, `focus_toggle` jumps between the ships):
  *your ship*, *enemy ship*, *power*, *weapons*, *drones*, *crew*, *controls*.
* **Crew orders.** Select a room on your ship to look at the crew inside it,
  pick one (or add several with the secondary button), go back to the room
  view and choose a destination. The crew portraits on the left work too.
* **Power.** On the power panel the triggers add and remove power from the
  system under the frame; `info` activates systems with buttons (cloak,
  hacking, mind control, teleporter, battery, doors).
* **Weapons and drones.** Select powers or arms a slot, the secondary button
  depowers it. While a weapon, hacking, mind control or the teleporter is
  armed the frame is locked to valid targets; beams move the cursor freely
  over the enemy ship and take two points; bombs and the teleporter can swap
  ships with `focus_toggle`.
* **Everything else**: pause, the FTL jump, the star map, event choices,
  the store, upgrade/crew/cargo screens, options, the hangar and the main menu
  are navigated with the same frame (`panel_prev/next` switch tabs).
* **Feedback.** Rumble on hull hits, shield hits, weapon fire, jumps,
  boarders, crew deaths and low hull; trackpad haptic ticks on Deck / Steam
  Controller; glyph-based button hints in FTL's own style, drawn from the
  controller you are actually holding.

Default bindings and the action list are in [`steam_input/README.md`](steam_input/README.md).
Install instructions are in [`docs/INSTALL.md`](docs/INSTALL.md).

## How it works

```
Steam client ── Steam Input API ──┐
                                  ▼
FTL.amd64 ◄── LD_PRELOAD ── ensign.amd64.so  (native/)   reads UI geometry, injects
     ▲                             │                      input, talks to Steam Input
     └──── LD_PRELOAD ── Hyperspace.so  ◄── Lua `Ensign` table ──┘
                              │
                              └── mod/data/ensign/*.lua (Ensign.ftl)  navigation, panels,
                                                                       HUD, rumble policy
```

* `native/` builds `build/ensign.amd64.so`. It must be preloaded **before**
  Hyperspace: it interposes `luaL_newstate` to register an `Ensign` table in
  Hyperspace's Lua state, calls the game's own input handlers (exported by
  Hyperspace) to inject mouse/keyboard events in the game's logical
  1280x720 space, reads the UI structs (`native/third_party/`) to enumerate
  clickable rectangles per screen, and drives `ISteamInput` through its vtable
  (`native/steam_input_min.h`, no SDK required) including rumble and haptics.
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
