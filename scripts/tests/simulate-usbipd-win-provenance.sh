#!/usr/bin/bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/usbipd-win.sh disable=SC1091
source "$script_dir/../lib/usbipd-win.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_root=$(mktemp -d "${TMPDIR:-/tmp}/usbipd-provenance-test.XXXXXX")
cleanup() {
  if [[ -n "${test_root:-}" && -d "$test_root" && ! -L "$test_root" && \
        "$test_root" == "${TMPDIR:-/tmp}"/usbipd-provenance-test.* ]]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

mock_template="$test_root/mock-template.sh"
cat >"$mock_template" <<'EOF'
#!/usr/bin/bash
set -euo pipefail

if [[ -n "${MOCK_EXECUTION_SENTINEL:-}" ]]; then
  printf 'invoked\n' >"$MOCK_EXECUTION_SENTINEL"
fi

case "${1:-}" in
  --version)
    case "${MOCK_VERSION_MODE:-good}" in
      good)
        printf '%s\r\n' "$MOCK_EXPECTED_VERSION"
        ;;
      wrong)
        printf '0.0.0-wrong\r\n'
        ;;
      prefix)
        printf '%s\r\n' "${MOCK_EXPECTED_VERSION%%+*}"
        ;;
      suffix)
        printf '%s-extra\r\n' "$MOCK_EXPECTED_VERSION"
        ;;
      multiline)
        printf '%s\r\nunexpected second line\r\n' "$MOCK_EXPECTED_VERSION"
        ;;
      stderr)
        printf '%s\r\n' "$MOCK_EXPECTED_VERSION"
        printf 'unexpected warning\r\n' >&2
        ;;
      timeout)
        sleep 5
        printf '%s\r\n' "$MOCK_EXPECTED_VERSION"
        ;;
      self-modify)
        printf '%s\r\n' "$MOCK_EXPECTED_VERSION"
        printf '\n# version mutation\n' >>"$0"
        ;;
      self-modify-fail)
        printf '%s\r\n' "$MOCK_EXPECTED_VERSION"
        printf '\n# failing version mutation\n' >>"$0"
        exit 92
        ;;
      *)
        exit 97
        ;;
    esac
    ;;
  policy)
    [[ "${2:-}" == list ]] || exit 96
    case "${MOCK_POLICY_MODE:-good}" in
      good)
        printf 'Allow AutoBind 18d1:d001\r\n'
        ;;
      fail-secret)
        printf '%s\r\n' "${MOCK_POLICY_SECRET:?}"
        exit 95
        ;;
      self-modify)
        printf 'Allow AutoBind 18d1:d001\r\n'
        printf '\n# policy mutation\n' >>"$0"
        ;;
      self-modify-fail)
        printf '%s\r\n' "${MOCK_POLICY_SECRET:?}"
        printf '\n# failing policy mutation\n' >>"$0"
        exit 91
        ;;
      *)
        exit 94
        ;;
    esac
    ;;
  *)
    exit 93
    ;;
esac
EOF
chmod 0755 "$mock_template"

expected_version='5.3.0-54+Branch.master.Sha.aa3db8b82c4cb5071fd31bc54211606c70886912.aa3db8b82c4cb5071fd31bc54211606c70886912'
_cubs_usbipd_command_timeout_seconds=1

make_mock() {
  local destination=$1
  install -m 0755 "$mock_template" "$destination"
}

mock_identity() {
  local path=$1
  mock_size=$(stat -c '%s' -- "$path")
  mock_sha256=$(sha256sum -- "$path")
  mock_sha256=${mock_sha256%% *}
}

expect_version_failure() {
  local label=$1
  local mode=$2
  local mock="$test_root/$label.sh"
  local output status

  make_mock "$mock"
  mock_identity "$mock"
  set +e
  output=$(
    MOCK_EXPECTED_VERSION=$expected_version \
    MOCK_VERSION_MODE=$mode \
      cubs_verify_usbipd_win_executable \
        "$mock" "$mock_size" "$mock_sha256" "$expected_version" 2>&1
  )
  status=$?
  set -e
  (( status != 0 )) || fail "$label version output was accepted"
  [[ "$output" != *"$mock"* ]] || fail "$label leaked the candidate path"
}

good_mock="$test_root/good.sh"
make_mock "$good_mock"
mock_identity "$good_mock"
MOCK_EXPECTED_VERSION=$expected_version \
  cubs_verify_usbipd_win_executable \
    "$good_mock" "$mock_size" "$mock_sha256" "$expected_version"
