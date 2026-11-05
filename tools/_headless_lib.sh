# Helpers for run-headless.sh (sourced).
HS_SO='Hyperspace.1.6.13.amd64.so'

# Re-exec inside `nix develop` when xvfb-run / steam-run are not on PATH.
exec_in_devshell() {
    local root="$1"; shift
    if ! command -v xvfb-run >/dev/null || ! command -v steam-run >/dev/null; then
        [ -z "${ENSIGN_IN_DEVSHELL:-}" ] || { echo "error: xvfb-run/steam-run still missing in devshell" >&2; exit 1; }
        cd "$root" && ENSIGN_IN_DEVSHELL=1 exec nix develop -c "$@"
    fi
}

# extract_hs ZIP DATA SO PYTHON : copy Hyperspace.ftl and Linux/SO out of the zip.
extract_hs() {
    "$4" -I - "$1" "$2" "$3" <<'PY'
import sys, zipfile, os, shutil
zpath, data, so = sys.argv[1:4]
want = {"Hyperspace.ftl": "Hyperspace.ftl", "Linux/" + so: so}
with zipfile.ZipFile(zpath) as z:
    for src, dst in want.items():
        out = os.path.join(data, dst)
        if os.path.islink(out): os.unlink(out)
        with z.open(src) as i, open(out, "wb") as o:
            shutil.copyfileobj(i, o)
        os.chmod(out, 0o755 if dst.endswith(".so") else 0o644)
PY
}

# dat_has_entry PYTHON TOOLS DAT PATH
dat_has_entry() { "$1" -I "$2/ftldat.py" list "$3" | grep -qxF -- "$4"; }
