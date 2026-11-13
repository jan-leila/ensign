#!/usr/bin/env bash
# Build a release tarball: dist/ensign-<version>-linux-x86_64.tar.gz (+ .sha256).
#
#   tools/package.sh [VERSION]      VERSION defaults to `git describe`; a leading v is dropped
#
# The tarball holds what tools/install.sh needs and nothing from the game or
# Hyperspace (the installer downloads Hyperspace from its own releases):
#   LICENSE README.md docs/INSTALL.md mod/ steam_input/ tools/ (installer subset)
#   build/ensign.amd64.so  (portable build: glibc >= 2.31, no runpath)
#   dist/Ensign.ftl        (also rebuilt from mod/ by the installer)
# The version is stamped into the staged copy only (E.VERSION, metadata.xml).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
VERSION="${VERSION#v}"
case "$VERSION" in *[!A-Za-z0-9._+-]*|"") echo "package: bad version '$VERSION'" >&2; exit 2 ;; esac
NAME="ensign-$VERSION"
OUT="$ROOT/dist/$NAME-linux-x86_64.tar.gz"
GLIBC_MIN=2.31

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
S="$STAGE/$NAME"

echo "==> native (portable, glibc >= $GLIBC_MIN)"
make -C "$ROOT/native" portable VERSION="$VERSION" GLIBC_MIN="$GLIBC_MIN"
SO="$ROOT/build/ensign.amd64.so"
if readelf -d "$SO" | grep -qE 'RPATH|RUNPATH'; then
    echo "package: $SO has an RPATH/RUNPATH; not a portable build" >&2; exit 1
fi
newest="$(objdump -T "$SO" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)"
if [ "$(printf '%s\n%s\n' "$newest" "$GLIBC_MIN" | sort -V | tail -n 1)" != "$GLIBC_MIN" ]; then
    echo "package: $SO needs GLIBC_$newest (> $GLIBC_MIN)" >&2; exit 1
fi
echo "native ok: newest glibc symbol $newest, no runpath"

echo "==> staging $NAME"
mkdir -p "$S/docs" "$S/tools" "$S/build" "$S/dist"
cp -a "$ROOT/LICENSE" "$ROOT/README.md" "$S/"
cp -a "$ROOT/docs/INSTALL.md" "$S/docs/"
cp -a "$ROOT/mod" "$ROOT/steam_input" "$S/"
for f in install.sh uninstall.sh _common.sh ftldat.py build-ftl.sh; do
    cp -a "$ROOT/tools/$f" "$S/tools/"
done
install -m 755 "$SO" "$S/build/ensign.amd64.so"

sed -i "s/^E\.VERSION = \".*\"/E.VERSION = \"$VERSION\"/" "$S/mod/data/ensign/00_core.lua"
grep -q "^E.VERSION = \"$VERSION\"" "$S/mod/data/ensign/00_core.lua" || { echo "package: could not stamp E.VERSION" >&2; exit 1; }
sed -i "s|<version>.*</version>|<version>$VERSION</version>|" "$S/mod/mod-appendix/metadata.xml"

"$S/tools/build-ftl.sh" >/dev/null

echo "==> archive"
mkdir -p "$ROOT/dist"
mtime="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$mtime" \
    -C "$STAGE" -czf "$OUT" "$NAME"
(cd "$ROOT/dist" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "built $OUT"
cat "$OUT.sha256"
