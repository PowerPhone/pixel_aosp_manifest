#!/usr/bin/env bash
# Real app APIs only: no direct ALSA, root requests, mixer or service changes.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
exec "${POWERPHONE_ANALYSIS_PYTHON:-$repo/work/toolchains/hf-plot-venv/bin/python}" \
    "$repo/tools/audio/cubs/run_api_duplex_reference.py" "$@"
