# Sources used (format research)

- https://partner.steamgames.com/doc/features/steam_controller/iga_file (IGA format: actions, input_mode, localization, action_layers)
- https://partner.steamgames.com/doc/features/steam_controller/action_manifest_file (configurations by controller type, "path" relative to manifest)
- https://shared.fastly.steamstatic.com/community_assets/images/steamworks_docs/english/%23library_controllersavedefaulttitle_0.vdf (real Steam Controller config for Defender's Quest: group/preset/gameactions/game_action syntax)
- https://shared.fastly.steamstatic.com/community_assets/images/steamworks_docs/english/defenders_quest_actions.vdf and portal2_actions.vdf (real IGA files)
- https://gist.github.com/abdimoussa98/7cb9bd259040da39d3ca5bb3ecdd46e7 (real controller_neptune config: back-button input names, trackpad/joystick modes, "key_press X, , " convention)

- Controller type names (`controller_triton`, `controller_ps5_edge`, `controller_switch2_pro`, `controller_switch_joycon_pair`, `controller_legion_go(_s)`, `controller_rog_ally`, `controller_zotac_zone`, ...): strings in the Linux Steam client (`steamclient.so`, `steamui.so`), November 2026. Types with a real config in `~/.steam/steam/controller_base/`: neptune, triton, steamcontroller_gordon, xbox360, xboxone, ps3, ps4, ps5, switch_pro, switch_joycon_left/right, legion_go_s, generic.
- Back-button input names: `button_back_left` / `button_back_right` (+ `_upper`) appear in Steam's own templates for neptune, triton, legion_go_s, ps5 (Edge paddles) and single Joy-Cons (SL/SR); `center_trackpad` is the PlayStation touchpad source in the ps4/ps5 templates.

# Unverified (not confirmed by a real example)

- Deck back buttons: button_back_left_upper=L4, button_back_left=L5, button_back_right_upper=R4, button_back_right=R5 (names seen in a real config, L4/L5 assignment assumed).
- button_escape = Start/Options/+, button_menu = Back/View/Share/- (inferred from Steam Controller example).
- Triggers bound via the "edge" input of a "trigger" group with Full_Press (as in the DQ example).
- game_action binding strings use "game_action <Set> <action>, <description>" exactly as in the real DQ config (no trailing ", , ").
- Trackpad as joystick_move for nav_move on Deck, and absolute_mouse on a right_joystick group, are not shown in a real game_action example.
- No gyro groups.
- Xbox Elite paddles, Legion Go back buttons: assumed to use the same four `button_back_*` names as the Deck (upper = P1/P3?). Configs for xboxelite, ps5_edge, switch2_pro, switch_joycon_pair, legion_go, rog_ally and zotac_zone have not been loaded on real hardware; Steam ignores inputs a controller does not have.
- DualSense Edge Fn buttons are not bound (input name unknown).
- Steam may ignore/repair configs if group sources are incomplete; tune in Steam's configurator.

# Multi-binding and layout notes (action redesign)

- Several `"binding"` entries under one activator's `"bindings"` block (same key repeated) is the real spelling: seen in Steam's own configs, e.g. `steamapps/common/Steam Controller Configs/111951489/config/250760/controller_xboxone.vdf` (two `"binding"` lines under one `"bindings"`). Not yet verified for `game_action` bindings specifically. The Python `vdf` module collapses duplicate keys, so validation uses the order-preserving parser in `tools/gen-steam-input.py`.
- Rebinding one verb in Steam's configurator edits only its own `binding` line; the other verbs on that physical input stay.
- Steam's normalised copy of a config appends ", , " to binding strings and adds creator/timestamp/localization fields; the repo files omit those (as the earlier accepted files did). The configs carry the `actions` block (with `legacy_set`) but no `localization` block; localization lives in the manifest only.
- Trigger groups bind only the matching verb: LT group = `system_power_down`, RT group = `system_power_up` (Full_Press on `edge`); the same verbs are also bound on B / A.
- `ship_inventory` = `button_escape` (View/Back), `ship_screens` = `button_menu` (Start/Menu). `pause` lives on a back button (Deck R5, Steam Controller right grip) and on the left stick click on pads without back buttons; in the Menus set both View and Start are `menu_escape`.
- Right stick click is unbound on gamepads and the Deck (the groups keep an empty `inputs` block); `cursor_click` / `menu_click` use the right pad click on Deck and Steam Controller only.
- Binding descriptions are the action titles; titles must not contain commas (the binding string is comma-delimited; the generator asserts this).
- Files are generated: `python3 tools/gen-steam-input.py`. Group ids are assigned sequentially (InGame then Menus); presets reference them.