policy_stderr="$test_root/good-policy.stderr"
policy_output=$(
  MOCK_EXPECTED_VERSION=$expected_version \
  MOCK_POLICY_MODE=good \
    cubs_usbipd_win_policy_list --stdout 2>"$policy_stderr"
)
[[ ! -s "$policy_stderr" ]] || \
  fail "successful policy inspection wrote unexpected diagnostics"
[[ "$policy_output" == 'Allow AutoBind 18d1:d001' ]] || \
  fail "successful policy inspection returned unexpected normalized output"
for rejected_output_name in PATH IFS RANDOM captured_output; do
  set +e
  rejected_output=$(
    cubs_usbipd_win_policy_list "$rejected_output_name" 2>&1
  )
  rejected_status=$?
  set -e
  (( rejected_status != 0 )) || \
    fail "caller-selected policy output variable was accepted"
  [[ "$rejected_output" != *"$good_mock"* ]] || \
    fail "fixed policy-output mode rejection leaked the candidate path"
done

# Candidate paths containing spaces must remain usable, while hostile PATH
# entries must not shadow any provenance primitive used by the helper.
space_dir="$test_root/Program Files/usbipd-win"
mkdir -p "$space_dir"
space_mock="$space_dir/usbipd.exe"
make_mock "$space_mock"
mock_identity "$space_mock"
shadow_dir="$test_root/path-shadow"
shadow_sentinel="$test_root/path-shadow-invoked"
mkdir "$shadow_dir"
for shadow_name in realpath stat sha256sum timeout tr od xxd; do
  shadow_tool="$shadow_dir/$shadow_name"
  {
    printf '#!/usr/bin/bash\n'
    printf 'printf invoked >%q\n' "$shadow_sentinel"
    printf 'exit 99\n'
  } >"$shadow_tool"
  chmod 0755 "$shadow_tool"
done
PATH=$shadow_dir \
MOCK_EXPECTED_VERSION=$expected_version \
  cubs_verify_usbipd_win_executable \
    "$space_mock" "$mock_size" "$mock_sha256" "$expected_version"
space_policy_output=$(
  PATH=$shadow_dir \
  MOCK_EXPECTED_VERSION=$expected_version \
  MOCK_POLICY_MODE=good \
    cubs_usbipd_win_policy_list --stdout
)
[[ "$space_policy_output" == 'Allow AutoBind 18d1:d001' && \
   ! -e "$shadow_sentinel" ]] || \
  fail "ambient PATH influenced usbipd-win provenance inspection"

wrong_hash_mock="$test_root/private-wrong-hash-path.sh"
wrong_hash_sentinel="$test_root/wrong-hash-invoked"
make_mock "$wrong_hash_mock"
mock_identity "$wrong_hash_mock"
set +e
wrong_hash_output=$(
  MOCK_EXECUTION_SENTINEL=$wrong_hash_sentinel \
  MOCK_EXPECTED_VERSION=$expected_version \
    cubs_verify_usbipd_win_executable \
      "$wrong_hash_mock" "$mock_size" \
      0000000000000000000000000000000000000000000000000000000000000000 \
      "$expected_version" 2>&1
)
wrong_hash_status=$?
set -e
(( wrong_hash_status != 0 )) || fail "wrong executable hash was accepted"
[[ ! -e "$wrong_hash_sentinel" ]] || \
  fail "wrong-hash executable ran before rejection"
[[ "$wrong_hash_output" != *"$wrong_hash_mock"* ]] || \
  fail "wrong-hash failure leaked the candidate path"

expect_version_failure wrong-version wrong
expect_version_failure prefix-version prefix
expect_version_failure suffix-version suffix
expect_version_failure multiline-version multiline
expect_version_failure stderr-version stderr
expect_version_failure timeout-version timeout
expect_version_failure self-modifying-version self-modify

failing_version_mutating_mock="$test_root/failing-version-mutating.sh"
make_mock "$failing_version_mutating_mock"
mock_identity "$failing_version_mutating_mock"
set +e
failing_version_mutation_output=$(
  MOCK_EXPECTED_VERSION=$expected_version \
  MOCK_VERSION_MODE=self-modify-fail \
    cubs_verify_usbipd_win_executable \
      "$failing_version_mutating_mock" "$mock_size" "$mock_sha256" \
      "$expected_version" 2>&1
)
failing_version_mutation_status=$?
set -e
(( failing_version_mutation_status != 0 )) || \
  fail "failing version-time executable self-modification was accepted"
[[ "$failing_version_mutation_output" == \
   *'changed during its version check'* ]] || \
  fail "failing version mutation was not re-hashed after execution"
[[ "$failing_version_mutation_output" != *"$failing_version_mutating_mock"* ]] || \
  fail "failing version mutation leaked the candidate path"

