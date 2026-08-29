#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../lib/cubs-sepolicy.sh disable=SC1091
source "$project_root/scripts/lib/cubs-sepolicy.sh"

require_command cmp grep mkdir mktemp rm sed sha256sum

scratch_parent="$project_root/work/sepolicy-sanitization-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

fixture=
expected=
pristine_sha256=
sanitized_sha256=

make_fixture() {
  local name=$1
  local suffix=$2
  fixture="$scratch_dir/$name.cil"
  expected="$scratch_dir/$name.expected.cil"
  printf '%s\n' \
    '(type unrelated_domain)' \
    "(allow vndservicemanager${suffix} base_adevtool_typeattr_59 (binder (transfer)))" \
    '(allow unrelated_domain self (process (fork)))' \
    '(typeattribute base_adevtool_typeattr_59)' \
    "(typeattributeset base_adevtool_typeattr_59 (and (domain) (not (coredomain init${suffix} vendor_init${suffix}))))" \
    '(roletype object_r unrelated_domain)' \
    >"$fixture"
  printf '%s\n' \
    '(type unrelated_domain)' \
    '(allow unrelated_domain self (process (fork)))' \
    '(roletype object_r unrelated_domain)' \
    >"$expected"
  pristine_sha256=$(sha256sum -- "$fixture")
  pristine_sha256=${pristine_sha256%% *}
  sanitized_sha256=$(sha256sum -- "$expected")
  sanitized_sha256=${sanitized_sha256%% *}
}

expect_failure() {
  local description=$1
  local expected_message=$2
  shift 2
  local log="$scratch_dir/${description//[^a-zA-Z0-9]/-}.log"
  if ("$@") >"$log" 2>&1; then
    die "$description unexpectedly passed"
  fi
  grep -Fq -- "$expected_message" "$log" || {
    sed -n '1,120p' "$log" >&2
    die "$description failed for an unexpected reason"
  }
}

make_fixture vendor _202604
sanitize_cubs_redundant_vndservicemanager_rule \
  "$fixture" "$pristine_sha256" "$sanitized_sha256" _202604 false
cmp --silent "$fixture" "$expected" || \
  die "normal cubs SELinux transform changed more than the exact duplicate"
sanitize_cubs_redundant_vndservicemanager_rule \
  "$fixture" "$pristine_sha256" "$sanitized_sha256" _202604 true

make_fixture recovery ''
sanitize_cubs_redundant_vndservicemanager_rule \
  "$fixture" "$pristine_sha256" "$sanitized_sha256" '' false
cmp --silent "$fixture" "$expected" || \
  die "recovery cubs SELinux transform changed more than the exact duplicate"

make_fixture unsanitized-check _202604
expect_failure unsanitized-check \
  'generated cubs vndservicemanager duplicate has not been removed' \
  sanitize_cubs_redundant_vndservicemanager_rule \
  "$fixture" "$pristine_sha256" "$sanitized_sha256" _202604 true

make_fixture partial _202604
sed -i '/^(allow vndservicemanager_202604 base_adevtool_typeattr_59 (binder (transfer)))$/d' \
  "$fixture"
expect_failure partial \
  'differs from both exact pristine and sanitized states' \
  sanitize_cubs_redundant_vndservicemanager_rule \
  "$fixture" "$pristine_sha256" "$sanitized_sha256" _202604 false

make_fixture extra-consumer _202604
printf '%s\n' \
  '(allow unrelated_domain base_adevtool_typeattr_59 (binder (call)))' \
  >>"$fixture"
extra_consumer_sha256=$(sha256sum -- "$fixture")
extra_consumer_sha256=${extra_consumer_sha256%% *}
expect_failure extra-consumer \
  'redundant cubs vndservicemanager attribute has unexpected consumers' \
  sanitize_cubs_redundant_vndservicemanager_rule \
  "$fixture" "$extra_consumer_sha256" "$sanitized_sha256" _202604 false

make_fixture tampered-post-state _202604
sanitize_cubs_redundant_vndservicemanager_rule \
  "$fixture" "$pristine_sha256" "$sanitized_sha256" _202604 false
printf '%s\n' '(allow unrelated_domain self (process (transition)))' >>"$fixture"
expect_failure tampered-post-state \
  'differs from both exact pristine and sanitized states' \
  sanitize_cubs_redundant_vndservicemanager_rule \
  "$fixture" "$pristine_sha256" "$sanitized_sha256" _202604 true

printf '%s\n' 'mocked cubs SELinux duplicate-rule sanitization passed'
