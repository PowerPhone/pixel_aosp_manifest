#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
mock_adb="$test_dir/mock-adb.sh"
mock_adb_sha256=$(sha256sum "$mock_adb" | awk '{print $1}')
scratch_parent="$project_root/work/runtime-validation-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
test_runner=$(mktemp "$project_root/scripts/.validate-runtime-test.XXXXXX")
declare -a reports=()

cleanup() {
  local report
  for report in "${reports[@]}"; do
    if [[ "$report" == "$project_root"/logs/runtime-validation-*.txt ]]; then
      rm -f -- "$report"
    fi
  done
  if [[ "$test_runner" == "$project_root/scripts/".validate-runtime-test.* ]]; then
    rm -f -- "$test_runner"
  fi
  if [[ "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

sed \
  -e "s/^expected_adb_sha256=\$PLATFORM_TOOLS_ADB_SHA256$/expected_adb_sha256=$mock_adb_sha256/" \
  "$project_root/scripts/validate-runtime.sh" >"$test_runner"
chmod 0755 "$test_runner"
grep -Fxq "expected_adb_sha256=$mock_adb_sha256" "$test_runner" || {
  printf 'error: failed to create digest-pinned runtime test runner\n' >&2
  exit 1
}

mkdir -p "$scratch_dir/state"
printf 'android\n' >"$scratch_dir/state/mode"
: >"$scratch_dir/adb.log"

run_case() {
  local name=$1 mode=$2 expected_status=$3 expected_pattern=$4
  local output report_relative report status
  shift 4

  if output=$(env \
      MOCK_FASTBOOT_STATE_DIR="$scratch_dir/state" \
      MOCK_ADB_LOG="$scratch_dir/adb.log" \
      MOCK_ADB_SERIAL=MOCK_CUBS_SERIAL \
      MOCK_ADB_RUNTIME_MODE="$mode" \
      ADB="$mock_adb" \
      CUBS_ADB_SERIAL=MOCK_CUBS_SERIAL \
      "$@" \
      "$test_runner" "$mode" 2>&1); then
    status=0
  else
    status=$?
  fi
  if (( status != expected_status )); then
    printf 'error: runtime case %s exited %d, expected %d\n%s\n' \
      "$name" "$status" "$expected_status" "$output" >&2
    exit 1
  fi
  grep -Fq "$expected_pattern" <<<"$output" || {
    printf 'error: runtime case %s lacks expected output: %s\n%s\n' \
      "$name" "$expected_pattern" "$output" >&2
    exit 1
  }
  report_relative=$(sed -n 's/^report: //p' <<<"$output" | tail -n 1)
  [[ "$report_relative" =~ ^logs/runtime-validation-(gsi|cubs)- ]] || {
    printf 'error: runtime case %s did not publish a safe report path\n' \
      "$name" >&2
    exit 1
  }
  report="$project_root/$report_relative"
  [[ -f "$report" && ! -L "$report" ]] || {
    printf 'error: runtime case %s report is unavailable\n' "$name" >&2
    exit 1
  }
  reports+=("$report")
}

run_case gsi-pass gsi 0 'runtime validation PASS_WITH_WARNINGS'
gsi_report=${reports[-1]}
grep -Fq 'PASS gsi product device: generic_arm64' "$gsi_report"
grep -Fq 'PASS gsi ADB authentication mode: 0' "$gsi_report"
grep -Fq 'PASS product build ID: CP2A.260605.016' "$gsi_report"
grep -Fq 'PASS system_ext build ID: CP2A.260605.016' "$gsi_report"
grep -Fq 'PASS product GSI alias target: /system/product' "$gsi_report"
grep -Fq 'PASS system_ext GSI alias target: /system/system_ext' "$gsi_report"
grep -Fq 'PASS product is embedded in the GSI root rather than separately mounted' \
  "$gsi_report"

run_case cubs-pass cubs 0 'runtime validation PASS_WITH_WARNINGS'
cubs_report=${reports[-1]}
grep -Fq 'PASS cubs product device: cubs' "$cubs_report"
grep -Fq 'PASS cubs ADB authentication mode: <unset> (effective unauthenticated)' \
  "$cubs_report"
grep -Fq 'PASS product build ID: CD1A.260714.001.A9' "$cubs_report"
grep -Fq 'PASS product mapper source: /dev/block/dm-3' "$cubs_report"

run_case gsi-device-mismatch gsi 1 \
  'FAIL gsi product device: expected generic_arm64, found cubs' \
  MOCK_ADB_OVERRIDE_PROPERTY=ro.product.device \
  MOCK_ADB_OVERRIDE_VALUE=cubs
run_case gsi-adb-auth-mismatch gsi 1 \
  'FAIL gsi ADB authentication mode: expected 0, found 1' \
  MOCK_ADB_OVERRIDE_PROPERTY=ro.adb.secure \
  MOCK_ADB_OVERRIDE_VALUE=1
run_case gsi-product-identity-mismatch gsi 1 \
  'FAIL product build ID: expected CP2A.260605.016, found CD1A.260714.001.A9' \
  MOCK_ADB_OVERRIDE_PROPERTY=ro.product.build.id \
  MOCK_ADB_OVERRIDE_VALUE=CD1A.260714.001.A9
run_case gsi-system-ext-identity-mismatch gsi 1 \
  'FAIL system_ext build ID: expected CP2A.260605.016, found CD1A.260714.001.A9' \
  MOCK_ADB_OVERRIDE_PROPERTY=ro.system_ext.build.id \
  MOCK_ADB_OVERRIDE_VALUE=CD1A.260714.001.A9
run_case gsi-product-mount-mismatch gsi 1 \
  'FAIL product unexpectedly has a separate GSI mount' \
  MOCK_ADB_GSI_SEPARATE_PRODUCT=1
run_case gsi-product-alias-mismatch gsi 1 \
  'FAIL product GSI alias target: expected /system/product, found /wrong/product' \
  MOCK_ADB_PRODUCT_ALIAS_TARGET=/wrong/product
run_case gsi-system-ext-alias-mismatch gsi 1 \
  'FAIL system_ext GSI alias target: expected /system/system_ext, found /wrong/system_ext' \
  MOCK_ADB_SYSTEM_EXT_ALIAS_TARGET=/wrong/system_ext
run_case cubs-device-mismatch cubs 1 \
  'FAIL cubs product device: expected cubs, found generic_arm64' \
  MOCK_ADB_OVERRIDE_PROPERTY=ro.product.device \
  MOCK_ADB_OVERRIDE_VALUE=generic_arm64
run_case cubs-adb-auth-mismatch cubs 1 \
  'FAIL cubs ADB authentication mode: expected unset-or-0, found 1' \
  MOCK_ADB_OVERRIDE_PROPERTY=ro.adb.secure \
  MOCK_ADB_OVERRIDE_VALUE=1

printf 'runtime mode, identity, ADB-security, and mount simulations passed\n'
