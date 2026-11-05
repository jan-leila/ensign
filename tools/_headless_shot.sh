#!/usr/bin/env bash
# Runs INSIDE xvfb-run (needs $DISPLAY). Starts a screenshot poller, runs the game, stops the poller.
# Env: SHOT_DATA (dir where the game writes ensign_shot_request), SHOT_OUT (png output dir).
# Usage: _headless_shot.sh GAME_CMD [ARGS...]
REQ="$SHOT_DATA/ensign_shot_request"

snap() {  # snap FILE : root window -> PNG (atomic)
    local tmp="$1.part.png"
    if xwd -root -silent -display "$DISPLAY" 2>/dev/null | { magick xwd:- "png:$tmp" 2>/dev/null || convert xwd:- "png:$tmp" 2>/dev/null; }; then
        mv -f "$tmp" "$1"
    else
        rm -f "$tmp"; return 1
    fi
}

poller() {
    local parent="$1" n=0 name
    while kill -0 "$parent" 2>/dev/null; do
        if [ -f "$REQ" ]; then
            name="$(tr -cd 'A-Za-z0-9_.-' < "$REQ" | head -c 64)"; [ -n "$name" ] || name=shot
            snap "$SHOT_OUT/$name.png" || echo "[shot] capture failed: $name" >&2
            rm -f "$REQ"   # ack
        fi
        n=$((n + 1))
        if [ $((n % 50)) -eq 0 ]; then snap "$SHOT_OUT/last.png" || true; fi
        sleep 0.1
    done
}

rm -f "$REQ"
poller "$$" &
PID=$!
steam-run "$@"
RC=$?
kill "$PID" 2>/dev/null
exit "$RC"
