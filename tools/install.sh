#!/usr/bin/env bash
# Install Ensign (Hyperspace + Ensign.ftl + native hook + Steam Input files) into FTL.
set -euo pipefail

HS_DEFAULT_VERSION="1.23.2"   # latest Hyperspace release observed (tag v1.23.2)

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOLS/.." && pwd)"
PYTHON="${PYTHON:-python3}"
# shellcheck source=tools/_common.sh
. "$TOOLS/_common.sh"

FTL_DIR_OPT="$(default_ftl_dir)"
HS_VERSION="$HS_DEFAULT_VERSION"
DOWNLOAD=1
DRY=0
STEAM_DIR="${STEAM_DIR:-$HOME/.steam/steam}"
CACHE="${ENSIGN_CACHE:-$HOME/.cache/ensign}"

usage() {
    cat <<USAGE
Usage: tools/install.sh [options]
  --ftl-dir DIR               FTL install dir (default: \$FTL_DIR or the Steam path)
  --hyperspace-version VER    Hyperspace release to use (default: $HS_DEFAULT_VERSION)
  --no-download               expect the Hyperspace zip already in $CACHE
  --steam-dir DIR             Steam root for the controller_config fallback (default: $STEAM_DIR)
  --dry-run                   show what would be done, change nothing
  -h, --help
Environment: PYTHON (default python3), ENSIGN_CACHE (default ~/.cache/ensign), ENSIGN_BUILD_DIR (default build/)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ftl-dir) FTL_DIR_OPT="${2:?}"; shift 2 ;;
        --hyperspace-version) HS_VERSION="${2:?}"; shift 2 ;;
        --no-download) DOWNLOAD=0; shift ;;
        --steam-dir) STEAM_DIR="${2:?}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
HS_VERSION="${HS_VERSION#v}"

step() { printf '\n==> %s\n' "$*"; }
act() {  # act DESCRIPTION CMD...: run unless --dry-run
    local d="$1"; shift
    if [ "$DRY" = 1 ]; then echo "[dry-run] $d"; else "$@"; fi
}

DATA="$FTL_DIR_OPT/data"
DAT="$DATA/ftl.dat"
VANILLA="$DATA/ftl.dat.vanilla"
LAUNCHER="$DATA/FTL"

# ---- a. vanilla backup ------------------------------------------------------
step "Checking ftl.dat in $DATA"
[ -f "$DAT" ] || { echo "error: $DAT not found (use --ftl-dir)" >&2; exit 1; }
[ -f "$LAUNCHER" ] || { echo "error: launcher $LAUNCHER not found" >&2; exit 1; }
command -v "$PYTHON" >/dev/null || { echo "error: $PYTHON not found" >&2; exit 1; }

if [ -f "$VANILLA" ]; then
    if dat_has "$VANILLA" data/hyperspace.xml; then
        echo "error: $VANILLA already contains Hyperspace data; it is not a vanilla backup." >&2
        echo "       Delete it, let Steam 'Verify integrity of game files', and re-run." >&2
        exit 1
    fi
    echo "vanilla backup already present: $VANILLA"
else
    if dat_has "$DAT" data/hyperspace.xml; then
        echo "error: ftl.dat already contains Hyperspace/mod data and there is no vanilla backup." >&2
        echo "       In Steam: FTL > Properties > Installed Files > 'Verify integrity of game files'," >&2
        echo "       then re-run this script." >&2
        exit 1
    fi
    act "cp $DAT -> $VANILLA" cp -p "$DAT" "$VANILLA"
    [ "$DRY" = 1 ] || echo "created vanilla backup: $VANILLA"
fi

# ---- b. Hyperspace ----------------------------------------------------------
step "Hyperspace $HS_VERSION"
ZIPNAME="FTL.Hyperspace.$HS_VERSION-Linux.zip"
ZIP="$CACHE/$ZIPNAME"
URL="https://github.com/FTL-Hyperspace/FTL-Hyperspace/releases/download/v$HS_VERSION/$ZIPNAME"
if [ -f "$ZIP" ]; then
    echo "cached: $ZIP"
elif [ "$DOWNLOAD" = 0 ]; then
    echo "error: $ZIP not found and --no-download given" >&2
    echo "       download $URL there first." >&2
    exit 1
else
    act "download $URL -> $ZIP" bash -c 'mkdir -p "$1" && curl -fsSL --retry 3 -o "$2.part" "$3" && mv "$2.part" "$2"' _ "$CACHE" "$ZIP" "$URL"
