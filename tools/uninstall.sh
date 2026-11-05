#!/usr/bin/env bash
# Remove Ensign from FTL and restore the original launcher and ftl.dat.
set -euo pipefail

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
# shellcheck source=tools/_common.sh
. "$TOOLS/_common.sh"

FTL_DIR_OPT="$(default_ftl_dir)"
KEEP_HS=0
DRY=0
STEAM_DIR="${STEAM_DIR:-$HOME/.steam/steam}"

usage() {
    cat <<USAGE
Usage: tools/uninstall.sh [options]
  --ftl-dir DIR     FTL install dir (default: \$FTL_DIR or the Steam path)
  --keep-hyperspace keep Hyperspace: re-patch ftl.dat with only Hyperspace.ftl and
                    leave Hyperspace in the launcher's LD_PRELOAD
  --steam-dir DIR   Steam root holding controller_config (default: $STEAM_DIR)
  --dry-run         show what would be done
  -h, --help
USAGE
}
while [ $# -gt 0 ]; do
    case "$1" in
        --ftl-dir) FTL_DIR_OPT="${2:?}"; shift 2 ;;
        --keep-hyperspace) KEEP_HS=1; shift ;;
        --steam-dir) STEAM_DIR="${2:?}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

act() { local d="$1"; shift; if [ "$DRY" = 1 ]; then echo "[dry-run] $d"; else "$@"; fi; }

DATA="$FTL_DIR_OPT/data"
DAT="$DATA/ftl.dat"
VANILLA="$DATA/ftl.dat.vanilla"
LAUNCHER="$DATA/FTL"
[ -d "$DATA" ] || { echo "error: $DATA not found (use --ftl-dir)" >&2; exit 1; }

# launcher
if [ "$KEEP_HS" = 1 ]; then
    if [ -f "$LAUNCHER" ]; then
        rewrite_launcher() {
            local tmp; tmp="$(mktemp "$DATA/.FTL.ensign.XXXXXX")"
            launcher_with_block "$LAUNCHER" 0 >"$tmp"
            replace_file "$tmp" "$LAUNCHER"
        }
        act "launcher: keep only Hyperspace in LD_PRELOAD block" rewrite_launcher
    fi
elif [ -f "$LAUNCHER.ensign-orig" ]; then
    restore_launcher() {
        local tmp; tmp="$(mktemp "$DATA/.FTL.ensign.XXXXXX")"
        cp "$LAUNCHER.ensign-orig" "$tmp"
        replace_file "$tmp" "$LAUNCHER"
        rm -f "$LAUNCHER.ensign-orig"
    }
    act "restore launcher from FTL.ensign-orig" restore_launcher
elif [ -f "$LAUNCHER" ] && grep -qF "$ENSIGN_BEGIN" "$LAUNCHER"; then
    strip_launcher() {
        local tmp; tmp="$(mktemp "$DATA/.FTL.ensign.XXXXXX")"
        launcher_without_block "$LAUNCHER" >"$tmp"
        replace_file "$tmp" "$LAUNCHER"
    }
    echo "warning: no FTL.ensign-orig; just removing the ensign block"
    act "strip ensign block from launcher" strip_launcher
else
    echo "launcher: nothing to restore"
fi

# ftl.dat
if [ -f "$VANILLA" ]; then
    restore_dat() {
        local tmp="$DATA/.ftl.dat.ensign.tmp"
        if [ "$KEEP_HS" = 1 ]; then
            [ -f "$DATA/Hyperspace.ftl" ] || { echo "error: $DATA/Hyperspace.ftl missing" >&2; return 1; }
            "$PYTHON" -I "$TOOLS/ftldat.py" patch --base "$VANILLA" --out "$tmp" "$DATA/Hyperspace.ftl"
        else
            cp "$VANILLA" "$tmp"
        fi
        mv -f "$tmp" "$DAT"
    }
    act "ftl.dat: $([ "$KEEP_HS" = 1 ] && echo 'vanilla + Hyperspace.ftl' || echo 'restore vanilla')" restore_dat
else
    echo "warning: $VANILLA not found; ftl.dat left untouched (use Steam 'Verify integrity of game files' to restore)" >&2
fi

# files
for f in "$DATA/$ENSIGN_SO" "$STEAM_DIR/controller_config/game_actions_212680.vdf"; do
    [ -e "$f" ] && act "remove $f" rm -f "$f"
done
[ -d "$DATA/ensign_steam_input" ] && act "remove $DATA/ensign_steam_input" rm -rf "$DATA/ensign_steam_input"

cat <<SUM

Ensign removed from $FTL_DIR_OPT$([ "$DRY" = 1 ] && echo " (dry run: nothing changed)").
Kept: $VANILLA (delete it to reclaim ~280 MB)$([ "$KEEP_HS" = 0 ] && echo "; Hyperspace.ftl and $HS_SO are in data/ but no longer loaded").
SUM
