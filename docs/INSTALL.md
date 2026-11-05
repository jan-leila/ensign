# Installing Ensign

Ensign adds controller support to FTL: Faster Than Light (Linux Steam build 1.6.13). It consists of:

- **Hyperspace** (mod framework, loaded via `LD_PRELOAD`)
- **`Ensign.ftl`** (data/Lua mod patched into `ftl.dat`)
- **`ensign.amd64.so`** (native hook, also loaded via `LD_PRELOAD`)
- **Steam Input files** (action manifest and default bindings)

The installer does all of it, is safe to re-run, and keeps backups so it can be undone.

## Requirements

- FTL installed through Steam (Linux native build, not Proton).
- `bash`, `curl`, `python3` (3.8+). No other Python packages are needed.
- To build the native hook yourself: `gcc` and `make` (or use `nix develop` in the repo).

## Desktop Linux

1. Get the repo and (optionally) build the native hook:

   ```sh
   git clone <repo-url> ensign && cd ensign
   nix develop            # optional, NixOS: gives you python3, gcc, make, ...
   make -C native         # produces build/ensign.amd64.so
   ```

2. Make sure FTL is unmodified. If you have used other mods before, in Steam
   right-click FTL > Properties > Installed Files > **Verify integrity of game files**.
   (The installer refuses to continue if `ftl.dat` already contains Hyperspace data and no vanilla backup exists.)
   If you previously launched Hyperspace via a Steam launch option containing `LD_PRELOAD=...`, clear that launch option.

3. Run the installer:

   ```sh
   tools/install.sh
   ```

   Useful options:

   | Option | Meaning |
   |---|---|
   | `--ftl-dir DIR` | FTL install directory (default: `$FTL_DIR`, else `~/.steam/steam/steamapps/common/FTL Faster Than Light`) |
   | `--hyperspace-version VER` | Hyperspace release (default `1.23.2`) |
   | `--no-download` | Use the Hyperspace zip already in `~/.cache/ensign/` (`FTL.Hyperspace.VER-Linux.zip`) |
   | `--steam-dir DIR` | Steam root used for the controller_config fallback (default `~/.steam/steam`) |
   | `--dry-run` | Print what would happen and change nothing |

   What it does, in order: backs up `data/ftl.dat` to `data/ftl.dat.vanilla` (once);
   downloads the Hyperspace release and installs `Hyperspace.ftl` and `Hyperspace.1.6.13.amd64.so` into `data/`;
   builds `dist/Ensign.ftl`; copies `build/ensign.amd64.so` into `data/`;
   writes a fresh `ftl.dat` = vanilla + Hyperspace + Ensign;
   copies `steam_input/` to `data/ensign_steam_input/` and `ensign_actions.vdf` to
   `~/.steam/steam/controller_config/game_actions_212680.vdf`;
   backs up `data/FTL` to `data/FTL.ensign-orig` and inserts a block between
   `# >>> ensign >>>` / `# <<< ensign <<<` that sets `LD_PRELOAD` (ensign first, Hyperspace second).

   If `build/ensign.amd64.so` is missing the installer warns and installs Hyperspace + `Ensign.ftl` only;
   build it and run the installer again.

4. **Enable Steam Input for FTL.** In Steam: right-click FTL > Properties > Controller >
   set *Override for FTL: Faster Than Light* to **Enable Steam Input** (the default "Use Default Settings"
   is not enough for games without native Steam Input support). Then launch FTL from Steam.

## Steam Deck

Use **Desktop Mode** and open Konsole. Steam lives in `~/.local/share/Steam` (with `~/.steam/steam` as a symlink to it),
so the default paths normally work unchanged.

```sh
git clone <repo-url> ensign && cd ensign
tools/install.sh           # if build/ensign.amd64.so was built elsewhere, copy it into build/ first
```

If your FTL is on an SD card, pass its location:

