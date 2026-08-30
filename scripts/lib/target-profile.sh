#!/usr/bin/env bash

# This file is sourced by common.sh after project_root has been resolved.
# shellcheck disable=SC2154
pixel_target=${PIXEL_TARGET:-cubs}
[[ "$pixel_target" =~ ^[a-z0-9_]+$ ]] || {
  printf 'error: invalid PIXEL_TARGET: %s\n' "$pixel_target" >&2
  exit 1
}
case "$pixel_target" in
  cubs|frankel) ;;
  *)
    printf 'error: unsupported PIXEL_TARGET: %s\n' "$pixel_target" >&2
    exit 1
    ;;
esac
target_root="$project_root/config/targets"
target_directory="$target_root/$pixel_target"
[[ -d "$target_root" && ! -L "$target_root" && \
   -d "$target_directory" && ! -L "$target_directory" ]] || {
  printf 'error: unsafe target-profile directory for %s\n' "$pixel_target" >&2
  exit 1
}
target_profile="$target_directory/release.env"
[[ -f "$target_profile" && ! -L "$target_profile" ]] || {
  printf 'error: unsupported PIXEL_TARGET: %s\n' "$pixel_target" >&2
  exit 1
}
target_profile=$(realpath -e -- "$target_profile") || {
  printf 'error: unable to resolve target profile: %s\n' "$pixel_target" >&2
  exit 1
}
[[ "$target_profile" == "$target_directory/release.env" ]] || {
  printf 'error: target profile escapes its reviewed directory: %s\n' \
    "$target_profile" >&2
  exit 1
}

required_target_variables=(
  DEVICE_CODENAME
  DEVICE_MARKETING_NAME
  DEVICE_PLATFORM
  DEVICE_PRODUCT_TARGET
  STOCK_BUILD_ID
  STOCK_SECURITY_PATCH
  EXPECTED_BOOTLOADER_VERSION
  EXPECTED_BASEBAND_VERSION
  FACTORY_IMAGE_FILENAME
  FACTORY_IMAGE_URL
  FACTORY_IMAGE_SHA256
  FULL_OTA_FILENAME
  FULL_OTA_URL
  FULL_OTA_SHA256
)
# A profile omission must never inherit a same-named caller variable. Clear the
# complete schema before evaluating the reviewed profile.
for target_variable in "${required_target_variables[@]}"; do
  unset "$target_variable"
done
# shellcheck disable=SC1090
source "$target_profile"
for target_variable in "${required_target_variables[@]}"; do
  [[ -n "${!target_variable+x}" && -n "${!target_variable}" ]] || {
    printf 'error: target profile omits %s: %s\n' \
      "$target_variable" "$target_profile" >&2
    exit 1
  }
done
[[ "$DEVICE_CODENAME" == "$pixel_target" ]] || {
  printf 'error: target profile identity mismatch: %s != %s\n' \
    "$DEVICE_CODENAME" "$pixel_target" >&2
  exit 1
}

target_profile_iso_date_is_valid() {
  local value=$1 year month day maximum_day

  [[ "$value" =~ ^(20[0-9]{2})-([01][0-9])-([0-3][0-9])$ ]] || return 1
  year=${BASH_REMATCH[1]}
  month=${BASH_REMATCH[2]}
  day=${BASH_REMATCH[3]}
  case "$month" in
    01|03|05|07|08|10|12) maximum_day=31 ;;
    04|06|09|11) maximum_day=30 ;;
    02)
      maximum_day=28
      if (( 10#$year % 400 == 0 || \
            (10#$year % 4 == 0 && 10#$year % 100 != 0) )); then
        maximum_day=29
      fi
      ;;
    *) return 1 ;;
  esac
  (( 10#$day >= 1 && 10#$day <= maximum_day ))
}
[[ "$DEVICE_MARKETING_NAME" =~ ^[A-Za-z0-9._+()\ -]+$ && \
   "$DEVICE_PLATFORM" =~ ^[a-z0-9_]+$ && \
   "$DEVICE_PRODUCT_TARGET" == \
     "$DEVICE_CODENAME-aosp_current-userdebug" && \
   "$STOCK_BUILD_ID" =~ ^[A-Z0-9][A-Z0-9.]*$ && \
   "$EXPECTED_BOOTLOADER_VERSION" =~ ^[-A-Za-z0-9._]+$ && \
   "$EXPECTED_BASEBAND_VERSION" =~ ^[-A-Za-z0-9._]+$ ]] || {
  printf 'error: malformed identity or firmware value in %s\n' \
    "$target_profile" >&2
  exit 1
}
target_profile_iso_date_is_valid "$STOCK_SECURITY_PATCH" || {
  printf 'error: invalid stock security-patch date in %s: %s\n' \
    "$target_profile" "$STOCK_SECURITY_PATCH" >&2
  exit 1
}
for target_filename in "$FACTORY_IMAGE_FILENAME" "$FULL_OTA_FILENAME"; do
  [[ "$target_filename" =~ ^[-A-Za-z0-9._]+\.zip$ ]] || {
    printf 'error: unsafe target archive filename: %s\n' "$target_filename" >&2
    exit 1
  }
done
[[ "$FACTORY_IMAGE_URL" =~ ^https://[^[:space:]]+/$FACTORY_IMAGE_FILENAME$ && \
   "$FULL_OTA_URL" =~ ^https://[^[:space:]]+/$FULL_OTA_FILENAME$ ]] || {
  printf 'error: target archive URL does not match its pinned filename\n' >&2
  exit 1
}
for target_digest in "$FACTORY_IMAGE_SHA256" "$FULL_OTA_SHA256"; do
  [[ "$target_digest" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'error: malformed target archive SHA-256 in %s\n' \
      "$target_profile" >&2
    exit 1
  }
done
export PIXEL_TARGET="$pixel_target"
unset -f target_profile_iso_date_is_valid
unset pixel_target target_root target_directory target_profile \
  required_target_variables target_variable target_filename target_digest
