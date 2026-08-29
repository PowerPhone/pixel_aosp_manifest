#!/usr/bin/env bash

# Helpers for the exact post-FileTreeSpec cubs fstab AVB normalization.
# Callers must source lib/common.sh first.

# shellcheck disable=SC2034 # public constants consumed by sourcing scripts
CUBS_ADEVTOOL_FSTAB_SHA256=c35d10a5a8be65057e898ba693b6cd5963272aeabf2c0b482e4843b300744673
# shellcheck disable=SC2034 # public constants consumed by sourcing scripts
CUBS_CHAINED_AVB_FSTAB_SHA256=827b95b759bfb843d3c2fee4af2bcf8e535d81fc87a051d37e69432b2f514312

cubs_fstab_avb_records() {
  local fstab=$1
  local description=${2:-cubs fstab}
  local records

  [[ -f "$fstab" && ! -L "$fstab" ]] || \
    die "$description is not a regular file: $fstab"
  if ! records=$(LC_ALL=C awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      {
        partition = $1
        sub(/^.*\/by-name\//, "", partition)
        flag_count = split($NF, flags, ",")
        avb_count = 0
        avb_target = ""
        for (flag_index = 1; flag_index <= flag_count; flag_index++) {
          if (flags[flag_index] ~ /^avb_keys=/) {
            exit 41
          }
          if (flags[flag_index] ~ /^avb=/) {
            avb_count++
            avb_target = substr(flags[flag_index], 5)
            if (avb_target !~ /^[a-z0-9_]+$/) {
              exit 42
            }
          }
        }
        if (avb_count > 1) {
          exit 43
        }
        if (avb_count == 1) {
          if (partition !~ /^[a-z0-9_]+$/) {
            exit 44
          }
          print partition ":" avb_target
        }
      }
    ' "$fstab"); then
    die "$description has malformed, duplicate, or key-bypassing AVB flags"
  fi
  [[ -n "$records" ]] || die "$description contains no active AVB records"
  printf '%s\n' "$records"
}

cubs_validate_fstab_avb_mapping() {
  local fstab=$1
  local mode=$2
  local description=${3:-cubs fstab}
  local actual expected

  case "$mode" in
    adevtool-root)
      expected=$(printf '%s\n' \
        boot:vbmeta \
        init_boot:vbmeta \
        product:vbmeta \
        system:vbmeta \
        system:vbmeta \
        system_dlkm:vbmeta \
        system_dlkm:vbmeta \
        system_ext:vbmeta \
        vendor:vbmeta \
        vendor_dlkm:vbmeta \
        vendor_dlkm:vbmeta | LC_ALL=C sort)
      ;;
    chained)
      expected=$(printf '%s\n' \
        boot:boot \
        init_boot:init_boot \
        product:vbmeta_system \
        system:vbmeta_system \
        system:vbmeta_system \
        system_dlkm:vbmeta_system \
        system_dlkm:vbmeta_system \
        system_ext:vbmeta_system \
        vendor:vbmeta_vendor \
        vendor_dlkm:vbmeta \
        vendor_dlkm:vbmeta | LC_ALL=C sort)
      ;;
    *) die "invalid cubs fstab AVB mapping mode: $mode" ;;
  esac

  actual=$(cubs_fstab_avb_records "$fstab" "$description" | LC_ALL=C sort)
  [[ "$actual" == "$expected" ]] || \
    die "$description does not contain the exact $mode AVB mapping"
}

cubs_fstab_child_avb_targets() {
  local fstab=$1
  local description=${2:-cubs fstab}

  cubs_fstab_avb_records "$fstab" "$description" | \
    LC_ALL=C awk -F: '$2 != "vbmeta" {print $2}' | LC_ALL=C sort -u
}

