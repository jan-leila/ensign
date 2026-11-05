# Shared helpers for install.sh / uninstall.sh (sourced, not executed).

ENSIGN_BEGIN='# >>> ensign >>>'
ENSIGN_END='# <<< ensign <<<'
HS_SO='Hyperspace.1.6.13.amd64.so'
ENSIGN_SO='ensign.amd64.so'

default_ftl_dir() {
    if [ -n "${FTL_DIR:-}" ]; then
        printf '%s\n' "$FTL_DIR"
    else
        printf '%s\n' "$HOME/.steam/steam/steamapps/common/FTL Faster Than Light"
    fi
}

# Remove the ensign block (if any) from launcher $1, writing the result to stdout.
launcher_without_block() {
    sed "/^${ENSIGN_BEGIN//\//\\/}\$/,/^${ENSIGN_END//\//\\/}\$/d" "$1"
}

# launcher_with_block LAUNCHER WITH_ENSIGN(0|1): print a new launcher on stdout with
# exactly one ensign block inserted right before the final `exec` line.
launcher_with_block() {
    local launcher="$1" with_ensign="$2" stripped n line
    stripped="$(mktemp)"
    launcher_without_block "$launcher" >"$stripped"
    n="$(grep -n '^exec ' "$stripped" | tail -n 1 | cut -d: -f1 || true)"
    if [ -z "$n" ]; then
        rm -f "$stripped"
        echo "error: no 'exec' line found in $launcher" >&2
        return 1
    fi
    if [ "$with_ensign" = 1 ]; then
        line="export LD_PRELOAD=\"\$here/$ENSIGN_SO:\$here/$HS_SO\${LD_PRELOAD:+:\$LD_PRELOAD}\""
    else
        line="export LD_PRELOAD=\"\$here/$HS_SO\${LD_PRELOAD:+:\$LD_PRELOAD}\""
    fi
    head -n "$((n - 1))" "$stripped"
    printf '%s\n%s\n%s\n' "$ENSIGN_BEGIN" "$line" "$ENSIGN_END"
    tail -n "+$n" "$stripped"
    rm -f "$stripped"
}

# Atomically replace FILE with the contents of TMP, keeping FILE's mode.
replace_file() {
    local tmp="$1" dest="$2"
    chmod --reference="$dest" "$tmp" 2>/dev/null || chmod 755 "$tmp"
    mv -f "$tmp" "$dest"
}

dat_has() {  # dat_has DAT PATH : is PATH an entry of DAT?
    local l
    l="$("$PYTHON" -I "$TOOLS/ftldat.py" list "$1")" || return 2
    grep -qxF -- "$2" <<<"$l"
}
