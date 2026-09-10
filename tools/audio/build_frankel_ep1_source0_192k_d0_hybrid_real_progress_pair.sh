#!/usr/bin/env bash
# Build, but never flash, the D0 mailbox-plus-timer real-progress pair.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

export D0_PROGRESS_TAG=d0-hybrid-real-progress
export D0_PROGRESS_DESCRIPTION='D0 stock mailbox plus 1ms poll; max one real AoC Rx period per invocation'
export D0_PROGRESS_PATCHER="$script_dir/patch_frankel_aoc_ep1_d0_hybrid_real_progress.py"
export D0_PROGRESS_ALSA_SHA256=14f768697dfdce17869d91360da54ab9e4f7b8d291e718ff8919f524e7010e98

exec "$script_dir/build_frankel_ep1_source0_192k_d0_real_progress_pair.sh" "$@"
