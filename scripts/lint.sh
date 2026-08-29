#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"

bash -n config/cubs-dexpreopt.env scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh
shellcheck -x scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh
scripts/tests/simulate-cubs-fstab-avb-mapping.sh
scripts/tests/simulate-usbipd-win-provenance.sh
while IFS= read -r script; do
  if head -n 1 "$script" | grep -q '^#!' && [[ ! -x "$script" ]]; then
    printf 'error: directly executable script lacks executable mode: %s\n' \
      "$script" >&2
    exit 1
  fi
done < <(
  find scripts -type f -name '*.sh' ! -path 'scripts/lib/*' -print | \
    LC_ALL=C sort
)
xmllint --noout manifests/*.xml
base_revision_lock=patches/BASE_REVISIONS
[[ -f "$base_revision_lock" ]] || {
  printf 'error: missing %s\n' "$base_revision_lock" >&2
  exit 1
}
mapfile -t patch_base_lines < <(
  awk '!/^#/ && NF {print}' "$base_revision_lock"
)
(( ${#patch_base_lines[@]} > 0 )) || {
  printf 'error: empty patch-base revision lock\n' >&2
  exit 1
}
declare -A seen_patch_bases=()
for patch_base_line in "${patch_base_lines[@]}"; do
  read -r patch_project patch_revision extra <<<"$patch_base_line"
  [[ -n "$patch_project" && "$patch_revision" =~ ^[0-9a-f]{40}$ && \
     -z "${extra:-}" && -z "${seen_patch_bases[$patch_project]+present}" ]] || {
    printf 'error: malformed or duplicate patch-base entry: %s\n' \
      "$patch_base_line" >&2
    exit 1
  }
  seen_patch_bases["$patch_project"]=1
  manifest_revision=$(xmllint --xpath \
    "string(/manifest/project[@path='$patch_project']/@revision)" \
    manifests/resolved.xml)
  [[ "$manifest_revision" == "$patch_revision" ]] || {
    printf 'error: patch base for %s is %s, resolved source is %s\n' \
      "$patch_project" "$patch_revision" "${manifest_revision:-missing}" >&2
    exit 1
  }
done
(
  cd patches
  sha256sum --check SHA256SUMS
)

mapfile -t recorded_patch_files < <(
  awk 'NF == 2 {sub(/^\*/, "", $2); print $2}' patches/SHA256SUMS | LC_ALL=C sort
)
mapfile -t actual_patch_files < <(
  find patches -type f -name '*.patch' -printf '%P\n' | LC_ALL=C sort
)
[[ "${recorded_patch_files[*]}" == "${actual_patch_files[*]}" ]] || {
  printf 'error: patch files differ from patches/SHA256SUMS\n' >&2
  printf 'recorded: %s\n' "${recorded_patch_files[*]}" >&2
  printf 'actual:   %s\n' "${actual_patch_files[*]}" >&2
  exit 1
}
git diff --check

# The bundle runner is standalone, so its safety pins are literal. Keep those
# literals locked to the project configuration that creates private handoffs.
# shellcheck source=../config/release.env disable=SC1091
source config/release.env
# shellcheck source=../config/recovery.env disable=SC1091
source config/recovery.env

expected_usbipd_msi_filename="usbipd-win_${CUBS_USBIPD_WIN_VERSION}_x64.msi"
expected_usbipd_msi_url="https://github.com/dorssel/usbipd-win/releases/download/v${CUBS_USBIPD_WIN_VERSION}/${expected_usbipd_msi_filename}"
expected_usbipd_version_output="${CUBS_USBIPD_WIN_VERSION}-54+Branch.master.Sha.${CUBS_USBIPD_WIN_RELEASE_REVISION}.${CUBS_USBIPD_WIN_RELEASE_REVISION}"
[[ "$CUBS_USBIPD_WIN_VERSION" == 5.3.0 && \
   "$CUBS_USBIPD_WIN_RELEASE_REVISION" == \
     aa3db8b82c4cb5071fd31bc54211606c70886912 && \
   "$CUBS_USBIPD_WIN_VERSION_OUTPUT" == "$expected_usbipd_version_output" && \
   "$CUBS_USBIPD_WIN_X64_MSI_FILENAME" == \
     "$expected_usbipd_msi_filename" && \
   "$CUBS_USBIPD_WIN_X64_MSI_URL" == "$expected_usbipd_msi_url" && \
   "$CUBS_USBIPD_WIN_X64_MSI_SHA256" == \
     1c984914aec944de19b64eff232421439629699f8138e3ddc29301175bc6d938 && \
   "$CUBS_USBIPD_WIN_EXE_SIZE" == 8803720 && \
   "$CUBS_USBIPD_WIN_EXE_SHA256" == \
     78fd94ca4125db7407c77bd7b985971a1ac95705a331401976f748770035325b ]] || {
  printf 'error: usbipd-win release or installed-payload pins are inconsistent\n' \
    >&2
  exit 1
}
[[ "$CUBS_USBIPD_WIN_X64_MSI_SHA256" =~ ^[0-9a-f]{64}$ && \
   "$CUBS_USBIPD_WIN_EXE_SHA256" =~ ^[0-9a-f]{64}$ && \
   "$CUBS_USBIPD_WIN_X64_MSI_SHA256" != "$CUBS_USBIPD_WIN_EXE_SHA256" ]] || {
  printf 'error: malformed usbipd-win payload identity\n' >&2
  exit 1
}

