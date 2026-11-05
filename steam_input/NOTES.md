# Sources used (format research)

- https://partner.steamgames.com/doc/features/steam_controller/iga_file (IGA format: actions, input_mode, localization, action_layers)
- https://partner.steamgames.com/doc/features/steam_controller/action_manifest_file (configurations by controller type, "path" relative to manifest)
- https://shared.fastly.steamstatic.com/community_assets/images/steamworks_docs/english/%23library_controllersavedefaulttitle_0.vdf (real Steam Controller config for Defender's Quest: group/preset/gameactions/game_action syntax)
- https://shared.fastly.steamstatic.com/community_assets/images/steamworks_docs/english/defenders_quest_actions.vdf and portal2_actions.vdf (real IGA files)
- https://gist.github.com/abdimoussa98/7cb9bd259040da39d3ca5bb3ecdd46e7 (real controller_neptune config: back-button input names, trackpad/joystick modes, "key_press X, , " convention)

# Unverified (not confirmed by a real example)

- Deck back buttons: button_back_left_upper=L4, button_back_left=L5, button_back_right_upper=R4, button_back_right=R5 (names seen in a real config, L4/L5 assignment assumed).
- button_escape = Start/Options/+, button_menu = Back/View/Share/- (inferred from Steam Controller example).
- Triggers bound via the "edge" input of a "trigger" group with Full_Press (as in the DQ example).
- game_action binding strings use "game_action <Set> <action>, <description>" exactly as in the real DQ config (no trailing ", , ").
- Trackpad as joystick_move for nav_move on Deck, and absolute_mouse on a right_joystick group, are not shown in a real game_action example.
- No gyro groups, no Xbox Elite paddle bindings, no PS touchpad bindings.
- Steam may ignore/repair configs if group sources are incomplete; tune in Steam's configurator.
