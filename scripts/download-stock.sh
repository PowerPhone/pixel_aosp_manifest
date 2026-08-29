#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_command curl sha256sum
[[ "${GOOGLE_PIXEL_TERMS_ACCEPTED:-}" == 1 ]] || die \
  "review Google's Pixel factory/OTA terms, then set GOOGLE_PIXEL_TERMS_ACCEPTED=1"

download_dir="$project_root/downloads"
assert_inside_project "$download_dir"
[[ ! -L "$download_dir" ]] || \
  die "download directory must not be a symbolic link: $download_dir"
mkdir -p "$download_dir"
[[ -d "$download_dir" && ! -L "$download_dir" ]] || \
  die "download directory is not a real directory: $download_dir"

download_one() {
  local url=$1
  local filename=$2
  local checksum=$3
  local destination="$download_dir/$filename"
  local partial="$destination.part"

  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || \
      die "download destination is not a regular file: $destination"
    verify_sha256 "$checksum" "$destination"
    note "already verified: $filename"
    return
  fi

  if [[ -e "$partial" || -L "$partial" ]]; then
    [[ -f "$partial" && ! -L "$partial" ]] || \
      die "partial download is not a regular file: $partial"
  fi

  note "downloading $filename"
  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-all-errors \
    --continue-at - \
    --output "$partial" \
    "$url"
  verify_sha256 "$checksum" "$partial"
  [[ ! -e "$destination" && ! -L "$destination" ]] || \
    die "download destination appeared concurrently: $destination"
  mv -- "$partial" "$destination"
  note "verified: $filename"
}

download_one "$FACTORY_IMAGE_URL" "$FACTORY_IMAGE_FILENAME" "$FACTORY_IMAGE_SHA256"
download_one "$FULL_OTA_URL" "$FULL_OTA_FILENAME" "$FULL_OTA_SHA256"