usbipd_anchor_script=scripts/prepare-recovery-anchor.sh
usbipd_policy_body=$(sed -n \
  '/^check_recovery_usb_policy() {$/,/^}$/p' "$usbipd_anchor_script")
# The quoted dollar expressions below are intentional literal source fragments.
# shellcheck disable=SC2016
[[ $(grep -Fxc 'source "$script_dir/lib/usbipd-win.sh"' \
       "$usbipd_anchor_script") -eq 1 && \
   $(grep -Fc 'cubs_verify_usbipd_win_executable' \
       <<<"$usbipd_policy_body") -eq 1 && \
   $(grep -Fc 'cubs_usbipd_win_policy_list --stdout' \
       <<<"$usbipd_policy_body") -eq 1 && \
   $(grep -Foc '$usbipd_exe' <<<"$usbipd_policy_body") -eq 1 && \
   "$usbipd_policy_body" != *'"$usbipd_exe" policy'* && \
   "$usbipd_policy_body" != *'"$usbipd_exe" --version'* ]] || {
  printf 'error: recovery usbipd-win provenance integration regressed\n' >&2
  exit 1
}
for usbipd_doc in README.md docs/recovery-anchor.md; do
  for usbipd_documented_pin in \
    "$CUBS_USBIPD_WIN_X64_MSI_FILENAME" \
    "$CUBS_USBIPD_WIN_X64_MSI_URL" \
    "$CUBS_USBIPD_WIN_X64_MSI_SHA256" \
    "$CUBS_USBIPD_WIN_EXE_SIZE" \
    "$CUBS_USBIPD_WIN_EXE_SHA256" \
    "$CUBS_USBIPD_WIN_VERSION_OUTPUT"; do
    grep -Fq -- "$usbipd_documented_pin" "$usbipd_doc" || {
      printf 'error: %s omits a configured usbipd-win pin\n' \
        "$usbipd_doc" >&2
      exit 1
    }
  done
done
if ! grep -Fq 'GPL-3.0-only' THIRD_PARTY_NOTICES.md || \
   ! grep -Fq \
     'https://github.com/dorssel/usbipd-win/blob/v5.3.0/COPYING.md' \
     THIRD_PARTY_NOTICES.md; then
  printf 'error: usbipd-win upstream license notice is incomplete\n' >&2
  exit 1
fi

runner_fastboot_sha=$(sed -n 's/^expected_fastboot_sha256=//p' scripts/flash-a.sh)
runner_policy_sha=$(sed -n 's/^expected_recovery_policy_sha256=//p' scripts/flash-a.sh)
restore_fastboot_sha=$(sed -n 's/^expected_fastboot_sha256=//p' scripts/restore-stock.sh)
restore_fastboot_version=$(sed -n 's/^expected_fastboot_version=//p' scripts/restore-stock.sh)
derived_policy_sha=$(printf '%s' "$CUBS_RECOVERY_POLICY_ID" | sha256sum | awk '{print $1}')
derived_preparation_policy_sha=$(printf '%s' \
  "$CUBS_STOCK_B_PREPARATION_POLICY_ID" | sha256sum | awk '{print $1}')
