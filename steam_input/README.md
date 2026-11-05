# Ensign Steam Input files

Action Manifest and default per-controller configurations for FTL (AppID 212680).

- `ensign_actions.vdf`: the Action Manifest (actions, localization, config list).
- `configs/controller_*.vdf`: default bindings for neptune (Deck), steamcontroller_gordon, xbox360, xboxone, xboxelite, ps4, ps5, switch_pro, generic.

## Action sets

### InGame
Analog: `nav_move` (joystick_move), `cursor_move` (absolute_mouse).

| Action | Meaning | Gamepad default |
|---|---|---|
| nav_up/down/left/right | Navigate | D-pad |
| (nav_move) | Navigate | Left stick |
| (cursor_move) | Free cursor | Right stick |
| select | Select / Confirm | A / Cross / Switch south |
| back | Back | B / Circle |
| alt | Secondary (depower / deselect) | X / Square |
| info | Info | Y / Triangle |
| panel_prev / panel_next | Panels | LB, RB / L1, R1 |
| power_down / power_up | Decrease / increase power | LT, RT / L2, R2 |
| pause | Pause | Start / Options / + |
| game_menu | Game menu | Back / View / Share / - |
| jump | FTL jump | Right stick click |
| crew_all | Select all crew | Left stick click |
| doors_open / doors_close | All doors | Deck L4 / R4; Steam Controller left / right grip; else unbound |
| autofire / focus_toggle | Autofire, switch ship focus | Deck L5 / R5; else unbound |
| cursor_click | Cursor click | Deck/Steam Controller right pad click; else unbound |
| cursor_rclick, saved_positions, return_positions | | unbound |

Deck extras: right trackpad = cursor_move, left trackpad = nav_move, gyro off. Steam Controller: left pad = D-pad nav_*, right pad = cursor_move, left stick = nav_move; `jump` is unbound (no right stick).

### Menus
Analog: `menu_nav` (joystick_move), `menu_cursor` (absolute_mouse).
menu_up/down/left/right = D-pad; menu_nav = left stick; menu_cursor = right stick (and Deck/Steam Controller right pad); menu_select = A; menu_back = B; menu_alt = X; menu_info = Y; menu_tab_prev/next = LB/RB; menu_pause = Start; menu_escape = Back; menu_click = right stick click (or right pad click); menu_rclick unbound.

Action names are case-sensitive and globally unique across sets.

## How the mod registers it
At runtime the mod calls `SteamInput()->SetInputActionManifestFilePath(<absolute path to ensign_actions.vdf>)` before `Init`/first use (the doc calls the override `SetInputActionManifestPath`; the override is remembered for the rest of the Steam session). Config `path` values are relative to the manifest.

## Local-testing fallback
Valve's IGA doc: create a "controller_config" directory inside the Steam folder, place the file there, and rename it to `game_actions_X.vdf`, where X is the AppID (Linux: `~/.steam/steam/controller_config`; make sure it is `controller_config`, not `controller_base`). So:

    cp ensign_actions.vdf ~/.steam/steam/controller_config/game_actions_212680.vdf

Note: this IGA route uses only the actions/localization; the `configurations` block is for the manifest route.

## Requirements
On desktop Steam, Steam Input must be enabled for FTL (Properties > Controller > Override for FTL > Enable Steam Input).

## Exporting a tuned config
    xdg-open 'steam://dumpcontrollerconfig?appid=212680'

writes a .vdf to /tmp. Replace the matching `configs/controller_*.vdf` with it (check `controller_type`) and keep the `actions` block consistent with the manifest.

## Limitations
Binding syntax was copied from real exported configs, but several details are unverified (see `NOTES.md`): Deck L4/L5 assignment, Start/Back input names, trigger "edge" binding, trackpad modes. Tune in Steam's configurator and re-export if anything misbehaves.
