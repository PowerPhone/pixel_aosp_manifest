#!/usr/bin/env bash
# Build real Cubs EROFS payloads from captured partition roots; never flash.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    exec python3 "$here/build_primary_images.py" --help
fi
# Preserving the captured UID/GID values requires root. Do not chown the input
# roots or normalize every file to root:root to work around that requirement.
if ((EUID)); then
    exec sudo -n -- python3 "$here/build_primary_images.py" "$@"
fi
exec python3 "$here/build_primary_images.py" "$@"