[[ "$CUBS_FINALIZED_STOCK_RESTORE_ADOPTED_RUNTIME_ATTESTATION_SHA256" =~ \
     ^(none|[0-9a-f]{64})$ ]] || {
  printf 'error: finalized stock-restore adopted-runtime pin is malformed\n' >&2
  exit 1
}
[[ "$runner_fastboot_sha" == "$PLATFORM_TOOLS_FASTBOOT_SHA256" ]] || {
  printf 'error: standalone runner fastboot digest differs from recovery.env\n' >&2
  exit 1
}
[[ "$restore_fastboot_sha" == "$PLATFORM_TOOLS_FASTBOOT_SHA256" && \
   "$restore_fastboot_version" == "$PLATFORM_TOOLS_VERSION" ]] || {
  printf 'error: stock restore fastboot pins differ from project configuration\n' >&2
  exit 1
}
[[ "$runner_policy_sha" == "$CUBS_RECOVERY_POLICY_SHA256" ]] || {
  printf 'error: standalone runner recovery policy differs from recovery.env\n' >&2
  exit 1
}
[[ "$derived_policy_sha" == "$CUBS_RECOVERY_POLICY_SHA256" ]] || {
  printf 'error: recovery policy ID does not match its recorded digest\n' >&2
  exit 1
}
[[ "$derived_preparation_policy_sha" == \
   "$CUBS_STOCK_B_PREPARATION_POLICY_SHA256" ]] || {
  printf 'error: stock-B preparation policy ID does not match its recorded digest\n' >&2
  exit 1
}
for direct_pin in \
  "expected_physical_b_source_manifest_sha256:$CUBS_STOCK_B_SOURCE_PAYLOAD_MANIFEST_SHA256" \
  "expected_physical_b_vendor_boot_fetch_sha256:$CUBS_STOCK_VENDOR_BOOT_SHA256"; do
  direct_name=${direct_pin%%:*}
  direct_configured=${direct_pin#*:}
  direct_runner=$(sed -n "s/^${direct_name}=//p" scripts/flash-a.sh)
  [[ "$direct_runner" == "$direct_configured" ]] || {
    printf 'error: standalone runner direct-lifeboat pin differs: %s\n' \
      "$direct_name" >&2
    exit 1
  }
done
for runner_pin in \
  "expected_factory_sha256:$FACTORY_IMAGE_SHA256" \
  "expected_full_ota_sha256:$FULL_OTA_SHA256" \
  "expected_stock_fingerprint_sha256:$CUBS_STOCK_FINGERPRINT_SHA256" \
  "expected_ab_ota_partitions_sha256:$CUBS_AB_OTA_PARTITIONS_SHA256" \
  "expected_shared_super_layout_sha256:$CUBS_SHARED_SUPER_LAYOUT_SHA256"; do
  runner_name=${runner_pin%%:*}
  configured_value=${runner_pin#*:}
  runner_value=$(sed -n "s/^${runner_name}=//p" scripts/flash-a.sh)
  [[ "$runner_value" == "$configured_value" ]] || {
    printf 'error: standalone runner pin differs from project configuration: %s\n' \
      "$runner_name" >&2
    exit 1
  }
done
[[ $(sed -n 's/^handoff_ready_seconds=//p' scripts/flash-a.sh) == \
   "$CUBS_RECOVERY_HANDOFF_READY_SECONDS" && \
   $(sed -n 's/^handoff_resume_seconds=//p' scripts/flash-a.sh) == \
   "$CUBS_RECOVERY_HANDOFF_RESUME_SECONDS" ]] || {
  printf 'error: standalone runner handoff lifetimes differ from recovery.env\n' >&2
  exit 1
}

# Audit every file Git could currently stage, not only files already tracked.
# This catches a misplaced proprietary image or private key even in a fresh
# repository before the first commit.
lint_scratch=$(mktemp -d "${TMPDIR:-/tmp}/pixel-aosp-lint.XXXXXX")
cleanup_lint_scratch() {
  if [[ -n "${lint_scratch:-}" && -d "$lint_scratch" && \
        ! -L "$lint_scratch" && \
        "$lint_scratch" == "${TMPDIR:-/tmp}"/pixel-aosp-lint.* ]]; then
    rm -rf -- "$lint_scratch"
  fi
}
trap cleanup_lint_scratch EXIT
if ! git ls-files --cached --others --exclude-standard -z \
    >"$lint_scratch/stageable-paths"; then
  printf 'error: unable to enumerate stageable repository paths\n' >&2
  exit 1
fi
while IFS= read -r -d '' candidate; do
  # Normalize only for the denylist comparison so case variants such as
  # firmware.IMG or PRIVATE.PEM cannot bypass the publication gate.
  candidate_lower=${candidate,,}
  case "$candidate_lower" in
    work/*|out/*|downloads/*|proprietary/*|artifacts/*|logs/*|.cache/*|\
    .ccache/*|.repo/*|scripts/.*-test.*|*/proprietary/*|\
    __pycache__/*|*/__pycache__/*|*.pyc|*.pyo|*.pyd|\
    vendor/google_devices/cubs/*|\
    *.7z|*.aar|*.apex|*.apk|*.bin|*.cpio|*.cpio.*|*.dex|*.dtb|*.dtbo|\
    *.elf|*.[eE][xX][eE]|*.fw|*.img|*.jar|*.ko|*.mbn|\
    *.[mM][sS][iI]|*.oat|*.odex|*.so|*.tar|\
    *.tar.*|*.tgz|*.ucode|*.vdex|*.xz|*.zip|*.zst|\
    *.jks|*.keystore|*.p12|*.pfx|*.p8|*.pk8|*.pem|*.der|*.key|*.exe|*.dll|\
    */adbkey*|adbkey*|*/id_dsa*|id_dsa*|*/id_ecdsa*|id_ecdsa*|\
    */id_ed25519*|id_ed25519*|*/id_rsa*|id_rsa*|\
    */.netrc|.netrc|*/.npmrc|.npmrc|*/.pypirc|.pypirc|\
    */.env|.env|*/.env.*|.env.*|*/credentials.json|credentials.json|\
    */*-credentials.json|*-credentials.json|*/service-account.json|\
    service-account.json|*/service_account.json|service_account.json)
      printf 'error: prohibited generated or credential path is stageable: %s\n' \
        "$candidate" >&2
      exit 1
      ;;
  esac
done <"$lint_scratch/stageable-paths"

cleanup_lint_scratch
lint_scratch=
trap - EXIT

printf 'repository checks passed\n'
