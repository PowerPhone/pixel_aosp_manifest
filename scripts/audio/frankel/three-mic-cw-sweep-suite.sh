#!/usr/bin/env bash
# Real hardware only: four separate 192 kHz, three-microphone measurements.
set -euo pipefail
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_directory/../../.." && pwd -P)
if (( $# != 1 )); then
  echo "Usage: $0 NEW_OUTPUT_DIRECTORY" >&2
  echo 'Requires the qualified Frankel boot-ready image and exclusive root ADB.' >&2
  exit 64
fi
run_root=$(realpath -m -- "$1")
[[ ! -e "$run_root" ]] || { echo "Output already exists: $run_root" >&2; exit 1; }
mkdir -p "$run_root"
python3 "$project_root/tools/audio/generate_frankel_multichannel192_stimuli.py" \
  --output-dir "$run_root/stimuli"
profile="$project_root/tools/audio/manifests/frankel_d10_three_channel_192k.json"
for signal in cw sweep; do
  case "$signal" in
    cw) stimulus=cw-50000Hz-30s-stereo-s32-192k.wav ;;
    sweep) stimulus=sweep-0-to-96000Hz-10s-x3-stereo-s32-192k.wav ;;
  esac
  for speaker in bottom earpiece; do
    FRANKEL_AUDIO_DURATION=34 FRANKEL_AUDIO_LEAD=2 \
      bash "$script_directory/d5-d10-three-mic-measurement.sh" \
      "$profile" "$run_root/stimuli/$stimulus" "$run_root/$signal-$speaker" "$speaker"
  done
done
printf 'Four recordings completed: %s\n' "$run_root"
