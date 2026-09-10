#!/usr/bin/env bash
# Direct standard-ALSA trials; no AoC firmware runtime modification.
set -euo pipefail
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec "$script_directory/d0-speaker-control-48k.sh" "$@"
