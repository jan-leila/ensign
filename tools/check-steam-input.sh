#!/usr/bin/env bash
# Verify the real Steam client accepts our ISteamInput vtable usage and manifest,
# without launching FTL. Needs Steam running and an account owning FTL.
# Usage: tools/check-steam-input.sh [--seconds N] [--virtual-pad]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FTL_DIR="${FTL_DIR:-$HOME/.steam/steam/steamapps/common/FTL Faster Than Light}"
SECONDS_LISTEN=3; VPAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) SECONDS_LISTEN="$2"; shift 2;;
    --virtual-pad) VPAD=1; shift;;
    *) echo "unknown arg $1" >&2; exit 64;;
  esac
done
W="$HOME/.cache/ensign/steamcheck"; mkdir -p "$W"
cp -f "$FTL_DIR/data/amd64/libsteam_api.so" "$W/libsteam_api.so" || { echo "cannot copy libsteam_api.so from $FTL_DIR" >&2; exit 1; }
echo 212680 > "$W/steam_appid.txt"
g++ -std=c++17 -O1 -g -I"$ROOT/native" "$ROOT/native/tools/steam_input_check.cpp" -ldl -o "$W/steam_input_check" || exit 1
PADPID=""
if [ "$VPAD" = 1 ]; then
  nix shell --impure --expr 'let p=import <nixpkgs> {}; in p.python3.withPackages (ps:[ps.evdev])' \
    -c python3 -I "$ROOT/tools/_virtual_pad.py" & PADPID=$!
  trap '[ -n "$PADPID" ] && pkill -P "$PADPID" 2>/dev/null; [ -n "$PADPID" ] && kill "$PADPID" 2>/dev/null' EXIT
  sleep 6
fi
cd "$W"
OUT="$(LD_LIBRARY_PATH="$W" ./steam_input_check "$ROOT/steam_input/ensign_actions.vdf" "$SECONDS_LISTEN" 2>&1)"
RC=$?
printf '%s\n' "$OUT"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^\[FAIL\]'; then exit 1; fi
