#!/usr/bin/env bash

# Exact host-side provenance checks for the Windows usbipd-win executable.
# This file is sourced by callers. The executable path is untrusted location
# input; callers must supply the reviewed size, SHA-256, and version string.

_cubs_usbipd_command_timeout_seconds=20
_cubs_usbipd_verified_path=
_cubs_usbipd_verified_size=
_cubs_usbipd_verified_sha256=
_cubs_usbipd_verified_version=

_cubs_usbipd_clear_verified() {
  _cubs_usbipd_verified_path=
  _cubs_usbipd_verified_size=
  _cubs_usbipd_verified_sha256=
  _cubs_usbipd_verified_version=
}

_cubs_usbipd_sha256() {
  local path=$1
  local digest

  digest=$(/usr/bin/sha256sum -- "$path" 2>/dev/null) || return 1
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

_cubs_usbipd_file_matches() {
  local path=$1
  local expected_size=$2
  local expected_sha256=$3
  local actual_size actual_sha256

  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || return 1
  actual_size=$(/usr/bin/stat -c '%s' -- "$path" 2>/dev/null) || return 1
  [[ "$actual_size" == "$expected_size" ]] || return 1
  actual_sha256=$(_cubs_usbipd_sha256 "$path") || return 1
  [[ "$actual_sha256" == "$expected_sha256" ]]
}

_cubs_usbipd_expected_version_hex() {
  local expected_version=$1

  printf '%s\n' "$expected_version" | \
    /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n'
}

_cubs_usbipd_observed_version_record() {
  local path=$1
  local observed_hex observed_status

  # Encode the complete stdout/stderr byte stream before putting it in a shell
  # variable. This preserves trailing and embedded newlines and rejects NULs or
  # other unexpected bytes. CR is the sole normalization for Windows output.
  if observed_hex=$(
    set -o pipefail
    /usr/bin/timeout "$_cubs_usbipd_command_timeout_seconds" \
      "$path" --version 2>&1 | \
      /usr/bin/tr -d '\r' | \
      /usr/bin/od -An -v -tx1 | \
      /usr/bin/tr -d ' \n'
  ); then
    observed_status=0
  else
    observed_status=$?
  fi
  printf '%s:%s\n' "$observed_status" "$observed_hex"
}

cubs_verify_usbipd_win_executable() {
  local candidate=$1
  local expected_size=$2
  local expected_sha256=$3
  local expected_version=$4
  local canonical_path expected_hex observed_hex observed_record observed_status

  _cubs_usbipd_clear_verified

  [[ "$expected_size" =~ ^[1-9][0-9]{0,18}$ ]] || \
    die "invalid expected usbipd-win executable size"
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die "invalid expected usbipd-win executable SHA-256"
  [[ -n "$expected_version" && \
     "$expected_version" != *$'\r'* && \
     "$expected_version" != *$'\n'* ]] || \
    die "invalid expected usbipd-win version"
  [[ "$candidate" == /* && -f "$candidate" && ! -L "$candidate" && \
     -x "$candidate" ]] || \
    die "usbipd-win candidate is not a safe regular executable"

  canonical_path=$(/usr/bin/realpath -e -- "$candidate" 2>/dev/null) || \
    die "unable to canonicalize usbipd-win candidate"
  [[ "$canonical_path" == /* && -f "$canonical_path" && \
     ! -L "$canonical_path" && -x "$canonical_path" ]] || \
    die "canonical usbipd-win candidate is not a safe regular executable"
  _cubs_usbipd_file_matches \
    "$canonical_path" "$expected_size" "$expected_sha256" || \
    die "usbipd-win executable does not match its pinned payload"

  expected_hex=$(_cubs_usbipd_expected_version_hex "$expected_version") || \
    die "unable to encode expected usbipd-win version"
  observed_record=$(_cubs_usbipd_observed_version_record "$canonical_path") || \
    die "unable to inspect usbipd-win version"
  observed_status=${observed_record%%:*}
  observed_hex=${observed_record#*:}

  # Re-hash immediately after executing the candidate. A location selected by
  # USBIPD_EXE is never authority for its bytes, and self-modification or a
  # replacement during the version probe invalidates the verified state.
  _cubs_usbipd_file_matches \
    "$canonical_path" "$expected_size" "$expected_sha256" || \
    die "usbipd-win executable changed during its version check"
  [[ "$observed_status" == 0 ]] || \
    die "usbipd-win version command failed"
  [[ "$observed_hex" == "$expected_hex" ]] || \
    die "usbipd-win version output does not match its pinned identity"

  _cubs_usbipd_verified_path=$canonical_path
  _cubs_usbipd_verified_size=$expected_size
  _cubs_usbipd_verified_sha256=$expected_sha256
  _cubs_usbipd_verified_version=$expected_version
}

cubs_usbipd_win_policy_list() {
  local output_mode=${1:-}
  local byte captured_hex policy_record policy_status
  local index

  (( $# == 1 )) && [[ "$output_mode" == --stdout ]] || \
    die "usbipd-win policy inspection requires its fixed --stdout mode"
  [[ -n "$_cubs_usbipd_verified_path" && \
     "$_cubs_usbipd_verified_size" =~ ^[1-9][0-9]{0,18}$ && \
     "$_cubs_usbipd_verified_sha256" =~ ^[0-9a-f]{64}$ && \
     -n "$_cubs_usbipd_verified_version" ]] || \
    die "usbipd-win executable has not been verified"

  # Re-check immediately before use so a previously verified path cannot be
  # replaced between the version and policy operations.
  _cubs_usbipd_file_matches \
    "$_cubs_usbipd_verified_path" \
    "$_cubs_usbipd_verified_size" \
    "$_cubs_usbipd_verified_sha256" || \
    die "verified usbipd-win executable changed before policy inspection"

  # Preserve the complete stdout/stderr record as hexadecimal until the
  # command status and the post-use executable hash have both passed. This
  # prevents Bash command substitution from silently dropping NUL bytes and
  # keeps identifying policy output out of every failure path.
  if captured_hex=$(
    set -o pipefail
    /usr/bin/timeout "$_cubs_usbipd_command_timeout_seconds" \
      "$_cubs_usbipd_verified_path" policy list 2>&1 | \
      /usr/bin/tr -d '\r' | \
      /usr/bin/od -An -v -tx1 | \
      /usr/bin/tr -d ' \n'
  ); then
    policy_status=0
  else
    policy_status=$?
  fi

  # Do not release potentially identifying policy output until the executable
  # is proved unchanged after use.
  _cubs_usbipd_file_matches \
    "$_cubs_usbipd_verified_path" \
    "$_cubs_usbipd_verified_size" \
    "$_cubs_usbipd_verified_sha256" || \
    die "usbipd-win executable changed during policy inspection"
  [[ "$policy_status" == 0 ]] || \
    die "usbipd-win policy inspection failed"
  [[ -n "$captured_hex" && "$captured_hex" =~ ^([0-9a-f]{2})+$ ]] || \
    die "usbipd-win policy output is empty or malformed"
  for ((index = 0; index < ${#captured_hex}; index += 2)); do
    byte=${captured_hex:index:2}
    case "$byte" in
      09|0a|2[0-9a-f]|[3-6][0-9a-f]|7[0-9a-e]) ;;
      *) die "usbipd-win policy output contains a forbidden control byte" ;;
    esac
  done
  policy_record=$(printf '%s' "$captured_hex" | /usr/bin/xxd -r -p) || \
    die "unable to decode usbipd-win policy output"
  printf '%s\n' "$policy_record"
}
