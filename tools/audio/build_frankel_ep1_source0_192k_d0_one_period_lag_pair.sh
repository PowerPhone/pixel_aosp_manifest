#!/usr/bin/env bash
# Build, but never flash, the D0 hybrid real-progress startup-cushion image.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)

export D0_PROGRESS_TAG=d0-hybrid-one-period-lag
export D0_PROGRESS_DESCRIPTION='D0 mailbox plus 1ms real-counter poll; max(previous, actual-period) startup cushion'
export D0_PROGRESS_BASE_VARIANT=frankel-ep1-source0-192k-d0-hybrid-real-progress
export D0_PROGRESS_BASE_DIR="$project_root/work/audio-research/frankel/speaker-ep1-source0-192k-d0-hybrid-real-progress-pair/trial-1"
export D0_PROGRESS_BASE_VKB_SHA256=8f38733d465c856ba052f1d921f8381fdfb7626d38c11c0dbbf72d1e3a0bb953
export D0_PROGRESS_BASE_ALSA_SHA256=14f768697dfdce17869d91360da54ab9e4f7b8d291e718ff8919f524e7010e98
export D0_PROGRESS_PATCHER="$script_dir/patch_frankel_aoc_ep1_d0_one_period_lag.py"
export D0_PROGRESS_ALSA_SHA256=37cc7ff81bf9804677699d612621ed75a177597e773709ec54924916811818e6
export D0_PROGRESS_CHECK_STATE=d0-hybrid-one-period-lag
export D0_PROGRESS_EXPECTED_GEOMETRY=stereo-S32-192000-p1920-n2-start1920

exec "$script_dir/build_frankel_ep1_source0_192k_d0_real_progress_pair.sh" "$@"