```sh
tools/install.sh --ftl-dir "/run/media/mmcblk0p1/steamapps/common/FTL Faster Than Light"
```

Then in Game Mode: FTL > Controller icon > Controller Settings > pick the **Ensign** layout from Templates
(or Community layouts). Steam Input is on by default on the Deck. SteamOS keeps `python3`, `curl` and `bash` available in Desktop Mode;
building the native hook on the Deck needs a toolchain, so build it on another machine and copy `build/ensign.amd64.so` over.

## Uninstall

```sh
tools/uninstall.sh                    # full revert: original launcher, vanilla ftl.dat, Ensign files removed
tools/uninstall.sh --keep-hyperspace  # keep Hyperspace (vanilla + Hyperspace.ftl, Hyperspace left in LD_PRELOAD)
tools/uninstall.sh --dry-run          # preview
```

It restores `data/FTL` from `FTL.ensign-orig` and `data/ftl.dat` from `ftl.dat.vanilla`, and removes
`data/ensign.amd64.so`, `data/ensign_steam_input/` and `controller_config/game_actions_212680.vdf`.
`data/ftl.dat.vanilla` (about 280 MB) is kept; delete it once you no longer need it.
Steam's "Verify integrity of game files" is always a valid fallback. It will restore stock `ftl.dat` and `data/FTL`
(if you do this, delete `ftl.dat.vanilla` and `FTL.ensign-orig` so the next install makes fresh backups).

After a game update, run `tools/install.sh` again if Steam replaced `ftl.dat` or `data/FTL`.
(If `ftl.dat.vanilla` is stale after an update, delete it and verify game files first.)

## Troubleshooting

**Is Hyperspace loading?** Launch the game once, quit, then:

```sh
cd "$HOME/.steam/steam/steamapps/common/FTL Faster Than Light/data"
grep -i hyperspace FTL_HS.log | head      # expect: "Hyperspace: v1.23.2 x64 ..."
grep '\[Ensign\]' FTL_HS.log FTL.log      # expect Ensign start-up lines
```

- No `FTL_HS.log`, or no "Hyperspace" line: the `LD_PRELOAD` block did not run. Check `tail data/FTL` shows the block
  before the final `exec` line, and that you are launching through Steam (not a different binary). Also make sure a Steam launch option
  does not replace the launcher.
- Title screen shows "Hyperspace" in the version string when `ftl.dat` is patched correctly. If not, re-run the installer.
- Hyperspace log reports a version mismatch or missing `hyperspace.xml`: `ftl.dat` was replaced by Steam; re-run the installer.
- No `[Ensign]` lines: `ensign.amd64.so` is missing from `data/`, or the block lists only Hyperspace. Build with `make -C native` and re-run the installer.

**LD_PRELOAD errors** appear in the terminal if you start Steam from one (or in `~/.steam/steam/logs/`/`FTL.log`), e.g.:

```
ERROR: ld.so: object '/.../data/ensign.amd64.so' from LD_PRELOAD cannot be preloaded (cannot open shared object file): ignored.
```

The game still starts but without that library. Fix the path/permissions (`chmod 755`) or reinstall.
`wrong ELF class: ELFCLASS32` means a 32-bit library was used; FTL runs as `amd64` here, so use the `amd64` libraries.

**Controller does nothing**: confirm Steam Input is enabled for FTL (step 4), the Ensign layout is selected,
and `data/ensign_steam_input/` exists. For local testing without the Steam Workshop/community listing, the fallback manifest at
`~/.steam/steam/controller_config/game_actions_212680.vdf` is used; restart Steam after the first install so it is picked up.

**Installer says ftl.dat is not vanilla**: use Steam's "Verify integrity of game files" and run it again.

**Hyperspace download fails**: download `FTL.Hyperspace.<version>-Linux.zip` from
<https://github.com/FTL-Hyperspace/FTL-Hyperspace/releases> into `~/.cache/ensign/` and use `--no-download`.
