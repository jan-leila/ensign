#!/usr/bin/env bash
# Build dist/Ensign.ftl from mod/ (a .ftl is a zip with data/, img/, audio/ at its root).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
py="${PYTHON:-python3}"

if [ ! -d "$root/mod" ]; then
    echo "build-ftl: $root/mod does not exist" >&2
    exit 1
fi

mkdir -p "$root/dist"
"$py" -I "$root/tools/ftldat.py" pack-ftl "$root/mod" "$root/dist/Ensign.ftl"
echo "built $root/dist/Ensign.ftl"
