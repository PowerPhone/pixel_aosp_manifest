#!/usr/bin/env bash

# Helpers for the exact post-FileTreeSpec cubs SELinux compatibility transform.
# Callers must source lib/common.sh first.

sanitize_cubs_redundant_vndservicemanager_rule() {
  local policy_file=$1
  local pristine_sha256=$2
  local sanitized_sha256=$3
  local platform_type_suffix=$4
  local check_only=$5
  local synthetic_attribute=base_adevtool_typeattr_59
  local source_type="vndservicemanager${platform_type_suffix}"
  local init_type="init${platform_type_suffix}"
  local vendor_init_type="vendor_init${platform_type_suffix}"
  local allow_line
  local declaration_line
  local set_line
  local current_sha256
  local attribute_count
  local line_count
  local temporary_file

  [[ "$pristine_sha256" =~ ^[0-9a-f]{64}$ && \
     "$sanitized_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die "invalid cubs SELinux transform digest"
  [[ "$platform_type_suffix" == "" || \
     "$platform_type_suffix" == _202604 ]] || \
    die "unexpected cubs platform-policy suffix: $platform_type_suffix"
  [[ "$check_only" == true || "$check_only" == false ]] || \
    die "invalid cubs SELinux check-only mode: $check_only"
  [[ -f "$policy_file" && ! -L "$policy_file" ]] || \
    die "cubs generated SELinux extension is not a regular file: $policy_file"

  allow_line="(allow $source_type $synthetic_attribute (binder (transfer)))"
  declaration_line="(typeattribute $synthetic_attribute)"
  set_line="(typeattributeset $synthetic_attribute (and (domain) (not (coredomain $init_type $vendor_init_type))))"
  current_sha256=$(sha256sum -- "$policy_file")
  current_sha256=${current_sha256%% *}

  case "$current_sha256" in
    "$pristine_sha256")
      for expected_line in \
        "$allow_line" \
        "$declaration_line" \
        "$set_line"; do
        line_count=$(grep -Fxc -- "$expected_line" "$policy_file" || true)
        (( line_count == 1 )) || \
          die "pristine cubs SELinux extension lacks one exact redundant vndservicemanager component: $policy_file"
      done
      attribute_count=$(grep -Foc -- "$synthetic_attribute" "$policy_file" || true)
      (( attribute_count == 3 )) || \
        die "redundant cubs vndservicemanager attribute has unexpected consumers: $policy_file"
      [[ "$check_only" == false ]] || \
        die "generated cubs vndservicemanager duplicate has not been removed: $policy_file"

      # shellcheck disable=SC2154 # provided by lib/common.sh in every caller
      temporary_file=$(mktemp "$project_root/work/.cubs-sepolicy.XXXXXX")
      if ! LC_ALL=C sed \
        -e "\|^${allow_line}\$|d" \
        -e "\|^${declaration_line}\$|d" \
        -e "\|^${set_line}\$|d" \
        "$policy_file" >"$temporary_file"; then
        rm -f -- "$temporary_file"
        die "failed to remove exact redundant cubs vndservicemanager rule: $policy_file"
      fi
      verify_sha256 "$sanitized_sha256" "$temporary_file"
      chmod --reference="$policy_file" "$temporary_file"
      mv -- "$temporary_file" "$policy_file"
      ;;
    "$sanitized_sha256")
      attribute_count=$(grep -Foc -- "$synthetic_attribute" "$policy_file" || true)
      (( attribute_count == 0 )) || \
        die "sanitized cubs SELinux extension retains the redundant vndservicemanager attribute: $policy_file"
      ;;
    *)
      die "cubs SELinux extension differs from both exact pristine and sanitized states: $policy_file"
      ;;
  esac

  verify_sha256 "$sanitized_sha256" "$policy_file"
}
