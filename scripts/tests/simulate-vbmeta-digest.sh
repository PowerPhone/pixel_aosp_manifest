#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$script_dir/lib/common.sh"

require_command grep mkdir mktemp rm sed unzip wc zip

# Exercise the exact independent-validator implementation without rebuilding
# images. The mock avbtool also proves that the packaged graph is the input.
# shellcheck disable=SC1090
source <(
  sed -n \
    -e '/^require_zip_entry_once() {$/,/^}$/p' \
    -e '/^require_value() {$/,/^}$/p' \
    -e '/^validate_target_files_vbmeta_digest() {$/,/^}$/p' \
    "$script_dir/validate-images.sh"
)

test_parent="$project_root/work/vbmeta-digest-tests"
mkdir -p "$test_parent"
test_dir=$(mktemp -d "$test_parent/.mock.XXXXXX")
cleanup() {
  if [[ -n "${test_dir:-}" && -d "$test_dir" && \
        "$test_dir" == "$test_parent"/.mock.* ]]; then
    rm -rf -- "$test_dir"
  fi
}
trap cleanup EXIT

expect_failure() {
  local description=$1
  shift
  if ("$@" >"$test_dir/expected-failure.log" 2>&1); then
    die "$description unexpectedly passed"
  fi
}

expected_digest=cb1578c1790363f6b75f4f86464cb3630c9fe135110ed87c996a54f648a2c213
wrong_digest=0000000000000000000000000000000000000000000000000000000000000000
mock_digest=$expected_digest
bundle="$test_dir/bundle"
scratch_dir="$test_dir/scratch"
zip_root="$test_dir/zip-root"
mkdir -p "$bundle" "$scratch_dir" "$zip_root/META"
printf 'mock packaged root vbmeta\n' > "$bundle/vbmeta.img"

mock_avbtool() {
  [[ $# -eq 3 && $1 == calculate_vbmeta_digest && $2 == --image && \
     $3 == "$bundle/vbmeta.img" ]] || die "unexpected mock avbtool invocation"
  printf '%s\n' "$mock_digest"
}
# Referenced by the validator helper loaded dynamically above.
# shellcheck disable=SC2034
avbtool_command=(mock_avbtool)

make_target_files() {
  local name=$1
  local form=$2
  local archive="$test_dir/$name.zip"
  case "$form" in
    valid) printf '%s\n' "$expected_digest" > "$zip_root/META/vbmeta_digest.txt" ;;
    mismatch) printf '%s\n' "$wrong_digest" > "$zip_root/META/vbmeta_digest.txt" ;;
    uppercase) printf '%s\n' "${expected_digest^^}" > "$zip_root/META/vbmeta_digest.txt" ;;
    no-lf) printf '%s' "$expected_digest" > "$zip_root/META/vbmeta_digest.txt" ;;
    extra-lf) printf '%s\n\n' "$expected_digest" > "$zip_root/META/vbmeta_digest.txt" ;;
    *) die "unknown vbmeta digest fixture: $form" ;;
  esac
  (
    cd "$zip_root"
    zip -q "$archive" META/vbmeta_digest.txt
  )
  printf '%s\n' "$archive"
}

target_files=$(make_target_files valid valid)
validate_target_files_vbmeta_digest "$bundle"
for form in mismatch uppercase no-lf extra-lf; do
  target_files=$(make_target_files "$form" "$form")
  expect_failure "$form vbmeta digest metadata" \
    validate_target_files_vbmeta_digest "$bundle"
done

# Referenced by the validator helper loaded dynamically above.
# shellcheck disable=SC2034
target_files=$(make_target_files calculated-mismatch valid)
mock_digest=$wrong_digest
expect_failure "calculated vbmeta digest mismatch" \
  validate_target_files_vbmeta_digest "$bundle"

note "target-files vbmeta digest canonical-format and mismatch tests passed"
