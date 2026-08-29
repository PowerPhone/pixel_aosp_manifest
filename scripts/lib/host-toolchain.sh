#!/usr/bin/env bash

# Archive-derived host-toolchain attestation. This file is sourced by callers.

host_toolchain_source=${BASH_SOURCE[0]}
case "$host_toolchain_source" in
  */*) host_toolchain_source_directory=${host_toolchain_source%/*} ;;
  *) host_toolchain_source_directory=. ;;
esac
host_toolchain_helper_dir=$(
  builtin cd -- "$host_toolchain_source_directory" && builtin pwd -P
)
host_toolchain_python="$host_toolchain_helper_dir/host-toolchain.py"
unset host_toolchain_source host_toolchain_source_directory

host_toolchain_safe_extract() {
  /usr/bin/python3 -B "$host_toolchain_python" extract \
    --archive "$1" \
    --root "$2" \
    --sha256 "$3" \
    --destination "$4"
}

host_toolchain_safe_extract_zip() {
  /usr/bin/python3 -B "$host_toolchain_python" extract-zip \
    --archive "$1" \
    --root "$2" \
    --sha256 "$3" \
    --destination "$4"
}

host_toolchain_validate_archive() {
  /usr/bin/python3 -B "$host_toolchain_python" validate-archive \
    --archive "$1" \
    --root "$2" \
    --sha256 "$3"
}

host_toolchain_verify_node() {
  /usr/bin/python3 -B "$host_toolchain_python" verify-node \
    --archive "$1" \
    --root "$2" \
    --sha256 "$3" \
    --installed "$4" \
    --scratch-parent "$5"
}

host_toolchain_verify_yarn() {
  /usr/bin/python3 -B "$host_toolchain_python" verify-yarn \
    --archive "$1" \
    --root "$2" \
    --sha256 "$3" \
    --node-root "$4" \
    --version "$5" \
    --url "$6" \
    --scratch-parent "$7"
}

host_toolchain_stage_yarn() {
  /usr/bin/python3 -B "$host_toolchain_python" stage-yarn \
    --archive "$1" \
    --root "$2" \
    --sha256 "$3" \
    --node-root "$4" \
    --version "$5" \
    --url "$6" \
    --scratch-parent "$7"
}

host_toolchain_verify_regular_sha256() {
  /usr/bin/python3 -B "$host_toolchain_python" verify-file \
    --path "$1" \
    --sha256 "$2" \
    --label "$3"
}

host_toolchain_verify_zip_tree() {
  /usr/bin/python3 -B "$host_toolchain_python" verify-zip-tree \
    --archive "$1" \
    --root "$2" \
    --sha256 "$3" \
    --installed "$4" \
    --scratch-parent "$5"
}

host_toolchain_archive_previous_directory() {
  local previous=$1
  local target=$2
  local label=$3
  local timestamp archived archive_base suffix=0
  timestamp=$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)
  archive_base="$target.invalid.$timestamp.$$"
  archived=$archive_base
  while [[ -e "$archived" || -L "$archived" ]]; do
    (( suffix += 1 ))
    archived="$archive_base.$suffix"
  done
  /usr/bin/mv --no-target-directory -- "$previous" "$archived"
}

host_toolchain_reconcile_version_directory() {
  local target=$1
  local label=$2
  local previous="$target.previous"
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -d "$target" && ! -L "$target" ]] || {
      printf 'error: %s version path is not a real directory: %s\n' \
        "$label" "$target" >&2
      return 1
    }
  fi
  if [[ -e "$previous" || -L "$previous" ]]; then
    [[ -d "$previous" && ! -L "$previous" ]] || {
      printf 'error: %s previous path is not a real directory: %s\n' \
        "$label" "$previous" >&2
      return 1
    }
    if [[ ! -e "$target" ]]; then
      # A crash occurred after old -> previous but before staged -> target.
      /usr/bin/mv --no-target-directory -- "$previous" "$target"
    else
      # Both names means staged -> target committed before the crash.
      host_toolchain_archive_previous_directory "$previous" "$target" "$label"
    fi
  fi
}

host_toolchain_publish_version_directory() {
  local staged=$1
  local target=$2
  local label=$3
  local previous="$target.previous"
  local target_parent=${target%/*}
  [[ "$target_parent" != "$target" && -d "$target_parent" && \
     ! -L "$target_parent" ]] || {
    printf 'error: %s version parent is not a real directory: %s\n' \
      "$label" "$target_parent" >&2
    return 1
  }
  [[ -d "$staged" && ! -L "$staged" ]] || {
    printf 'error: staged %s path is not a real directory: %s\n' \
      "$label" "$staged" >&2
    return 1
  }
  [[ $(/usr/bin/stat -c %d -- "$staged") == \
     $(/usr/bin/stat -c %d -- "$target_parent") ]] || {
    printf 'error: staged %s directory is not on the publication filesystem\n' \
      "$label" >&2
    return 1
  }
  host_toolchain_reconcile_version_directory "$target" "$label"
  [[ ! -e "$previous" && ! -L "$previous" ]] || {
    printf 'error: unreconciled %s previous path: %s\n' \
      "$label" "$previous" >&2
    return 1
  }
  if [[ -e "$target" ]]; then
    /usr/bin/mv --no-target-directory -- "$target" "$previous"
  fi
  if ! /usr/bin/mv --no-target-directory -- "$staged" "$target"; then
    if [[ -d "$previous" && ! -L "$previous" && \
          ! -e "$target" && ! -L "$target" ]]; then
      /usr/bin/mv --no-target-directory -- "$previous" "$target" || true
    fi
    return 1
  fi
  if [[ -d "$previous" && ! -L "$previous" ]]; then
    host_toolchain_archive_previous_directory "$previous" "$target" "$label"
  fi
}

host_toolchain_replace_symlink_atomic() {
  local target=$1
  local link=$2
  local label=$3
  local link_parent=${link%/*}
  local link_name=${link##*/}
  local temporary_link="$link_parent/.$link_name.next"
  [[ "$link_parent" != "$link" && -d "$link_parent" && \
     ! -L "$link_parent" ]] || {
    printf 'error: %s link parent is not a real directory: %s\n' \
      "$label" "$link_parent" >&2
    return 1
  }
  if [[ -e "$link" || -L "$link" ]]; then
    [[ -L "$link" ]] || {
      printf 'error: %s convenience path is not a symlink: %s\n' \
        "$label" "$link" >&2
      return 1
    }
  fi
  if [[ -e "$temporary_link" || -L "$temporary_link" ]]; then
    [[ -L "$temporary_link" ]] || {
      printf 'error: %s temporary link is unsafe: %s\n' \
        "$label" "$temporary_link" >&2
      return 1
    }
    /usr/bin/unlink -- "$temporary_link"
  fi
  /usr/bin/ln -s -- "$target" "$temporary_link"
  /usr/bin/mv --no-target-directory -- "$temporary_link" "$link"
  [[ -L "$link" && $(/usr/bin/readlink -- "$link") == "$target" ]] || {
    printf 'error: failed to publish %s convenience link: %s\n' \
      "$label" "$link" >&2
    return 1
  }
}
