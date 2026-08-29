#!/usr/bin/env bash
set -euo pipefail

state_dir=${MOCK_FASTBOOT_STATE_DIR:?set MOCK_FASTBOOT_STATE_DIR}
log_file=${MOCK_ADB_LOG:?set MOCK_ADB_LOG}
serial=${MOCK_ADB_SERIAL:-MOCK_CUBS_SERIAL}
runtime_mode=${MOCK_ADB_RUNTIME_MODE:-stock}
stock_shell_mode=${MOCK_ADB_STOCK_SHELL_MODE:-normal}

die() {
  printf 'mock-adb error: %s\n' "$*" >&2
  exit 1
}

read_state() {
  local key=$1 default=$2
  local path="$state_dir/$key"
  if [[ -f "$path" ]]; then
    sed -n '1p' "$path"
  else
    printf '%s\n' "$default"
  fi
}

write_state() {
  local key=$1 value=$2
  [[ "$key" =~ ^[a-z0-9_]+$ ]] || die "unsafe state key: $key"
  printf '%s\n' "$value" >"$state_dir/$key"
}

runtime_property() {
  local property=$1 partition build_id fingerprint

  if [[ -n "${MOCK_ADB_OVERRIDE_PROPERTY:-}" && \
        "$property" == "$MOCK_ADB_OVERRIDE_PROPERTY" ]]; then
    printf '%s\n' "${MOCK_ADB_OVERRIDE_VALUE:-}"
    return
  fi

  case "$runtime_mode" in
    gsi)
      case "$property" in
        ro.product.device) value=generic_arm64 ;;
        ro.product.vendor.device) value=cubs ;;
        ro.build.id) value=CP2A.260605.016 ;;
        ro.build.fingerprint)
          value=Android/gsi_arm64/generic_arm64:17/CP2A.260605.016/pixel_aosp17_r1:userdebug/test-keys
          ;;
        ro.adb.secure) value=0 ;;
        *) value= ;;
      esac
      ;;
    cubs)
      case "$property" in
        ro.product.device|ro.product.vendor.device) value=cubs ;;
        ro.build.id) value=CD1A.260714.001.A9 ;;
        ro.build.fingerprint)
          value=Android/cubs/cubs:17/CD1A.260714.001.A9/pixel_aosp17_r1:userdebug/test-keys
          ;;
        ro.adb.secure) value= ;;
        *) value= ;;
      esac
      ;;
    stock)
      case "$property" in
        ro.product.device) value=cubs ;;
        ro.build.id) value=CD1A.260714.001.A9 ;;
        ro.build.fingerprint)
          value=mock/stock/cubs:17/MOCK/user/release-keys
          ;;
        ro.build.type) value=user ;;
        ro.boot.slot_suffix) value=_a ;;
        ro.bootloader) value=spacecraft-17.4-15938155 ;;
        gsm.version.baseband)
          value=a900a-MP_260716-260716-M-15880348
          ;;
        sys.boot_completed) value=1 ;;
        ro.boot.flash.locked) value=0 ;;
        ro.boot.vbmeta.device_state) value=unlocked ;;
        ro.boot.verifiedbootstate) value=orange ;;
        ro.boot.snapshot_merge_status) value=none ;;
        sys.snapshot_merging) value=0 ;;
        *) value= ;;
      esac
      printf '%s\n' "$value"
      return
      ;;
    *) die "unsupported MOCK_ADB_RUNTIME_MODE: $runtime_mode" ;;
  esac

  if [[ -z "$value" ]]; then
    case "$property" in
      ro.build.type|ro.system.build.type|ro.system_ext.build.type|\
      ro.product.build.type|ro.system_dlkm.build.type|ro.vendor.build.type|\
      ro.vendor_dlkm.build.type)
        value=userdebug
        ;;
      ro.build.tags|ro.system.build.tags) value=test-keys ;;
      ro.build.version.release) value=17 ;;
      ro.build.version.sdk|ro.system.build.version.sdk) value=37 ;;
      ro.build.version.security_patch) value=2026-06-05 ;;
      ro.debuggable) value=1 ;;
      ro.secure) value=1 ;;
      service.adb.root) value= ;;
      ro.product.cpu.abilist) value=arm64-v8a ;;
      ro.product.cpu.abilist32) value= ;;
      ro.product.cpu.abilist64) value=arm64-v8a ;;
      ro.product.first_api_level) value=37 ;;
      ro.vendor.api_level) value=202604 ;;
      ro.boot.slot_suffix) value=_a ;;
      ro.boot.flash.locked) value=0 ;;
      ro.boot.verifiedbootstate) value=orange ;;
      ro.boot.vbmeta.device_state) value=unlocked ;;
      ro.boot.veritymode) value=enforcing ;;
      ro.boot.bootreason) value=reboot ;;
      ro.boot.dynamic_partitions|ro.virtual_ab.enabled|\
      ro.virtual_ab.compression.enabled|\
      ro.virtual_ab.userspace.snapshots.enabled)
        value=true
        ;;
      ro.boot.snapshot_merge_status) value=none ;;
      sys.snapshot_merging) value=0 ;;
      sys.boot_completed|dev.bootcomplete) value=1 ;;
      init.svc.bootanim) value=stopped ;;
    esac
  fi

  case "$property" in
    ro.system.build.id) partition=system ;;
    ro.system_dlkm.build.id) partition=system_dlkm ;;
    ro.system_ext.build.id) partition=system_ext ;;
    ro.product.build.id) partition=product ;;
    ro.vendor.build.id) partition=vendor ;;
    ro.vendor_dlkm.build.id) partition=vendor_dlkm ;;
    ro.system.build.fingerprint) partition=system ;;
    ro.system_dlkm.build.fingerprint) partition=system_dlkm ;;
    ro.system_ext.build.fingerprint) partition=system_ext ;;
    ro.product.build.fingerprint) partition=product ;;
    ro.vendor.build.fingerprint) partition=vendor ;;
    ro.vendor_dlkm.build.fingerprint) partition=vendor_dlkm ;;
    *) partition= ;;
  esac
  if [[ -n "$partition" ]]; then
    if [[ "$runtime_mode" == gsi && \
          "$partition" =~ ^(system|system_ext|product)$ ]]; then
      build_id=CP2A.260605.016
      fingerprint=Android/gsi_arm64/generic_arm64:17/CP2A.260605.016/pixel_aosp17_r1:userdebug/test-keys
    elif [[ "$runtime_mode" == gsi ]]; then
      build_id=CD1A.260714.001.A9
      fingerprint=google/cubs/cubs:17/CD1A.260714.001.A9/15938155:user/release-keys
    else
      build_id=CD1A.260714.001.A9
      fingerprint=Android/cubs/cubs:17/CD1A.260714.001.A9/pixel_aosp17_r1:userdebug/test-keys
    fi
    case "$property" in
      *.build.id) value=$build_id ;;
      *.build.fingerprint) value=$fingerprint ;;
    esac
  fi
  # Partition-specific type properties do not enter the identity branch above.
  case "$property" in
    ro.system_dlkm.build.type|ro.vendor.build.type|ro.vendor_dlkm.build.type)
      if [[ "$runtime_mode" == gsi ]]; then
        value=user
      else
        value=userdebug
      fi
      ;;
  esac
  printf '%s\n' "$value"
}

