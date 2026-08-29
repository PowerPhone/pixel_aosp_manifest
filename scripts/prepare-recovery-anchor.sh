#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/usbipd-win.sh disable=SC1091
source "$script_dir/lib/usbipd-win.sh"
# shellcheck source=lib/recovery-handoff.sh disable=SC1091
source "$script_dir/lib/recovery-handoff.sh"

require_command awk chmod cmp cp date flock grep mkdir mktemp mv openssl \
  realpath rm sed sha256sum sort stat timeout unzip xxd

ota_path="$project_root/downloads/$FULL_OTA_FILENAME"
state_file=$cubs_sideload_preflight
ota_metadata=
ota_fingerprint=
ota_incremental=
ota_sdk=
ota_security_patch=
adb_serial=
adb_state=
adb_bin=
fastboot_serial=
fastboot_bin=
expected_bootloader=
expected_baseband=
usbipd_exe=${USBIPD_EXE:-/mnt/c/Program Files/usbipd-win/usbipd.exe}
expected_ota_partition_list=(
  abl bl31 boot cap cpm dbc dbl
  dram_init_0 dram_init_1 dram_init_10 dram_init_11 dram_init_2 dram_init_3
  dram_init_4 dram_init_5 dram_init_6 dram_init_7 dram_init_8 dram_init_9
  dram_phy dtbo gc gdmc gsa_bl1 gsa_fw init_boot modem product pvmfw system
  system_dlkm system_ext tzsw vbmeta vbmeta_system vbmeta_vendor vendor
  vendor_boot vendor_dlkm vendor_kernel_boot
)
expected_ota_partitions=$(
  IFS=,
  printf '%s' "${expected_ota_partition_list[*]}"
)
lifeboat_partitions=("${cubs_preserved_b_partitions[@]}")

require_no_stock_restore_transaction() {
  [[ ! -e "$cubs_stock_restore_transaction" && \
     ! -L "$cubs_stock_restore_transaction" ]] || \
    die "finish the journaled stock restore before starting another recovery workflow"
  [[ ! -e "$cubs_slot_a_flash_transaction" && \
     ! -L "$cubs_slot_a_flash_transaction" ]] || \
    die "finish or adopt the journaled slot-A flash before starting another recovery workflow"
}

usage() {
  cat <<'EOF'
Usage: scripts/prepare-recovery-anchor.sh ACTION

Read-only actions:
  check-ota           Verify the pinned full OTA and its metadata.
  preflight-android   Verify exact stock build, slot A, unlock state, and battery.
  verify-android      Verify the post-OTA stock boot is exact build on slot B.
  verify-fastboot     Verify pre-flash B flags, firmware, and physical lifeboat.

State-changing actions (environment gate and exact interactive phrase required):
  install             Reboot verified stock A to sideload-auto-reboot and send OTA.
  resume-sideload     Resume sending after recovery USB forwarding was interrupted.
  reboot-and-verify   Reboot verified stock B to bootloader and verify its slot state.
  continue-b-merge    Reboot current B if a virtual A/B snapshot still needs to settle.
  select-b-lifeboat   Select physical B for another immediate fastbootd flash; no reboot.
  reissue-stale-handoff
                      Archive an expired unclaimed handoff and issue a fresh one.

Run the read-only action for a stage before its state-changing action. See
docs/recovery-anchor.md for the complete WSL USB and stock-ADB procedure.
EOF
}

load_stock_requirements() {
  local android_info board stock_dir stock_images

  [[ -n "$expected_bootloader" && -n "$expected_baseband" ]] && return 0
  verify_sha256 "$FACTORY_IMAGE_SHA256" \
    "$project_root/downloads/$FACTORY_IMAGE_FILENAME"
  "$script_dir/extract-stock.sh"
  stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
  stock_images="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
  require_file "$stock_images"
  [[ $(unzip -Z1 "$stock_images" | grep -Fxc android-info.txt || true) -eq 1 ]] || \
    die "stock image package must contain exactly one root android-info.txt"
  android_info=$(unzip -p "$stock_images" android-info.txt) || \
    die "unable to read stock android-info.txt"
  board=$(sed -n 's/^require board=//p' <<<"$android_info")
  expected_bootloader=$(sed -n 's/^require version-bootloader=//p' <<<"$android_info")
  expected_baseband=$(sed -n 's/^require version-baseband=//p' <<<"$android_info")
  [[ "|$board|" == *"|$DEVICE_CODENAME|"* ]] || \
    die "pinned stock package does not allow $DEVICE_CODENAME"
  [[ $(grep -c '^require board=' <<<"$android_info") -eq 1 && \
     $(grep -c '^require version-bootloader=' <<<"$android_info") -eq 1 && \
     $(grep -c '^require version-baseband=' <<<"$android_info") -eq 1 ]] || \
    die "pinned stock package has malformed firmware requirements"
  [[ -n "$expected_bootloader" && -n "$expected_baseband" ]] || \
    die "pinned stock package has empty firmware requirements"
}

metadata_value() {
  local key=$1
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' \
    <<<"$ota_metadata"
}

