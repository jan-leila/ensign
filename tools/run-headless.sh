#!/usr/bin/env bash
# Headless smoke test: run FTL + Hyperspace + Ensign shim under Xvfb with software GL.
# Works on a replica game dir (symlinks to the real install; the real dir is never written).
set -euo pipefail

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOLS/.." && pwd)"
# shellcheck source=tools/_headless_lib.sh
. "$TOOLS/_headless_lib.sh"
exec_in_devshell "$ROOT" "$0" "$@"

PYTHON="${PYTHON:-python3}"
SECONDS_RUN=25
# NOTE: steam-run mounts a private /tmp, so the replica must NOT live under /tmp.
REPLICA="${ENSIGN_REPLICA:-$HOME/.cache/ensign/replica}"
KEEP=0  # (--keep accepted for compatibility; the replica and logs are always kept)
WITH_ENSIGN=1; HS_VERSION="1.23.2"; SCRIPT=""
REAL="${FTL_DIR:-$HOME/.steam/steam/steamapps/common/FTL Faster Than Light}"
CACHE="${ENSIGN_CACHE:-$HOME/.cache/ensign}"
HS_SO='Hyperspace.1.6.13.amd64.so'; ENSIGN_SO='ensign.amd64.so'
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_RUN="${2:?}"; shift 2 ;;
        --replica) REPLICA="${2:?}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --no-ensign) WITH_ENSIGN=0; shift ;;
        --hs-version) HS_VERSION="${2:?}"; shift 2 ;;
        --script) SCRIPT="$(realpath "${2:?}")"; shift 2 ;;
        -h|--help) sed -n 2,3p "$0"; echo "Usage: run-headless.sh [--seconds N] [--replica DIR] [--keep] [--no-ensign] [--hs-version V] [--script FILE] [-- game args]"; exit 0 ;;
        --) shift; EXTRA=("$@"); break ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