unsafe_target="$test_root/unsafe-target.sh"
make_mock "$unsafe_target"
mock_identity "$unsafe_target"
ln -s "$unsafe_target" "$test_root/unsafe-link.sh"
mkdir "$test_root/unsafe-directory"
mkfifo "$test_root/unsafe-fifo"
install -m 0644 "$mock_template" "$test_root/non-executable.sh"
for unsafe_path in \
  "$test_root/unsafe-link.sh" \
  "$test_root/unsafe-directory" \
  "$test_root/unsafe-fifo" \
  "$test_root/non-executable.sh"; do
  set +e
  unsafe_output=$(
    MOCK_EXPECTED_VERSION=$expected_version \
      cubs_verify_usbipd_win_executable \
        "$unsafe_path" "$mock_size" "$mock_sha256" "$expected_version" 2>&1
  )
  unsafe_status=$?
  set -e
  (( unsafe_status != 0 )) || fail "unsafe candidate type was accepted"
  [[ "$unsafe_output" != *"$unsafe_path"* ]] || \
    fail "unsafe candidate failure leaked its path"
done

policy_mutating_mock="$test_root/policy-mutating.sh"
make_mock "$policy_mutating_mock"
mock_identity "$policy_mutating_mock"
MOCK_EXPECTED_VERSION=$expected_version \
  cubs_verify_usbipd_win_executable \
    "$policy_mutating_mock" "$mock_size" "$mock_sha256" "$expected_version"
set +e
policy_mutation_output=$(
  MOCK_EXPECTED_VERSION=$expected_version \
  MOCK_POLICY_MODE=self-modify \
    cubs_usbipd_win_policy_list --stdout 2>&1
)
policy_mutation_status=$?
set -e
(( policy_mutation_status != 0 )) || \
  fail "policy-time executable self-modification was accepted"
[[ "$policy_mutation_output" != *"$policy_mutating_mock"* ]] || \
  fail "policy mutation failure leaked the candidate path"
[[ "$policy_mutation_output" != *'18d1:d001'* ]] || \
  fail "policy mutation failure leaked policy output"

policy_failing_mutating_mock="$test_root/policy-failing-mutating.sh"
policy_failing_mutation_secret='private-policy-output-before-mutation-failure'
make_mock "$policy_failing_mutating_mock"
mock_identity "$policy_failing_mutating_mock"
MOCK_EXPECTED_VERSION=$expected_version \
  cubs_verify_usbipd_win_executable \
    "$policy_failing_mutating_mock" "$mock_size" "$mock_sha256" \
    "$expected_version"
set +e
policy_failing_mutation_output=$(
  MOCK_EXPECTED_VERSION=$expected_version \
  MOCK_POLICY_MODE=self-modify-fail \
  MOCK_POLICY_SECRET=$policy_failing_mutation_secret \
    cubs_usbipd_win_policy_list --stdout 2>&1
)
policy_failing_mutation_status=$?
set -e
(( policy_failing_mutation_status != 0 )) || \
  fail "failing policy-time executable self-modification was accepted"
[[ "$policy_failing_mutation_output" == \
   *'changed during policy inspection'* ]] || \
  fail "failing policy mutation was not re-hashed after execution"
[[ "$policy_failing_mutation_output" != *"$policy_failing_mutating_mock"* ]] || \
  fail "failing policy mutation leaked the candidate path"
[[ "$policy_failing_mutation_output" != *"$policy_failing_mutation_secret"* ]] || \
  fail "failing policy mutation leaked policy output"

policy_failure_mock="$test_root/policy-failure-private-path.sh"
policy_secret='private-policy-hardware-identifier'
make_mock "$policy_failure_mock"
mock_identity "$policy_failure_mock"
MOCK_EXPECTED_VERSION=$expected_version \
  cubs_verify_usbipd_win_executable \
    "$policy_failure_mock" "$mock_size" "$mock_sha256" "$expected_version"
set +e
policy_failure_output=$(
  MOCK_EXPECTED_VERSION=$expected_version \
  MOCK_POLICY_MODE=fail-secret \
  MOCK_POLICY_SECRET=$policy_secret \
    cubs_usbipd_win_policy_list --stdout 2>&1
)
policy_failure_status=$?
set -e
(( policy_failure_status != 0 )) || fail "failed policy command was accepted"
[[ "$policy_failure_output" != *"$policy_failure_mock"* ]] || \
  fail "failed policy command leaked the candidate path"
[[ "$policy_failure_output" != *"$policy_secret"* ]] || \
  fail "failed policy command leaked policy output"

printf 'usbipd-win provenance simulation passed\n'