runtime_mounts() {
  printf '%s\n' '/dev/block/dm-0 / ext4 ro,seclabel,relatime 0 0'
  printf '%s\n' '/dev/block/dm-1 /system_dlkm erofs ro,seclabel,relatime 0 0'
  if [[ "$runtime_mode" == cubs || \
        "${MOCK_ADB_GSI_SEPARATE_SYSTEM_EXT:-0}" == 1 ]]; then
    printf '%s\n' '/dev/block/dm-2 /system_ext erofs ro,seclabel,relatime 0 0'
  fi
  if [[ "$runtime_mode" == cubs || \
        "${MOCK_ADB_GSI_SEPARATE_PRODUCT:-0}" == 1 ]]; then
    printf '%s\n' '/dev/block/dm-3 /product erofs ro,seclabel,relatime 0 0'
  fi
  printf '%s\n' '/dev/block/dm-4 /vendor erofs ro,seclabel,relatime 0 0'
  printf '%s\n' '/dev/block/dm-5 /vendor_dlkm erofs ro,seclabel,relatime 0 0'
  printf '%s\n' '/dev/block/dm-63 /data f2fs rw,seclabel 0 0'
  printf '%s\n' '/dev/block/sda12 /metadata f2fs rw,seclabel 0 0'
}

runtime_services() {
  local service
  for service in \
      SurfaceFlinger \
      android.hardware.audio.core.IConfig/default \
      android.hardware.biometrics.fingerprint.IFingerprint/default \
      android.hardware.bluetooth.IBluetoothHci/default \
      android.hardware.camera.provider.ICameraProvider/internal/0 \
      android.hardware.gnss.IGnss/default \
      android.hardware.graphics.composer3.IComposer/default \
      android.hardware.health.IHealth/default \
      android.hardware.nfc.INfc/default \
      android.hardware.radio.config.IRadioConfig/default \
      android.hardware.sensors.ISensors/default \
      android.hardware.wifi.IWifi/default \
      audio bluetooth_manager media.camera phone sensorservice wifi; do
    printf '%s: [mock]\n' "$service"
  done
}

runtime_features() {
  local feature
  for feature in \
      android.hardware.bluetooth android.hardware.camera \
      android.hardware.camera.front android.hardware.fingerprint \
      android.hardware.location.gps android.hardware.nfc \
      android.hardware.sensor.accelerometer android.hardware.sensor.gyroscope \
      android.hardware.telephony android.hardware.wifi; do
    printf 'feature:%s\n' "$feature"
  done
}