HS_VERSION="${HS_VERSION#v}"
DATA="$REPLICA/data"
case "$(realpath -m "$REPLICA")" in
    /tmp|/tmp/*) echo "error: replica under /tmp is invisible inside steam-run (private /tmp); use another dir" >&2; exit 1 ;;
esac
step() { printf '\n==> %s\n' "$*"; }

[ -f "$REAL/data/ftl.dat" ] || { echo "error: real game not found at $REAL" >&2; exit 1; }
[ -f "$ROOT/build/$ENSIGN_SO" ] || { echo "error: $ROOT/build/$ENSIGN_SO missing (nix develop -c make -C native)" >&2; exit 1; }

# ---- Hyperspace zip ---------------------------------------------------------
step "Hyperspace $HS_VERSION"
ZIPNAME="FTL.Hyperspace.$HS_VERSION-Linux.zip"
ZIP="$CACHE/$ZIPNAME"
if [ ! -f "$ZIP" ]; then
    mkdir -p "$CACHE"
    curl -fsSL --retry 3 -o "$ZIP.part" "https://github.com/FTL-Hyperspace/FTL-Hyperspace/releases/download/v$HS_VERSION/$ZIPNAME"
    mv "$ZIP.part" "$ZIP"
fi
echo "using $ZIP"

# ---- Ensign.ftl -------------------------------------------------------------
step "Building Ensign.ftl"
"$TOOLS/build-ftl.sh"

# ---- replica ----------------------------------------------------------------
step "Replica at $REPLICA"
mkdir -p "$REPLICA"
# Never let the replica be (or live inside) the real game dir.
case "$(realpath -m "$REPLICA")/" in
    "$(realpath -m "$REAL")"/*) echo "error: replica inside real game dir" >&2; exit 1 ;;
esac
# keep the big patched dat (and logs dir); rebuild the rest of the tree
if [ -f "$DATA/ftl.dat" ]; then mv -f "$DATA/ftl.dat" "$REPLICA/.ftl.dat.keep"; fi
find "$REPLICA" -mindepth 1 -maxdepth 1 ! -name logs ! -name .ftl.dat.keep ! -name .ftl.dat.stamp ! -name home ! -name xdg -exec rm -rf {} +
rm -rf "$REPLICA/xdg"
mkdir -p "$DATA" "$REPLICA/logs"
[ -f "$REPLICA/.ftl.dat.keep" ] && mv -f "$REPLICA/.ftl.dat.keep" "$DATA/ftl.dat"

# top-level files + data/ entries as symlinks, with exclusions
for f in "$REAL"/*; do
    b="$(basename "$f")"; [ "$b" = data ] && continue
    ln -s "$f" "$REPLICA/$b"
done
# top-level launcher is a bash script that cds to ./data; symlink resolves wrongly, so copy
rm -f "$REPLICA/FTL"; cp "$REAL/FTL" "$REPLICA/FTL"
for f in "$REAL/data"/*; do
    b="$(basename "$f")"
    case "$b" in FTL|ftl.dat|FTL.log|FTL_HS.log|zhl.log|"$HS_SO"|Hyperspace.ftl|ensign*) continue ;; esac
    ln -s "$f" "$DATA/$b"
done

extract_hs "$ZIP" "$DATA" "$HS_SO" "$PYTHON"
install -m 755 "$ROOT/build/$ENSIGN_SO" "$DATA/$ENSIGN_SO"
mkdir -p "$DATA/ensign_steam_input"
[ -d "$ROOT/steam_input" ] && cp -a "$ROOT/steam_input/." "$DATA/ensign_steam_input/"

# launcher
. "$TOOLS/_common.sh"
launcher_with_block "$REAL/data/FTL" "$WITH_ENSIGN" > "$DATA/FTL"
chmod 755 "$DATA/FTL"

# ---- patched ftl.dat --------------------------------------------------------
step "ftl.dat"
if dat_has_entry "$PYTHON" "$TOOLS" "$REAL/data/ftl.dat" data/hyperspace.xml; then
    echo "error: real ftl.dat already contains Hyperspace data; need a vanilla base" >&2; exit 1
fi
STAMP="$(printf '%s\n' "$(stat -c '%s %Y' "$REAL/data/ftl.dat")" "$(stat -c '%s %Y' "$ZIP")" "$(sha256sum < "$ROOT/dist/Ensign.ftl")" | sha256sum | cut -d' ' -f1)"
if [ -f "$DATA/ftl.dat" ] && [ "$(cat "$REPLICA/.ftl.dat.stamp" 2>/dev/null)" = "$STAMP" ]; then
    echo "reusing up-to-date $DATA/ftl.dat"
else
    rm -f "$DATA/ftl.dat"
    "$PYTHON" -I "$TOOLS/ftldat.py" patch --base "$REAL/data/ftl.dat" --out "$DATA/ftl.dat" "$DATA/Hyperspace.ftl" "$ROOT/dist/Ensign.ftl"
    echo "$STAMP" > "$REPLICA/.ftl.dat.stamp"
fi

# ---- scratch save dir -------------------------------------------------------
XDG="$REPLICA/xdg"
mkdir -p "$XDG/FasterThanLight"
for f in settings.ini ae_prof.sav prof.sav; do
    [ -f "$HOME/.local/share/FasterThanLight/$f" ] && cp "$HOME/.local/share/FasterThanLight/$f" "$XDG/FasterThanLight/$f"
done

# ---- run --------------------------------------------------------------------
step "Running for ${SECONDS_RUN}s ($([ $WITH_ENSIGN = 1 ] && echo 'ensign+hyperspace' || echo 'hyperspace only'))"
rm -f "$DATA"/FTL.log "$DATA"/FTL_HS.log "$DATA"/zhl.log "$DATA"/ensign.log
envs=(LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe ENSIGN_DEV=1 SDL_AUDIODRIVER=dummy
      XDG_DATA_HOME="$XDG" ENSIGN_REPLICA_RUN=1 ${ENSIGN_TRACE:+ENSIGN_TRACE=1})
[ -n "$SCRIPT" ] && envs+=(ENSIGN_TEST_SCRIPT="$SCRIPT")
START=$(date +%s)
set +e
(cd "$REPLICA" && env "${envs[@]}" timeout --signal=TERM --kill-after=5 "$SECONDS_RUN" \
    xvfb-run -a -s "-screen 0 1280x720x24" steam-run "$REPLICA/FTL" "${EXTRA[@]}" \
    > "$REPLICA/stdout.txt" 2>&1)
RC=$?
set -e
ELAPSED=$(( $(date +%s) - START ))
pkill -f "$REPLICA/data/FTL.amd64" 2>/dev/null || true

# ---- collect ----------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPLICA/logs/$TS"; mkdir -p "$OUT"
for f in FTL.log FTL_HS.log zhl.log ensign.log; do [ -f "$DATA/$f" ] && cp "$DATA/$f" "$OUT/"; done
cp "$REPLICA/stdout.txt" "$OUT/"
[ -d "$XDG/FasterThanLight" ] && ls -la "$XDG/FasterThanLight" > "$OUT/xdg-listing.txt"

step "Summary"
echo "exit status: $RC after ${ELAPSED}s (124/137/143 = killed by timeout = normal)"
echo "--- tail FTL.log"; tail -n 25 "$DATA/FTL.log" 2>/dev/null || echo "(none)"
echo "--- FTL_HS.log matches"
grep -iE 'Hyperspace|\[Lua\]|Ensign|error|lua' "$DATA/FTL_HS.log" 2>/dev/null | tail -n 60 || echo "(none)"
echo "--- stdout/stderr tail"; tail -n 20 "$REPLICA/stdout.txt"
echo "--- ensign.log"; cat "$DATA/ensign.log" 2>/dev/null || echo "(missing)"
echo "--- logs copied to: $OUT"

FAIL=0
if [ "$WITH_ENSIGN" = 1 ]; then
    if ! grep -q 'registered Ensign' "$DATA/ensign.log" 2>/dev/null; then
        echo "FAIL: ensign.log missing or lacks 'registered Ensign'" >&2; FAIL=1
        grep -h '^\[Ensign\]' "$REPLICA/stdout.txt" | head -n 10 | sed 's/^/  stderr: /' >&2 || true
    fi
fi
if [ "$ELAPSED" -lt 3 ] && [ "$SECONDS_RUN" -ge 3 ]; then echo "FAIL: game died within 3 seconds" >&2; FAIL=1; fi
exit "$FAIL"
