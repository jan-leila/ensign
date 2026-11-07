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