if [[ ${1:-} == version && $# -eq 1 ]]; then
  printf '%s\n' \
    'Android Debug Bridge version 1.0.41' \
    'Version 37.0.1-mock'
  exit 0
fi

if [[ ${1:-} == devices && $# -eq 1 ]]; then
  printf 'List of devices attached\n'
  if [[ $(read_state mode bootloader) == android ]]; then
    printf '%s\tdevice\n' "$serial"
  fi
  exit 0
fi

[[ ${1:-} == -s && $# -ge 3 ]] || die "missing selected serial or command"
[[ $2 == "$serial" ]] || die "unexpected selected serial: $2"
shift 2
if [[ -n "${MOCK_ADB_COMMAND_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$MOCK_ADB_COMMAND_LOG"
fi

case ${1:-} in
  get-state)
    [[ $# -eq 1 && $(read_state mode bootloader) == android ]] || exit 1
    printf 'device\n'
    ;;
  shell)
    shift
    if [[ "$*" == '-T -x true' ]]; then
      case "$stock_shell_mode" in
        normal) : ;;
        tradein|closed)
          printf 'error: closed\n' >&2
          exit 1
          ;;
        *) die "unsupported MOCK_ADB_STOCK_SHELL_MODE: $stock_shell_mode" ;;
      esac
    elif [[ "$*" == 'tradeinmode getstatus' ]]; then
      [[ "$stock_shell_mode" == tradein ]] || exit 1
      printf '{"status":"foyer"}\n'
    elif [[ ${1:-} == getprop && $# -eq 2 ]]; then
      runtime_property "$2"
    elif [[ ${1:-} == lpdump && ${2:-} == -a && $# -eq 2 ]]; then
      printf '%s\n' 'Current slot: _a' 'Update state: none'
      for partition in \
          system system_dlkm system_ext product vendor vendor_dlkm; do
        printf '  Name: %s_a\n' "$partition"
        printf '  Extents:\n'
        printf '    0 .. 4095 linear super 2048\n'
      done
    elif [[ "$runtime_mode" != stock ]]; then
      case "$*" in
        true) ;;
        'id -u') printf '2000\n' ;;
        getenforce) printf 'Enforcing\n' ;;
        'cat /proc/uptime') printf '120.00 480.00\n' ;;
        'cat /proc/sys/kernel/random/boot_id')
          printf '01234567-89ab-cdef-0123-456789abcdef\n'
          ;;
        'cat /proc/mounts') runtime_mounts ;;
        'readlink /product')
          printf '%s\n' "${MOCK_ADB_PRODUCT_ALIAS_TARGET:-/system/product}"
          ;;
        'readlink /system_ext')
          printf '%s\n' \
            "${MOCK_ADB_SYSTEM_EXT_ALIAS_TARGET:-/system/system_ext}"
          ;;
        'readlink /dev/block/mapper/system_a') printf '/dev/block/dm-0\n' ;;
        'readlink /dev/block/mapper/system_dlkm_a') printf '/dev/block/dm-1\n' ;;
        'readlink /dev/block/mapper/system_ext_a') printf '/dev/block/dm-2\n' ;;
        'readlink /dev/block/mapper/product_a') printf '/dev/block/dm-3\n' ;;
        'readlink /dev/block/mapper/vendor_a') printf '/dev/block/dm-4\n' ;;
        'readlink /dev/block/mapper/vendor_dlkm_a') printf '/dev/block/dm-5\n' ;;
        'test -d /system/product'|'test -d /system/system_ext') ;;
        'test -e /dev/block/mapper/'*'_a-cow') ;;
        'test -r /vendor/etc/vintf/manifest.xml'|\
        'test -r /vendor/etc/vintf/compatibility_matrix.xml'|\
        'test -r /system/etc/vintf/manifest.xml') ;;
        'df -k /data')
          printf '%s\n' \
            'Filesystem 1K-blocks Used Available Use% Mounted on' \
            '/dev/block/dm-63 235018324 1048576 220065584 1% /data'
          ;;
        'ls /system/etc/vintf/compatibility_matrix*.xml')
          printf '/system/etc/vintf/compatibility_matrix.202604.xml\n'
          ;;
        'checkvintf --check-compat') printf 'COMPATIBLE\n' ;;
        'uname -m') printf 'aarch64\n' ;;
        'uname -r') printf '6.12.69-android16-mock\n' ;;
        'getconf PAGESIZE') printf '4096\n' ;;
        'service list') runtime_services ;;
        'pm list features') runtime_features ;;
        'pidof system_server') printf '1200\n' ;;
        'pidof surfaceflinger') printf '900\n' ;;
        'pidof audioserver') printf '901\n' ;;
        'pidof cameraserver') printf '902\n' ;;
        'wm size') printf 'Physical size: 1080x2424\n' ;;
        'wm density') printf 'Physical density: 420\n' ;;
        'dumpsys battery')
          printf '%s\n' '  status: 4' '  level: 100' '  temperature: 275'
          ;;
        *) die "unexpected runtime shell command: $*" ;;
      esac
    else
      die "unexpected shell command: $*"
    fi
    ;;
  reboot)
    [[ $# -eq 2 && $2 == bootloader ]] || die "unexpected reboot target"
    write_state mode bootloader
    printf 'reboot bootloader\n' >>"$log_file"
    ;;
  *)
    die "unexpected command: $*"
    ;;
esac