fi
extract_hs() {
    "$PYTHON" -I - "$ZIP" "$DATA" "$HS_SO" <<'PY'
import sys, zipfile, os, shutil
zpath, data, so = sys.argv[1:4]
want = {"Hyperspace.ftl": "Hyperspace.ftl", "Linux/" + so: so}
with zipfile.ZipFile(zpath) as z:
    names = set(z.namelist())
    for src, dst in want.items():
        if src not in names:
            sys.exit("error: %s missing from %s (found: %s)" % (src, zpath, ", ".join(sorted(names))))
    for src, dst in want.items():
        tmp = os.path.join(data, "." + dst + ".tmp")
        with z.open(src) as i, open(tmp, "wb") as o:
            shutil.copyfileobj(i, o)
        os.chmod(tmp, 0o755 if dst.endswith(".so") else 0o644)
        os.replace(tmp, os.path.join(data, dst))
        print("installed", os.path.join(data, dst))
PY
}
act "extract Hyperspace.ftl and Linux/$HS_SO from the zip into $DATA" extract_hs
# This Hyperspace release statically links Lua, so no separate liblua is installed.

# ---- c. Ensign.ftl and native library ---------------------------------------
step "Building Ensign.ftl"
act "$TOOLS/build-ftl.sh" "$TOOLS/build-ftl.sh"
HAVE_SO=0
BUILD_DIR="${ENSIGN_BUILD_DIR:-$ROOT/build}"
if [ -f "$BUILD_DIR/$ENSIGN_SO" ]; then
    HAVE_SO=1
    act "cp build/$ENSIGN_SO -> $DATA/$ENSIGN_SO" install -m 755 "$BUILD_DIR/$ENSIGN_SO" "$DATA/$ENSIGN_SO"
    echo "native hook: $DATA/$ENSIGN_SO"
else
    echo "warning: $BUILD_DIR/$ENSIGN_SO not found; build it with:  make -C native" >&2
    echo "         (continuing with Hyperspace + Ensign.ftl only; re-run after building)" >&2
fi

# ---- d. patch ftl.dat -------------------------------------------------------
step "Patching ftl.dat (vanilla + Hyperspace.ftl + Ensign.ftl)"
patch_dat() {
    local tmp="$DATA/.ftl.dat.ensign.tmp"
    rm -f "$tmp"
    "$PYTHON" -I "$TOOLS/ftldat.py" patch --base "$VANILLA" --out "$tmp" "$DATA/Hyperspace.ftl" "$ROOT/dist/Ensign.ftl"
    "$PYTHON" -I "$TOOLS/ftldat.py" verify "$tmp"
    chmod --reference="$DAT" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$DAT"
}
act "$PYTHON -I tools/ftldat.py patch --base $VANILLA --out $DAT $DATA/Hyperspace.ftl $ROOT/dist/Ensign.ftl" patch_dat

# ---- e. Steam Input files ---------------------------------------------------
step "Steam Input files"
if [ -d "$ROOT/steam_input" ]; then
    install_si() {
        rm -rf "$DATA/ensign_steam_input"
        mkdir -p "$DATA/ensign_steam_input"
        cp -a "$ROOT/steam_input/." "$DATA/ensign_steam_input/"
        if [ -f "$ROOT/steam_input/ensign_actions.vdf" ]; then
            mkdir -p "$STEAM_DIR/controller_config"
            cp -f "$ROOT/steam_input/ensign_actions.vdf" "$STEAM_DIR/controller_config/game_actions_212680.vdf"
        else
            echo "warning: steam_input/ensign_actions.vdf missing; fallback file not installed" >&2
        fi
    }
    act "copy steam_input/ -> $DATA/ensign_steam_input and ensign_actions.vdf -> $STEAM_DIR/controller_config/game_actions_212680.vdf" install_si
else
    echo "warning: $ROOT/steam_input does not exist yet; skipping Steam Input files" >&2
fi

# ---- f. launcher ------------------------------------------------------------
step "Patching launcher $LAUNCHER"
patch_launcher() {
    [ -f "$LAUNCHER.ensign-orig" ] || cp -p "$LAUNCHER" "$LAUNCHER.ensign-orig"
    local tmp
    tmp="$(mktemp "$DATA/.FTL.ensign.XXXXXX")"
    launcher_with_block "$LAUNCHER" "$HAVE_SO" >"$tmp"
    replace_file "$tmp" "$LAUNCHER"
}
act "back up launcher to FTL.ensign-orig (once) and insert ensign block (ensign.so first, Hyperspace second)" patch_launcher

# ---- g. summary -------------------------------------------------------------
step "Summary"
cat <<SUM
FTL dir:            $FTL_DIR_OPT
Hyperspace:         v$HS_VERSION ($HS_SO)
ftl.dat:            vanilla + Hyperspace.ftl + Ensign.ftl  (backup: ftl.dat.vanilla)
Native hook:        $([ "$HAVE_SO" = 1 ] && echo installed || echo "NOT installed (run: make -C native, then re-run this script)")
Launcher:           LD_PRELOAD block between '$ENSIGN_BEGIN' markers (backup: FTL.ensign-orig)
$([ "$DRY" = 1 ] && echo "(dry run: nothing was changed)")

Next: in Steam, right-click FTL > Properties > Controller (Steam Input) and
set "Enable Steam Input" (not "Disable"), then launch FTL from Steam.
Undo with tools/uninstall.sh.
SUM