check_ota() {
  local entries entry_count ota_type ota_device ota_build_id ota_timestamp

  verify_sha256 "$FULL_OTA_SHA256" "$ota_path"
  entries=$(unzip -Z1 "$ota_path")
  for required_entry in \
    META-INF/com/android/metadata \
    META-INF/com/android/metadata.pb \
    payload.bin \
    payload_properties.txt; do
    entry_count=$(grep -Fxc -- "$required_entry" <<<"$entries" || true)
    (( entry_count == 1 )) || die \
      "OTA must contain exactly one $required_entry entry"
  done

  ota_metadata=$(unzip -p "$ota_path" META-INF/com/android/metadata)
  ota_type=$(metadata_value ota-type)
  ota_device=$(metadata_value pre-device)
  ota_fingerprint=$(metadata_value post-build)
  ota_incremental=$(metadata_value post-build-incremental)
  ota_sdk=$(metadata_value post-sdk-level)
  ota_security_patch=$(metadata_value post-security-patch-level)
  ota_timestamp=$(metadata_value post-timestamp)
  ota_build_id=$(cut -d/ -f4 <<<"$ota_fingerprint")

  [[ "$ota_type" == AB ]] || die "expected an A/B OTA; metadata reports ${ota_type:-unknown}"
  [[ "$ota_device" == "$DEVICE_CODENAME" ]] || \
    die "OTA is for ${ota_device:-unknown}, not $DEVICE_CODENAME"
  [[ "$ota_build_id" == "$STOCK_BUILD_ID" ]] || \
    die "OTA build is ${ota_build_id:-unknown}, not $STOCK_BUILD_ID"
  [[ "$ota_fingerprint" == \
    "google/$DEVICE_CODENAME/$DEVICE_CODENAME:17/$STOCK_BUILD_ID/"*":user/release-keys" ]] || \
    die "OTA post-build fingerprint is not the expected stock Pixel 11 form"
  [[ "$ota_incremental" =~ ^[0-9]+$ ]] || die "OTA incremental is malformed"
  [[ "$ota_sdk" == 37 ]] || die "expected OTA SDK 37; found ${ota_sdk:-unknown}"
  [[ "$ota_security_patch" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || \
    die "OTA security patch is malformed"
  [[ "$ota_timestamp" =~ ^[0-9]+$ ]] || die "OTA timestamp is malformed"

  note "verified pinned full A/B OTA for $DEVICE_CODENAME $STOCK_BUILD_ID"
  printf 'OTA fingerprint: %s\n' "$ota_fingerprint"
  printf 'OTA security patch: %s\n' "$ota_security_patch"
  note "the full OTA payload includes inactive-slot bootchain, modem, and logical partitions"
  printf 'OTA A/B partition allowlist: %s\n' "$expected_ota_partitions"
}

find_single_adb() {
  select_pinned_adb
  probe_single_adb || die "expected exactly one ADB transport"
}

select_pinned_adb() {
  local digest output version
  [[ -z "$adb_bin" ]] || return 0
  if [[ -n "${ADB:-}" ]]; then
    [[ "$ADB" == /* ]] || die "ADB must be an absolute path"
    adb_bin=$ADB
  else
    adb_bin="$project_root/work/toolchains/platform-tools/adb"
  fi
  [[ -f "$adb_bin" && ! -L "$adb_bin" && -x "$adb_bin" ]] || \
    die "pinned workspace adb is not a safe executable: $adb_bin"
  adb_bin=$(realpath -e -- "$adb_bin")
  digest=$(sha256sum "$adb_bin" | awk '{print $1}')
  [[ "$digest" == "$PLATFORM_TOOLS_ADB_SHA256" ]] || \
    die "adb does not match the pinned Platform-Tools binary digest"
  output=$("$adb_bin" version 2>&1)
  if [[ "$output" =~ Version[[:space:]]([0-9]+(\.[0-9]+)*)- ]]; then
    version=${BASH_REMATCH[1]}
  else
    die "unable to determine adb version"
  fi
  [[ "$version" == "$PLATFORM_TOOLS_VERSION" ]] || die \
    "this release is pinned to adb $PLATFORM_TOOLS_VERSION; found $version"
}

probe_single_adb() {
  local -a records=()
  local record

  [[ -n "$adb_bin" ]] || die "pinned adb is not selected"
  mapfile -t records < <("$adb_bin" devices | \
    awk 'NR > 1 && NF >= 2 {print $1 "\t" $2}')
  (( ${#records[@]} == 1 )) || return 1
  record=${records[0]}
  adb_serial=${record%%$'\t'*}
  adb_state=${record#*$'\t'}
}

adb_prop() {
  local property=$1
  timeout 20 "$adb_bin" -s "$adb_serial" shell getprop "$property" | tr -d '\r'
}

check_virtual_ab_shared_super() {
  local expected_slot=$1
  local layout_digest layout_lines='' lpdump_output partition
  local -A first_sector=()

  lpdump_output=$(timeout 30 "$adb_bin" -s "$adb_serial" shell lpdump -a | tr -d '\r') || \
    die "unable to inspect virtual A/B metadata with lpdump"
  [[ $(grep -c "^Current slot: _$expected_slot$" <<<"$lpdump_output") -ge 1 ]] || \
    die "lpdump does not agree that Android is running slot $expected_slot"
  [[ $(grep -c '^Header flags: .*virtual_ab_device' <<<"$lpdump_output") -ge 2 ]] || \
    die "both logical metadata views are not marked virtual A/B"
  [[ $(grep -c '^Update state: none$' <<<"$lpdump_output") -eq 1 ]] || \
    die "virtual A/B update state is not exactly none"

  while read -r partition sector; do
    [[ -n "$partition" && "$sector" =~ ^[0-9]+$ ]] || \
      die "malformed first-extent record from lpdump"
    first_sector["$partition"]=$sector
  done < <(
    awk '
      /^  Name: / { partition = $2; next }
      partition != "" && /^    0 \.\./ {
        print partition, $NF
        partition = ""
      }
    ' <<<"$lpdump_output"
  )
  for partition in \
    system system_dlkm system_ext product vendor vendor_dlkm; do
    [[ -n "${first_sector[${partition}_a]+present}" && \
       -n "${first_sector[${partition}_b]+present}" ]] || \
      die "lpdump is missing slot views for $partition"
    [[ "${first_sector[${partition}_a]}" == \
       "${first_sector[${partition}_b]}" ]] || \
      die "$partition A/B views do not begin on the same audited super extent"
    layout_lines+="${partition}=${first_sector[${partition}_a]}:${first_sector[${partition}_b]}"$'\n'
  done
  layout_digest=$(printf '%s' "$layout_lines" | sha256sum | awk '{print $1}')
  [[ "$layout_digest" == "$CUBS_SHARED_SUPER_LAYOUT_SHA256" ]] || \
    die "shared-super layout differs from the exact audited cubs baseline"
  note "verified no pending snapshot and shared physical super extents for A/B logical views"
}

check_android() {
  local expected_slot=$1
  local ab_ota_partitions baseband battery_info battery_level boot_completed
  local bootloader build_id build_timestamp build_type device fingerprint
  local flash_locked incremental modem sdk security_patch slot_suffix
  local uptime_raw uptime_seconds vbmeta_state verified_boot_state
  local -a modem_versions=()

  require_no_stock_restore_transaction
  check_ota
  load_stock_requirements
  find_single_adb
  [[ "$adb_state" == device ]] || \
    die "the single ADB transport is '$adb_state'; enable USB debugging and accept the RSA prompt"

  device=$(adb_prop ro.product.device)
  build_id=$(adb_prop ro.build.id)
  fingerprint=$(adb_prop ro.build.fingerprint)
  incremental=$(adb_prop ro.build.version.incremental)
  sdk=$(adb_prop ro.build.version.sdk)
  security_patch=$(adb_prop ro.build.version.security_patch)
  build_type=$(adb_prop ro.build.type)
  build_timestamp=$(adb_prop ro.build.date.utc)
  slot_suffix=$(adb_prop ro.boot.slot_suffix)
  bootloader=$(adb_prop ro.bootloader)
  baseband=$(adb_prop gsm.version.baseband)
  ab_ota_partitions=$(adb_prop ro.product.ab_ota_partitions)
  flash_locked=$(adb_prop ro.boot.flash.locked)
  vbmeta_state=$(adb_prop ro.boot.vbmeta.device_state)
  verified_boot_state=$(adb_prop ro.boot.verifiedbootstate)
  boot_completed=$(adb_prop sys.boot_completed)
  battery_info=$(timeout 20 "$adb_bin" -s "$adb_serial" shell dumpsys battery | tr -d '\r')
  battery_level=$(awk -F: '/^[[:space:]]*level:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' \
    <<<"$battery_info")

  [[ "$device" == "$DEVICE_CODENAME" ]] || \
    die "expected Android product $DEVICE_CODENAME; found ${device:-unknown}"
  [[ "$build_id" == "$STOCK_BUILD_ID" ]] || \
    die "expected stock build $STOCK_BUILD_ID; found ${build_id:-unknown}"
  [[ "$fingerprint" == "$ota_fingerprint" ]] || \
    die "Android fingerprint does not exactly match the pinned OTA"
  [[ "$incremental" == "$ota_incremental" ]] || \
    die "Android incremental does not exactly match the pinned OTA"
  [[ "$sdk" == "$ota_sdk" ]] || die "Android SDK does not match the pinned OTA"
  [[ "$security_patch" == "$ota_security_patch" ]] || \
    die "Android security patch does not exactly match the pinned OTA"
  [[ "$build_type" == user ]] || die "expected untouched stock user build; found $build_type"
  [[ "$build_timestamp" == "$(metadata_value post-timestamp)" ]] || \
    die "Android build timestamp does not exactly match the pinned full OTA"
  [[ "$slot_suffix" == "_$expected_slot" ]] || \
    die "expected stock slot $expected_slot; found ${slot_suffix:-unknown}"
  [[ "$bootloader" == "$expected_bootloader" ]] || \
    die "Android bootloader baseline mismatch: expected $expected_bootloader; found ${bootloader:-unknown}"
  IFS=, read -r -a modem_versions <<<"$baseband"
  (( ${#modem_versions[@]} > 0 )) || die "Android reports no modem firmware"
  for modem in "${modem_versions[@]}"; do
    [[ "$modem" == "$expected_baseband" ]] || \
      die "Android baseband baseline mismatch: expected $expected_baseband; found ${baseband:-unknown}"
  done
  [[ "$ab_ota_partitions" == "$expected_ota_partitions" ]] || \
    die "Android A/B OTA partition allowlist does not match the audited full payload"
  [[ "$flash_locked" == 0 ]] || die "bootloader is not reported unlocked by Android"
  [[ -z "$vbmeta_state" || "$vbmeta_state" == unlocked ]] || \
    die "vbmeta device state is neither absent nor unlocked"
  [[ "$verified_boot_state" == orange ]] || \
    die "expected orange verified-boot state on unlocked stock; found ${verified_boot_state:-unknown}"
  [[ "$boot_completed" == 1 ]] || die "Android has not completed boot"
  [[ "$battery_level" =~ ^[0-9]+$ ]] || die "unable to read Android battery level"
  (( battery_level >= 50 )) || die "battery must be at least 50%; found $battery_level%"

  check_virtual_ab_shared_super "$expected_slot"

  if [[ "$expected_slot" == b ]]; then
    uptime_raw=$(timeout 20 "$adb_bin" -s "$adb_serial" shell cat /proc/uptime | tr -d '\r')
    uptime_seconds=${uptime_raw%%.*}
    [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || die "unable to read Android uptime"
    (( uptime_seconds >= 120 )) || \
      die "leave stock slot B running for at least two minutes before verification"
  fi

  note "verified exact stock $STOCK_BUILD_ID on Android slot $expected_slot"
  printf 'boot completed: %s\n' "$boot_completed"
  printf 'battery level: %s%%\n' "$battery_level"
}

find_single_fastboot() {
  probe_single_fastboot || die "expected exactly one fastboot device"
}

probe_single_fastboot() {
  local -a devices=()
  [[ -n "$fastboot_bin" ]] || die "pinned fastboot is not selected"
  mapfile -t devices < <("$fastboot_bin" devices | awk 'NF {print $1}')
  (( ${#devices[@]} == 1 )) || return 1
  fastboot_serial=${devices[0]}
  [[ "$fastboot_serial" != -* && ! "$fastboot_serial" =~ [[:space:]] ]] || \
    die "invalid fastboot serial"
}

fastboot_value() {
  local variable=$1
  local output
  output=$("$fastboot_bin" -s "$fastboot_serial" getvar "$variable" 2>&1) || true
  sed -nE "s/^(\(bootloader\)[[:space:]]*)?$variable:[[:space:]]*//p" \
    <<<"$output" | tail -n 1
}

select_pinned_fastboot() {
  local digest output version
  if [[ -n "${FASTBOOT:-}" ]]; then
    [[ "$FASTBOOT" == /* ]] || die "FASTBOOT must be an absolute path"
    fastboot_bin=$FASTBOOT
  elif [[ -x "$project_root/work/toolchains/platform-tools/fastboot" ]]; then
    fastboot_bin="$project_root/work/toolchains/platform-tools/fastboot"
  else
    require_command fastboot
    fastboot_bin=$(command -v fastboot)
  fi
  [[ -f "$fastboot_bin" && ! -L "$fastboot_bin" && -x "$fastboot_bin" ]] || \
    die "fastboot is not a safe executable: $fastboot_bin"
  fastboot_bin=$(realpath -e -- "$fastboot_bin")
  digest=$(sha256sum "$fastboot_bin" | awk '{print $1}')
  [[ "$digest" == "$PLATFORM_TOOLS_FASTBOOT_SHA256" ]] || \
    die "fastboot does not match the pinned Platform-Tools binary digest"
  output=$("$fastboot_bin" --version 2>&1)
  if [[ "$output" =~ fastboot[[:space:]]version[[:space:]]([0-9]+(\.[0-9]+)*) ]]; then
    version=${BASH_REMATCH[1]}
  else
    die "unable to determine fastboot version"
  fi
  [[ "$version" == "$PLATFORM_TOOLS_VERSION" ]] || die \
    "this release is pinned to fastboot $PLATFORM_TOOLS_VERSION; found $version"
}

require_nonzero_fastboot_partition() {
  local partition=$1
  local size
  size=$(fastboot_value "partition-size:$partition")
  [[ "$size" =~ ^(0[xX])?[0-9a-fA-F]+$ && \
     "$size" =~ [1-9a-fA-F] ]] || \
    die "unable to prove a nonzero partition size for $partition"
  printf '%s\n' "$size"
}

check_physical_b_lifeboat() {
  local partition
  for partition in "${lifeboat_partitions[@]}"; do
    [[ $(fastboot_value "has-slot:$partition") == yes ]] || \
      die "$partition is not reported slotted"
    [[ $(fastboot_value "is-logical:${partition}_a") == no && \
       $(fastboot_value "is-logical:${partition}_b") == no ]] || \
      die "$partition is not reported as a physical A/B partition"
    require_nonzero_fastboot_partition "${partition}_a" >/dev/null
    require_nonzero_fastboot_partition "${partition}_b" >/dev/null
  done
  note "verified all 34 nonzero, slotted physical B firmware and lifeboat partitions"
}

verify_live_vendor_boot_b_control() {
  local actual_sha fetched size_hex target_size
  fetched=$(mktemp "$cubs_recovery_state_dir/.vendor-boot-b-fetch.XXXXXX")
  rm -f -- "$fetched"
  "$fastboot_bin" -s "$fastboot_serial" fetch vendor_boot_b "$fetched"
  [[ -f "$fetched" && ! -L "$fetched" && \
     $(stat -c '%u' "$fetched") == "$EUID" && \
     $(stat -c '%h' "$fetched") == 1 ]] || \
    die "live vendor_boot_b fetch is unsafe"
  target_size=$(cubs_normalize_partition_size \
    "$(fastboot_value partition-size:vendor_boot_b)")
  size_hex=$(printf '%x' "$(stat -c '%s' "$fetched")")
  [[ "$size_hex" == "$target_size" ]] || {
    rm -f -- "$fetched"
    die "live vendor_boot_b fetch does not cover its full physical partition"
  }
  actual_sha=$(sha256sum "$fetched" | awk '{print $1}')
  rm -f -- "$fetched"
  [[ "$actual_sha" == "$CUBS_STOCK_VENDOR_BOOT_SHA256" ]] || \
    die "live vendor_boot_b bytes differ from the exact lifeboat pin"
}

check_fastboot_anchor() {
  local verification_mode=${1:-lineage_aware}
  local baseband bootloader current_slot product slot_a_successful slot_a_unbootable
  local physical_sizes_sha256 slot_b_successful slot_b_unbootable
  local snapshot_status unlocked userspace

  require_no_stock_restore_transaction
  load_stock_requirements
  select_pinned_fastboot
  find_single_fastboot
  product=$(fastboot_value product)
  bootloader=$(fastboot_value version-bootloader)
  baseband=$(fastboot_value version-baseband)
  unlocked=$(fastboot_value unlocked)
  userspace=$(fastboot_value is-userspace)
  current_slot=$(fastboot_value current-slot)
  snapshot_status=$(fastboot_value snapshot-update-status)
  slot_a_successful=$(fastboot_value slot-successful:a)
  slot_a_unbootable=$(fastboot_value slot-unbootable:a)
  slot_b_successful=$(fastboot_value slot-successful:b)
  slot_b_unbootable=$(fastboot_value slot-unbootable:b)

  [[ "$product" == "$DEVICE_CODENAME" ]] || \
    die "expected product $DEVICE_CODENAME; found ${product:-unknown}"
  [[ "$bootloader" == "$expected_bootloader" ]] || \
    die "bootloader mismatch: expected $expected_bootloader; found ${bootloader:-unknown}"
  [[ "$baseband" == "$expected_baseband" ]] || \
    die "baseband mismatch: expected $expected_baseband; found ${baseband:-unknown}"
  [[ "$unlocked" == yes ]] || die "device bootloader is not unlocked"
  [[ "$userspace" == no ]] || die "verification must run in bootloader fastboot, not fastbootd"
  [[ "$current_slot" == b ]] || die "expected current slot B; found ${current_slot:-unknown}"
  [[ "$snapshot_status" == none ]] || \
    die "snapshot update has not settled; status is ${snapshot_status:-unknown}"
  [[ "$slot_b_unbootable" == no ]] || die "slot B is marked unbootable"
  [[ "$slot_a_successful" == yes ]] || die "slot A is not marked successful"
  [[ "$slot_a_unbootable" == no ]] || die "slot A is marked unbootable"

  check_physical_b_lifeboat
  if [[ "$verification_mode" == new_full_ota ]]; then
    [[ "$slot_b_successful" == yes ]] || \
      die "new full-OTA slot B has not been marked successful"
  elif [[ "$verification_mode" == lineage_aware && \
          ( -e "$cubs_recovery_lineage" || -L "$cubs_recovery_lineage" ) ]]; then
    [[ -f "$cubs_recovery_lineage" && ! -L "$cubs_recovery_lineage" ]] || \
      die "existing recovery lineage is unsafe"
    physical_sizes_sha256=$(cubs_physical_b_sizes_sha256)
    cubs_verify_lifeboat_lineage "$fastboot_serial" "$physical_sizes_sha256" \
      "$bootloader" "$baseband"
    cubs_require_verified_lineage_b_success "$slot_b_successful"
  elif [[ "$verification_mode" == lineage_aware ]]; then
    [[ "$slot_b_successful" == yes ]] || \
      die "new full-OTA slot B has not been marked successful"
  else
    die "invalid fastboot-anchor verification mode"
  fi
  note "B boot-control flags and all 34 physical lifeboat partitions are ready"
  note "these flags do not prove Android B after any shared-super logical write"
}

confirm_action() {
  local environment_name=$1
  local phrase=$2
  local entered

  [[ "${!environment_name:-}" == 1 ]] || \
    die "set $environment_name=1 only after reviewing docs/recovery-anchor.md"
  [[ -t 0 && -t 1 ]] || die "refusing state change without an interactive terminal"
  printf '\nType exactly: %s\n> ' "$phrase" >/dev/tty
  IFS= read -r entered </dev/tty
  [[ "$entered" == "$phrase" ]] || die "confirmation phrase did not match"
}

check_recovery_usb_policy() {
  local policy_found=false policy_line policy_output policy_upper

  # USBIPD_EXE selects only a location. The reviewed payload identity comes
  # exclusively from recovery.env and is checked before the candidate runs.
  cubs_verify_usbipd_win_executable "$usbipd_exe" \
    "$CUBS_USBIPD_WIN_EXE_SIZE" \
    "$CUBS_USBIPD_WIN_EXE_SHA256" \
    "$CUBS_USBIPD_WIN_VERSION_OUTPUT"
  policy_output=$(cubs_usbipd_win_policy_list --stdout) || \
    die "unable to inspect usbipd-win policy rules"
  while IFS= read -r policy_line; do
    policy_upper=${policy_line^^}
    if [[ "$policy_upper" == *ALLOW* && \
          "$policy_upper" == *AUTOBIND* && \
          "$policy_upper" == *18D1:D001* ]]; then
      policy_found=true
      break
    fi
  done <<<"$policy_output"
  [[ "$policy_found" == true ]] || die \
    "usbipd policy list has no Allow/AutoBind rule for recovery USB 18d1:d001"
  note "verified usbipd Allow/AutoBind policy for recovery USB 18d1:d001"
}

write_sideload_state() {
  local serial_hash
  serial_hash=$(printf '%s' "$adb_serial" | sha256sum | awk '{print $1}')
  assert_inside_project "$state_file"
  cubs_prepare_recovery_state_dir
  umask 077
  {
    printf 'created=%s\n' "$(date +%s)"
    printf 'serial_sha256=%s\n' "$serial_hash"
    printf 'ota_sha256=%s\n' "$FULL_OTA_SHA256"
    printf 'source_slot=a\n'
  } >"$state_file"
}

state_value() {
  local key=$1
  sed -nE "s/^$key=//p" "$state_file" | tail -n 1
}

check_sideload_state() {
  local age created current_serial_hash saved_serial_hash saved_ota_hash source_slot

  require_file "$state_file"
  created=$(state_value created)
  saved_serial_hash=$(state_value serial_sha256)
  saved_ota_hash=$(state_value ota_sha256)
  source_slot=$(state_value source_slot)
  [[ "$created" =~ ^[0-9]+$ ]] || die "invalid sideload preflight timestamp"
  [[ "$saved_serial_hash" =~ ^[0-9a-f]{64}$ ]] || die "invalid sideload device marker"
  [[ "$saved_ota_hash" == "$FULL_OTA_SHA256" ]] || die "sideload marker is for another OTA"
  [[ "$source_slot" == a ]] || die "sideload marker was not created from verified stock A"
  age=$(( $(date +%s) - created ))
  (( age >= 0 && age <= 3600 )) || \
    die "sideload preflight is older than one hour; return to stock A and start again"

  current_serial_hash=$(printf '%s' "$adb_serial" | sha256sum | awk '{print $1}')
  [[ "$current_serial_hash" == "$saved_serial_hash" ]] || \
    die "recovery transport is not the device checked before reboot"
}

wait_for_sideload() {
  local deadline=$((SECONDS + 300))
  local next_notice=$SECONDS

  while (( SECONDS < deadline )); do
    if probe_single_adb 2>/dev/null && [[ "$adb_state" == sideload ]]; then
      check_sideload_state
      note "recovery sideload transport is attached"
      return 0
    fi
    if (( SECONDS >= next_notice )); then
      note "waiting for recovery USB (18d1:d001) to attach to WSL"
      next_notice=$((SECONDS + 15))
    fi
    sleep 2
  done
  die "recovery USB did not attach within five minutes; fix forwarding, then run resume-sideload"
}

send_sideload() {
  check_ota
  find_single_adb
  [[ "$adb_state" == sideload ]] || \
    die "expected exactly one recovery transport in sideload state; found '$adb_state'"
  check_sideload_state

  note "sending the checksum-pinned full OTA; do not disconnect USB"
  "$adb_bin" -s "$adb_serial" sideload "$ota_path"
  assert_inside_project "$state_file"
  rm -f -- "$state_file"
  note "OTA transfer completed without a host-side error"
  note "consumed the one-hour sideload authorization marker"
  note "do not assume the anchor is ready until both verification stages pass"
  note "stock B disables USB debugging: enable it and accept RSA, then run verify-android"
}

install_anchor() {
  cubs_lock_recovery_state
  cubs_require_no_stock_b_preparation
  [[ ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
    die "an active flash handoff must be consumed or recovered before another OTA anchor"
  [[ "${CUBS_RECOVERY_USB_READY:-}" == 1 ]] || \
    die "set CUBS_RECOVERY_USB_READY=1 only after recovery USB auto-attach is ready"
  check_recovery_usb_policy
  check_android a
  confirm_action CUBS_ALLOW_SLOT_B_OTA \
    "install $STOCK_BUILD_ID full OTA including inactive-slot firmware into B"
  write_sideload_state

  note "rebooting exact stock slot A into recovery sideload-auto-reboot"
  "$adb_bin" -s "$adb_serial" reboot sideload-auto-reboot
  wait_for_sideload
  send_sideload
}

resume_sideload() {
  cubs_lock_recovery_state
  cubs_require_no_stock_b_preparation
  [[ ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
    die "an active flash handoff must be consumed or recovered before resuming an OTA"
  [[ "${CUBS_RECOVERY_USB_READY:-}" == 1 ]] || \
    die "set CUBS_RECOVERY_USB_READY=1 only after recovery USB forwarding is fixed"
  check_recovery_usb_policy
  check_ota
  find_single_adb
  [[ "$adb_state" == sideload ]] || \
    die "expected exactly one recovery transport in sideload state; found '$adb_state'"
  check_sideload_state
  confirm_action CUBS_ALLOW_SLOT_B_OTA \
    "resume $STOCK_BUILD_ID full OTA including inactive-slot firmware"
  send_sideload
}

reboot_and_verify() {
  local anchor_id expected_serial_binding observed_serial_binding
  local physical_sizes_sha256
  cubs_lock_recovery_state
  cubs_require_no_stock_b_preparation
  [[ ! -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
    die "an active recovery handoff already exists; consume or recover it first"
  check_android b
  select_pinned_fastboot
  anchor_id=$(cubs_random_anchor_id)
  expected_serial_binding=$(cubs_serial_binding "$anchor_id" "$adb_serial")
  confirm_action CUBS_ALLOW_BOOTLOADER_REBOOT \
    "reboot verified stock B to bootloader and inspect the anchor"
  select_pinned_fastboot
  "$adb_bin" -s "$adb_serial" reboot bootloader

  note "waiting for bootloader fastboot to attach"
  for _ in {1..60}; do
    if probe_single_fastboot 2>/dev/null; then
      observed_serial_binding=$(cubs_serial_binding "$anchor_id" "$fastboot_serial")
      [[ "$observed_serial_binding" == "$expected_serial_binding" ]] || \
        die "bootloader transport is not the Android device verified before reboot"
      check_fastboot_anchor new_full_ota
      physical_sizes_sha256=$(cubs_physical_b_sizes_sha256)
      cubs_write_lineage_and_handoff "$anchor_id" \
        "$observed_serial_binding" "$physical_sizes_sha256" \
        "$expected_bootloader" "$expected_baseband"
      note "created a one-hour private stock-B flash handoff"
      return 0
    fi
    sleep 2
  done
  die "bootloader fastboot did not attach within two minutes"
}

check_full_ota_merge_candidate() {
  local baseband bootloader current_slot product slot_b_successful
  local slot_b_unbootable snapshot_status unlocked userspace
  local path

  cubs_require_no_stock_b_preparation
  for path in "$cubs_recovery_lineage" "$cubs_recovery_handoff"; do
    [[ ! -e "$path" && ! -L "$path" ]] || \
      die "B merge continuation is forbidden after any recovery lineage was published"
  done
  load_stock_requirements
  select_pinned_fastboot
  find_single_fastboot
  product=$(fastboot_value product)
  bootloader=$(fastboot_value version-bootloader)
  baseband=$(fastboot_value version-baseband)
  unlocked=$(fastboot_value unlocked)
  userspace=$(fastboot_value is-userspace)
  current_slot=$(fastboot_value current-slot)
  snapshot_status=$(fastboot_value snapshot-update-status)
  slot_b_successful=$(fastboot_value slot-successful:b)
  slot_b_unbootable=$(fastboot_value slot-unbootable:b)

  [[ "$product" == "$DEVICE_CODENAME" ]] || \
    die "expected product $DEVICE_CODENAME; found ${product:-unknown}"
  [[ "$bootloader" == "$expected_bootloader" ]] || \
    die "bootloader mismatch: expected $expected_bootloader; found ${bootloader:-unknown}"
  [[ "$baseband" == "$expected_baseband" ]] || \
    die "baseband mismatch: expected $expected_baseband; found ${baseband:-unknown}"
  [[ "$unlocked" == yes ]] || die "device bootloader is not unlocked"
  [[ "$userspace" == no ]] || die "merge continuation must start in bootloader fastboot"
  [[ "$current_slot" == b ]] || die "refusing to continue the merge from a slot other than B"
  [[ "$slot_b_successful" == yes ]] || \
    die "refusing to boot B because it is not marked successful"
  [[ "$slot_b_unbootable" == no ]] || die "refusing to boot B because it is marked unbootable"
  case "$snapshot_status" in
    merging|snapshotted)
      ;;
    none)
      die "no snapshot is pending; run verify-fastboot instead"
      ;;
    *)
      die "unsupported snapshot state: ${snapshot_status:-unknown}"
      ;;
  esac

  check_physical_b_lifeboat
}

continue_b_merge() {
  cubs_lock_recovery_state
  check_full_ota_merge_candidate

  confirm_action CUBS_ALLOW_STOCK_B_REBOOT \
    "reboot current stock B and allow its snapshot to settle"
  check_full_ota_merge_candidate
  "$fastboot_bin" -s "$fastboot_serial" reboot
  note "stock B is booting; USB debugging will be disabled"
  note "enable it, accept RSA, wait at least two minutes, then repeat reboot-and-verify"
}

verify_selector_handoff() {
  local physical_sizes_sha256=$1 created expires now
  local -A handoff=()

  cubs_verify_lifeboat_handoff_for_recovery "$physical_sizes_sha256"
  cubs_load_exact_kv "$cubs_recovery_handoff" handoff \
    schema state handoff_kind created_epoch expires_epoch claimed_epoch \
    anchor_id serial_binding_sha256 lineage_sha256 physical_b_sizes_sha256 \
    recovery_policy_sha256 bundle_kind bundle_manifest_sha256
  [[ "${handoff[state]}" == ready && \
     "${handoff[handoff_kind]}" == physical_b_lifeboat && \
     "${handoff[claimed_epoch]}" == 0 && \
     "${handoff[bundle_kind]}" == none && \
     "${handoff[bundle_manifest_sha256]}" == none ]] || \
    die "selector continuation requires its exact unclaimed physical-lifeboat handoff"
  created=${handoff[created_epoch]}
  expires=${handoff[expires_epoch]}
  now=$(date +%s)
  (( 10#$now >= 10#$created )) || \
    die "selector handoff is dated in the future"
  if (( 10#$now <= 10#$expires )); then
    selector_handoff_freshness=fresh
  else
    selector_handoff_freshness=stale
  fi
  selector_handoff_sha256=$cubs_verified_recovery_handoff_sha256
}

check_select_b_lifeboat_candidate() {
  local baseband bootloader current_slot product slot_a_successful slot_a_unbootable
  local slot_b_successful
  local physical_sizes_sha256 slot_b_unbootable snapshot_status unlocked userspace

  require_no_stock_restore_transaction
  load_stock_requirements
  select_pinned_fastboot
  find_single_fastboot
  product=$(fastboot_value product)
  bootloader=$(fastboot_value version-bootloader)
  baseband=$(fastboot_value version-baseband)
  unlocked=$(fastboot_value unlocked)
  userspace=$(fastboot_value is-userspace)
  current_slot=$(fastboot_value current-slot)
  snapshot_status=$(fastboot_value snapshot-update-status)
  slot_a_successful=$(fastboot_value slot-successful:a)
  slot_a_unbootable=$(fastboot_value slot-unbootable:a)
  slot_b_successful=$(fastboot_value slot-successful:b)
  slot_b_unbootable=$(fastboot_value slot-unbootable:b)

  [[ "$product" == "$DEVICE_CODENAME" ]] || \
    die "expected product $DEVICE_CODENAME; found ${product:-unknown}"
  [[ "$bootloader" == "$expected_bootloader" ]] || \
    die "bootloader mismatch: expected $expected_bootloader; found ${bootloader:-unknown}"
  [[ "$baseband" == "$expected_baseband" ]] || \
    die "baseband mismatch: expected $expected_baseband; found ${baseband:-unknown}"
  [[ "$unlocked" == yes ]] || die "device bootloader is not unlocked"
  [[ "$userspace" == no ]] || \
    die "lifeboat selection must start in bootloader fastboot"
  [[ "$current_slot" =~ ^(a|b)$ ]] || \
    die "lifeboat selection requires current physical slot A or B"
  [[ "$snapshot_status" == none ]] || \
    die "snapshot update status must be none; found ${snapshot_status:-unknown}"
  [[ "$slot_b_successful" =~ ^(yes|no)$ && "$slot_b_unbootable" == no ]] || \
    die "physical slot B is not eligible as the fastbootd lifeboat"
  [[ "$slot_a_successful" == yes && "$slot_a_unbootable" == no ]] || \
    die "healthy stock slot A is unavailable for lifeboat selection"
  check_physical_b_lifeboat
  physical_sizes_sha256=$(cubs_physical_b_sizes_sha256)
  cubs_verify_lifeboat_lineage "$fastboot_serial" "$physical_sizes_sha256" \
    "$bootloader" "$baseband"

  selector_current_slot=$current_slot
  selector_physical_sizes_sha256=$physical_sizes_sha256
  selector_handoff_sha256=none
  selector_handoff_freshness=none
  if [[ -e "$cubs_recovery_handoff" || -L "$cubs_recovery_handoff" ]]; then
    [[ -f "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
      die "selector recovery handoff is unsafe"
    verify_selector_handoff "$physical_sizes_sha256"
  fi
  if [[ "$cubs_verified_stock_b_source" == full_ota && \
        "$slot_b_successful" == no ]]; then
    [[ "$current_slot" == b && "$selector_handoff_sha256" != none ]] || \
      die "full-OTA B lost successful before a bound selector activation"
  else
    cubs_require_verified_lineage_b_success "$slot_b_successful"
  fi
  verify_live_vendor_boot_b_control
}

select_b_lifeboat() {
  local first_handoff_sha256 first_physical_sizes_sha256

  cubs_lock_recovery_state
  check_select_b_lifeboat_candidate
  first_physical_sizes_sha256=$selector_physical_sizes_sha256
  first_handoff_sha256=$selector_handoff_sha256

  confirm_action CUBS_ALLOW_SELECT_B_LIFEBOAT \
    "select physical B for immediate fastbootd use; never boot Android B"

  # The prompt may remain open indefinitely. Repeat the exact tool, sole
  # transport, identity, flags, snapshot, size, lineage, handoff, and live-byte
  # checks before publishing authorization or changing boot control.
  check_select_b_lifeboat_candidate
  [[ "$selector_physical_sizes_sha256" == "$first_physical_sizes_sha256" && \
     "$selector_handoff_sha256" == "$first_handoff_sha256" ]] || \
    die "lifeboat state changed while waiting for selection confirmation"

  if [[ "$selector_handoff_freshness" == stale ]]; then
    cubs_verify_stale_ready_handoff "$fastboot_serial" \
      "$selector_physical_sizes_sha256" "$expected_bootloader" "$expected_baseband"
    cubs_reissue_verified_stale_handoff "$selector_physical_sizes_sha256"
    check_select_b_lifeboat_candidate
    [[ "$selector_handoff_freshness" == fresh ]] || \
      die "reissued selector handoff is not fresh"
  elif [[ "$selector_handoff_sha256" == none ]]; then
    # Publish the exact ready receipt first. If the host disappears after the
    # subsequent set_active ACK, rerunning this action can safely finish from B.
    cubs_write_lifeboat_handoff "$selector_physical_sizes_sha256"
    check_select_b_lifeboat_candidate
    [[ "$selector_handoff_freshness" == fresh ]] || \
      die "new selector handoff is not fresh"
  fi

  if [[ "$selector_current_slot" == a ]]; then
    "$fastboot_bin" -s "$fastboot_serial" set_active b
  else
    note "physical B is already selected; finalizing the bound selector receipt"
  fi
  check_select_b_lifeboat_candidate
  [[ "$selector_current_slot" == b && \
     "$selector_handoff_freshness" == fresh ]] || \
    die "physical B selection did not finish with a fresh exact handoff"
  note "physical B is selected; the phone remains in bootloader fastboot"
  note "a fresh one-hour private physical-lifeboat handoff is ready"
  note "run the reviewed flash-all.sh next; do not reboot invalid Android B"
}

reissue_stale_handoff() {
  local first_physical_sizes_sha256 second_physical_sizes_sha256

  cubs_lock_recovery_state
  [[ -e "$cubs_recovery_handoff" && ! -L "$cubs_recovery_handoff" ]] || \
    die "an existing regular recovery handoff is required for stale reissue"

  # Verify before asking for confirmation, then repeat every live-device and
  # receipt check after the operator responds. This action never sends a
  # mutating fastboot command; it changes only the locked private host receipt.
  check_fastboot_anchor
  verify_live_vendor_boot_b_control
  first_physical_sizes_sha256=$(cubs_physical_b_sizes_sha256)
  cubs_verify_stale_ready_handoff "$fastboot_serial" \
    "$first_physical_sizes_sha256" "$expected_bootloader" "$expected_baseband"

  confirm_action CUBS_ALLOW_STALE_HANDOFF_REISSUE \
    "archive the expired unclaimed handoff and issue a fresh one for immediate flashing"

  check_fastboot_anchor
  verify_live_vendor_boot_b_control
  second_physical_sizes_sha256=$(cubs_physical_b_sizes_sha256)
  [[ "$second_physical_sizes_sha256" == "$first_physical_sizes_sha256" ]] || \
    die "physical slot-B sizes changed while authorizing handoff reissue"
  cubs_verify_stale_ready_handoff "$fastboot_serial" \
    "$second_physical_sizes_sha256" "$expected_bootloader" "$expected_baseband"
  cubs_reissue_verified_stale_handoff "$second_physical_sizes_sha256"

  note "archived the expired unclaimed handoff without deleting its evidence"
  note "created a fresh one-hour private handoff; run the reviewed flash-all.sh immediately"
  note "the phone remains unchanged in bootloader fastboot on physical slot B"
}

action=${1:-}
case "$action" in
  check-ota)
    check_ota
    ;;
  preflight-android)
    check_android a
    ;;
  install)
    install_anchor
    ;;
  resume-sideload)
    resume_sideload
    ;;
  verify-android)
    cubs_lock_recovery_state
    cubs_require_no_stock_b_preparation
    check_android b
    note "verified stock B through the full-OTA lineage path"
    note "stock B is stable enough for the separately gated bootloader verification"
    ;;
  reboot-and-verify)
    reboot_and_verify
    ;;
  continue-b-merge)
    continue_b_merge
    ;;
  verify-fastboot)
    check_fastboot_anchor
    ;;
  select-b-lifeboat)
    select_b_lifeboat
    ;;
  reissue-stale-handoff)
    reissue_stale_handoff
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
