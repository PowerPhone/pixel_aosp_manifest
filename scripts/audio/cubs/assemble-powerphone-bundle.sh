#!/usr/bin/env bash
# Separate opt-in flavor. Do not call the legacy donor/attestation packager.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
exec python3 "$repo/tools/audio/cubs/assemble_powerphone_bundle.py" "$@"
