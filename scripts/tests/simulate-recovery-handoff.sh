#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd -- "$test_dir/../.." && pwd)
scratch_parent="$project_root/work/recovery-handoff-tests"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.simulate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.simulate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

export CUBS_RECOVERY_STATE_DIR="$scratch_dir/recovery"
# shellcheck source=../lib/common.sh disable=SC1091
source "$project_root/scripts/lib/common.sh"
# shellcheck source=../lib/recovery-handoff.sh disable=SC1091
source "$project_root/scripts/lib/recovery-handoff.sh"

fastboot_value() {
  case "$1" in
    partition-size:*_b) printf '0x04000000\n' ;;
    *) printf '\n' ;;
  esac
}

cubs_lock_recovery_state
anchor_id=0123456789abcdef0123456789abcdef
mock_serial=MOCK_CUBS_SERIAL
serial_binding=$(cubs_serial_binding "$anchor_id" "$mock_serial")
physical_sha=$(cubs_physical_b_sizes_sha256)
cubs_write_lineage_and_handoff "$anchor_id" "$serial_binding" "$physical_sha" \
  spacecraft-17.4-15938155 a900a-MP_260716-260716-M-15880348

[[ $(stat -c '%a' "$cubs_recovery_state_dir") == 700 && \
   $(stat -c '%a' "$cubs_recovery_lineage") == 600 && \
   $(stat -c '%a' "$cubs_recovery_handoff") == 600 ]] || {
  printf 'error: generated recovery state is not private\n' >&2
  exit 1
}
if grep -R -Fq -- "$mock_serial" "$cubs_recovery_state_dir"; then
  printf 'error: recovery state persisted the raw USB serial\n' >&2
  exit 1
fi
grep -Fxq 'state=ready' "$cubs_recovery_handoff"
grep -Fxq 'handoff_kind=stock_b_anchor' "$cubs_recovery_handoff"
if (cubs_verify_stale_ready_handoff "$mock_serial" "$physical_sha" \
    spacecraft-17.4-15938155 \
    a900a-MP_260716-260716-M-15880348 >/dev/null 2>&1); then
  printf 'error: a fresh recovery handoff was accepted for reissue\n' >&2
  exit 1
fi

rm -f -- "$cubs_recovery_handoff"
cubs_verify_lifeboat_lineage "$mock_serial" "$physical_sha" \
  spacecraft-17.4-15938155 a900a-MP_260716-260716-M-15880348
cubs_write_lifeboat_handoff "$physical_sha"
grep -Fxq 'handoff_kind=physical_b_lifeboat' "$cubs_recovery_handoff"

stale_created=$(( $(date +%s) - CUBS_RECOVERY_HANDOFF_READY_SECONDS - 1 ))
stale_expires=$((stale_created + CUBS_RECOVERY_HANDOFF_READY_SECONDS))
sed -i \
  -e "s/^created_epoch=.*/created_epoch=$stale_created/" \
  -e "s/^expires_epoch=.*/expires_epoch=$stale_expires/" \
  "$cubs_recovery_handoff"
stale_sha=$(sha256sum "$cubs_recovery_handoff" | awk '{print $1}')
cubs_verify_stale_ready_handoff "$mock_serial" "$physical_sha" \
  spacecraft-17.4-15938155 a900a-MP_260716-260716-M-15880348
# Simulate a host failure after the stale evidence archive was atomically
# published but before the active handoff was replaced. Reissue must validate
# and reuse the exact archive while keeping the stale active file continuously
# available until its one-step replacement.
mkdir -m 0700 "$cubs_recovery_state_dir/retired"
prepublished_archive="$cubs_recovery_state_dir/retired/${anchor_id}-${stale_created}-${stale_sha:0:16}.ready"
cp -- "$cubs_recovery_handoff" "$prepublished_archive"
chmod 0600 "$prepublished_archive"
cubs_reissue_verified_stale_handoff "$physical_sha"

mapfile -t retired_handoffs < <(
  find "$cubs_recovery_state_dir/retired" -maxdepth 1 -type f -name '*.ready' -print
)
(( ${#retired_handoffs[@]} == 1 )) || {
  printf 'error: stale handoff was not archived exactly once\n' >&2
  exit 1
}
[[ $(sha256sum "${retired_handoffs[0]}" | awk '{print $1}') == "$stale_sha" && \
   $(stat -c '%a' "${retired_handoffs[0]}") == 600 && \
   $(stat -c '%a' "$cubs_recovery_state_dir/retired") == 700 ]] || {
  printf 'error: retired stale handoff evidence was not preserved privately\n' >&2
  exit 1
}
grep -Fxq 'state=ready' "$cubs_recovery_handoff"
grep -Fxq 'claimed_epoch=0' "$cubs_recovery_handoff"
grep -Fxq 'bundle_kind=none' "$cubs_recovery_handoff"
grep -Fxq 'bundle_manifest_sha256=none' "$cubs_recovery_handoff"
fresh_created=$(sed -n 's/^created_epoch=//p' "$cubs_recovery_handoff")
fresh_expires=$(sed -n 's/^expires_epoch=//p' "$cubs_recovery_handoff")
(( fresh_created > stale_expires && \
   fresh_expires == fresh_created + CUBS_RECOVERY_HANDOFF_READY_SECONDS )) || {
  printf 'error: reissued handoff freshness interval is invalid\n' >&2
  exit 1
}

# Even after its resume window ages out, a claimed receipt remains evidence of
# a possibly incomplete flash and must never enter the ready-reissue path.
claimed_created=$(( $(date +%s) - CUBS_RECOVERY_HANDOFF_RESUME_SECONDS - 1 ))
claimed_expires=$((claimed_created + CUBS_RECOVERY_HANDOFF_READY_SECONDS))
sed -i \
  -e 's/^state=ready$/state=claimed/' \
  -e "s/^created_epoch=.*/created_epoch=$claimed_created/" \
  -e "s/^expires_epoch=.*/expires_epoch=$claimed_expires/" \
  -e "s/^claimed_epoch=.*/claimed_epoch=$claimed_expires/" \
  -e 's/^bundle_kind=none$/bundle_kind=cubs/' \
  -e 's/^bundle_manifest_sha256=none$/bundle_manifest_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "$cubs_recovery_handoff"
if (cubs_verify_stale_ready_handoff "$mock_serial" "$physical_sha" \
    spacecraft-17.4-15938155 \
    a900a-MP_260716-260716-M-15880348 >/dev/null 2>&1); then
  printf 'error: a claimed recovery handoff was accepted for reissue\n' >&2
  exit 1
fi

cubs_invalidate_recovery_handoff
[[ ! -e "$cubs_recovery_handoff" && ! -e "$cubs_recovery_lineage" ]] || {
  printf 'error: recovery-state invalidation left active evidence\n' >&2
  exit 1
}

[[ -f "${retired_handoffs[0]}" ]] || {
  printf 'error: lineage invalidation deleted retired handoff evidence\n' >&2
  exit 1
}

printf 'mocked private recovery lineage, stale reissue, and handoff lifecycle passed\n'
