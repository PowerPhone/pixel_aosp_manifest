#!/usr/bin/env bash
# Flash one Frankel vendor_kernel_boot experiment from bootloader fastboot.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
guard="$script_dir/verify_frankel_vbmeta_image_set.py"
default_avbtool="$project_root/work/aosp/out_pixel/frankel/host/linux-x86/bin/avbtool"
default_fastboot="$project_root/work/toolchains/platform-tools/fastboot"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
usage() {
  cat >&2 <<'EOF'
usage: flash_frankel_experimental_vendor_kernel_boot.sh \
  --vendor-kernel-boot FILE [--serial SERIAL] [--reboot] [--verify-only]

To flash a root vbmeta as well, both of these are mandatory:
  --vbmeta FILE --root-image-set COMPLETE_BUNDLE_DIR

Optional tool overrides:
  --fastboot FILE --avbtool FILE

The default operation flashes vendor_kernel_boot only and preserves the root
vbmeta already on the phone. A requested vbmeta is rejected unless it describes
both the candidate vendor_kernel_boot and every other image in the explicit
root image set.
EOF
  exit 2
}

vendor_kernel_boot=
vbmeta=
root_image_set=
serial=${FRANKEL_FASTBOOT_SERIAL:-${ANDROID_SERIAL:-}}
fastboot=${FASTBOOT:-$default_fastboot}
avbtool=${AVBTOOL:-$default_avbtool}
reboot=false
verify_only=false
while (( $# )); do
  case "$1" in
    --vendor-kernel-boot) (( $# >= 2 )) || usage; vendor_kernel_boot=$2; shift 2 ;;
    --vbmeta) (( $# >= 2 )) || usage; vbmeta=$2; shift 2 ;;
    --root-image-set) (( $# >= 2 )) || usage; root_image_set=$2; shift 2 ;;
    --serial) (( $# >= 2 )) || usage; serial=$2; shift 2 ;;
    --fastboot) (( $# >= 2 )) || usage; fastboot=$2; shift 2 ;;
    --avbtool) (( $# >= 2 )) || usage; avbtool=$2; shift 2 ;;
    --reboot) reboot=true; shift ;;
    --verify-only) verify_only=true; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$vendor_kernel_boot" ]] || usage
if [[ -n "$vbmeta" || -n "$root_image_set" ]]; then
  [[ -n "$vbmeta" && -n "$root_image_set" ]] || \
    die "--vbmeta and --root-image-set must be supplied together"
fi

for command_name in awk grep python3 realpath sed sort tail tr; do
  command -v "$command_name" >/dev/null 2>&1 || \
    die "missing command: $command_name"
done
[[ -f "$guard" && ! -L "$guard" ]] || die "missing descriptor guard: $guard"
vendor_kernel_boot=$(realpath -e -- "$vendor_kernel_boot")
avbtool=$(realpath -e -- "$avbtool")
fastboot=$(realpath -e -- "$fastboot")
for path in "$vendor_kernel_boot" "$avbtool" "$fastboot"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
done
[[ -x "$fastboot" ]] || die "fastboot is not executable: $fastboot"

# Complete all file-only validation before the first fastboot invocation.
python3 "$guard" --avbtool "$avbtool" digest \
  --image "$vendor_kernel_boot" --partition vendor_kernel_boot >/dev/null
if [[ -n "$vbmeta" ]]; then
  vbmeta=$(realpath -e -- "$vbmeta")
  root_image_set=$(realpath -e -- "$root_image_set")
  [[ -f "$vbmeta" && ! -L "$vbmeta" ]] || die "missing or unsafe vbmeta: $vbmeta"
  python3 "$guard" --avbtool "$avbtool" root-set \
    --vbmeta "$vbmeta" --image-set "$root_image_set" \
    --override "vendor_kernel_boot=$vendor_kernel_boot"
fi
if [[ "$verify_only" == true ]]; then
  note "image validation passed; no device operation requested"
  exit 0
fi

[[ "${FRANKEL_EXPERIMENTAL_FLASH_CONFIRM:-}" == \
   FLASH_EXPERIMENTAL_FRANKEL_KERNEL ]] || \
  die "set FRANKEL_EXPERIMENTAL_FLASH_CONFIRM=FLASH_EXPERIMENTAL_FRANKEL_KERNEL"

mapfile -t connected < <("$fastboot" devices | awk 'NF {print $1}' | sort -u)
if [[ -z "$serial" ]]; then
  (( ${#connected[@]} == 1 )) || \
    die "connect exactly one fastboot phone or pass --serial"
  serial=${connected[0]}
else
  printf '%s\n' "${connected[@]}" | grep -Fxq -- "$serial" || \
    die "selected fastboot device is not connected: $serial"
fi
fb() { "$fastboot" -s "$serial" "$@"; }
getvar() {
  local name=$1 output
  output=$(fb getvar "$name" 2>&1) || die "fastboot getvar failed: $name"
  sed -nE "s/^\(bootloader\) ${name}: ?//p; s/^${name}: ?//p" <<<"$output" | \
    tail -n 1 | tr -d '\r'
}
[[ "$(getvar product)" == frankel ]] || die "attached device is not frankel"
case "$(getvar unlocked)" in yes|true) ;; *) die "bootloader is not unlocked" ;; esac
[[ "$(getvar is-userspace)" == no ]] || \
  die "use bootloader fastboot, not fastbootd, for this experiment"
slot=$(getvar current-slot)
[[ "$slot" == a || "$slot" == b ]] || die "cannot determine current slot"

note "flashing experimental vendor_kernel_boot to current slot $slot"
fb --slot="$slot" flash vendor_kernel_boot "$vendor_kernel_boot"
if [[ -n "$vbmeta" ]]; then
  note "flashing descriptor-matched root vbmeta last to current slot $slot"
  fb --slot="$slot" flash vbmeta "$vbmeta"
else
  note "preserving the installed root vbmeta (kernel-only experiment)"
fi
if [[ "$reboot" == true ]]; then
  fb reboot
else
  note "remaining in bootloader fastboot; pass --reboot to boot automatically"
fi