cubs_validate_fstab_against_root_chains() {
  local fstab=$1
  local root_chain_records=$2
  local description=${3:-cubs fstab}
  local fstab_targets root_targets

  cubs_validate_fstab_avb_mapping "$fstab" chained "$description"
  [[ -n "$root_chain_records" ]] || \
    die "$description root AVB chain record set is empty"
  if ! root_targets=$(printf '%s\n' "$root_chain_records" | LC_ALL=C awk -F: '
      NF != 2 || $1 !~ /^[a-z0-9_]+$/ || $2 !~ /^[1-9][0-9]*$/ {
        exit 61
      }
      { print $1 }
    ' | LC_ALL=C sort -u); then
    die "$description root AVB chain records are malformed"
  fi
  fstab_targets=$(cubs_fstab_child_avb_targets "$fstab" "$description")
  [[ -n "$fstab_targets" && "$fstab_targets" == "$root_targets" ]] || \
    die "$description child AVB targets differ from root vbmeta chain descriptors"
}

cubs_rewrite_fstab_avb_mapping() {
  local input=$1
  local output=$2
  local description=${3:-cubs fstab}

  cubs_validate_fstab_avb_mapping "$input" adevtool-root "$description"
  [[ "$input" != "$output" ]] || \
    die "cubs fstab AVB transform input and output must differ"
  if ! LC_ALL=C awk '
      function partition_name(source, name) {
        name = source
        sub(/^.*\/by-name\//, "", name)
        return name
      }
      {
        line = $0
        if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/) {
          partition = partition_name($1)
          target = ""
          if (partition == "system" || partition == "system_dlkm" ||
              partition == "system_ext" || partition == "product") {
            target = "vbmeta_system"
          } else if (partition == "vendor") {
            target = "vbmeta_vendor"
          } else if (partition == "boot") {
            target = "boot"
          } else if (partition == "init_boot") {
            target = "init_boot"
          }
          if (target != "") {
            changed = gsub(/avb=vbmeta,/, "avb=" target ",", line)
            if (changed != 1) {
              exit 51
            }
            replacements++
          }
        }
        print line
      }
      END {
        if (replacements != 9) {
          exit 52
        }
      }
    ' "$input" >"$output"; then
    die "failed to restore the exact cubs child AVB mappings in $description"
  fi
  cubs_validate_fstab_avb_mapping "$output" chained "$description output"
}

sanitize_cubs_fstab_avb_mapping() {
  local fstab=$1
  local pristine_sha256=$2
  local normalized_sha256=$3
  local check_only=$4
  local description=${5:-cubs fstab}
  local current_sha256 temporary_file

  [[ "$pristine_sha256" =~ ^[0-9a-f]{64}$ && \
     "$normalized_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die "invalid cubs fstab transform digest"
  [[ "$check_only" == true || "$check_only" == false ]] || \
    die "invalid cubs fstab check-only mode: $check_only"
  [[ -f "$fstab" && ! -L "$fstab" ]] || \
    die "$description is not a regular file: $fstab"

  current_sha256=$(sha256sum -- "$fstab")
  current_sha256=${current_sha256%% *}
  case "$current_sha256" in
    "$pristine_sha256")
      cubs_validate_fstab_avb_mapping "$fstab" adevtool-root "$description"
      [[ "$check_only" == false ]] || \
        die "generated cubs fstab child AVB mapping has not been restored: $fstab"
      temporary_file=$(mktemp --tmpdir="$(dirname -- "$fstab")" \
        '.fstab.malibu.avb.XXXXXX')
      if ! cubs_rewrite_fstab_avb_mapping \
          "$fstab" "$temporary_file" "$description"; then
        rm -f -- "$temporary_file"
        die "failed to normalize $description"
      fi
      verify_sha256 "$normalized_sha256" "$temporary_file"
      chmod --reference="$fstab" "$temporary_file"
      mv -- "$temporary_file" "$fstab"
      ;;
    "$normalized_sha256")
      cubs_validate_fstab_avb_mapping "$fstab" chained "$description"
      ;;
    *)
      die "$description differs from both exact pristine and normalized states: $fstab"
      ;;
  esac

  verify_sha256 "$normalized_sha256" "$fstab"
  cubs_validate_fstab_avb_mapping "$fstab" chained "$description"
}
