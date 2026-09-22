#!/usr/bin/env bash
# Build, but never flash, the D0 real-mailbox bounded-progress pair.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

export D0_PROGRESS_TAG=d0-mailbox-real-progress
export D0_PROGRESS_DESCRIPTION='D0 stock mailbox ISR; max one real AoC Rx period per notification'
export D0_PROGRESS_PATCHER="$script_dir/patch_frankel_aoc_ep1_d0_mailbox_real_progress.py"
export D0_PROGRESS_ALSA_SHA256=fc990edad9b77b2bb96cd222f6a07503dc12247804c498a769d0436b5cb61cd0

exec "$script_dir/build_frankel_ep1_source0_192k_d0_real_progress_pair.sh" "$@"
