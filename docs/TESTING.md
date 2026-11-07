# Testing

## Steam Input check (no game launch)

Caveat: Steam routes a controller to the app whose window has focus. The checker has
no window, so with another game or the desktop focused Steam flips the pad between
apps ("Queueing activation for controller: 0 app: ...") and the checker sees no
origins and few actions. Treat the handle/manifest results as authoritative and use
the in-game log (`data/ensign.log`: "controller connected", "origins for ...",
"first press: ...") for binding verification.

    nix develop -c tools/check-steam-input.sh [--seconds N] [--virtual-pad]

Builds `native/tools/steam_input_check.cpp`, copies `libsteam_api.so` from
`$FTL_DIR/data/amd64/` (default `~/.steam/steam/steamapps/common/FTL Faster Than Light`)
to `~/.cache/ensign/steamcheck/`, writes `steam_appid.txt` (212680) there and runs it
against the real, running Steam client. It checks: `SteamAPI_Init`, the
`SteamInput006/007` interfaces, `SetInputActionManifestFilePath` + `Init`, vtable
sanity (`GetStringForActionOrigin(XBox360_A)` should print "A Button"), handles for
every action set/action in `steam_input/ensign_actions.vdf`, and (if a controller is
connected) input type, binding revision, action origins, rumble and live action
state. Exit status is non-zero if any `[FAIL]` line is printed.

Notes:
- Action/set handles are only non-zero while Steam has a controller attached for
  the app; with no controller the manifest wait times out ("Timed out waiting for
  game mapping!") and every handle is 0. That is not a manifest error.
- `--virtual-pad` starts `tools/_virtual_pad.py` (uinput fake Xbox 360 pad; needs
  write access to /dev/uinput and python evdev, fetched via `nix shell`) and loops
  A, B, dpad up, left stick, right stick. Steam only routes it through Steam Input
  if Steam Input is enabled for Xbox controllers (Steam > Settings > Controller >
  "Enable Steam Input for Xbox controllers") or for FTL (Properties > Controller >
  Enable Steam Input). The pad stops by itself after 120 s (`--seconds N` to change):
  a forgotten virtual pad counts as a connected controller, and although the shim
  now follows whichever controller shows input, a stray one is still confusing.
  `pgrep -af _virtual_pad` shows leftovers.

## Headless scripts

`tools/run-headless.sh --script tests/<name>.txt` runs a dev script against a replica
of the game (`ENSIGN_REPLICA=~/.cache/ensign/replicaN` for parallel runs). The run
stops after 25 s by default; anything that waits for a weapon to charge or several
replicas at once needs `--seconds 60` or more, or the script is cut off mid-way with
nothing failing.

Dev commands (all in `mod/data/ensign/80_dev.lua`): `press <button|action>`, `nav
<dir>`, `stick x y [ticks]`, `focus <kind> <id>`, `panel <name>`, `dump` (screen,
focus, every hit), `wdump` (weapon internals and the live projectile count),
`doordump` (door open flags through the game's own objects), `sysdump <id>`,
`sysdump`, `doorbytes <i>` (raw object bytes beside the fields Hyperspace reports:
how the Door layout was corrected), `kbd <sdl key> [up]` (feed the keyboard layer),
`rawkey <sdl key>` (a real key through the game, exercising the Hyperspace key
events), `logic <Ensign fn> args`, `event <name>` (`GHOST_SHIP` has three choices),
`addsystem`, `power`, `crewto`, `shot <name>` (screenshot in the run's log dir).

Hit `extra` values are only trustworthy where the struct layout has been checked
against the live object; when a flag never changes in the dumps, suspect the layout
before the game (the Door open flag was 4 bytes off until `doorbytes` showed it).
