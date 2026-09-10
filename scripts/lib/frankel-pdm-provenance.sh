#!/usr/bin/env bash

# Exact, reviewable provenance closure for the Frankel AP-PDM external module.
# This file is sourced by the module builder and generated-vendor sanitizer.

frankel_pdm_provenance_lock_relative_path='config/targets/frankel/powerphone-pdm.SHA256SUMS'

frankel_pdm_provenance_expected_paths() {
  printf '%s\n' \
    scripts/lib/frankel-pdm-provenance.sh \
    tools/audio/kernel/frankel_pdm_alsa/BUILD.bazel \
    tools/audio/kernel/frankel_pdm_alsa/allowed-imports.txt \
    tools/audio/kernel/frankel_pdm_alsa/build-frankel-gki.sh \
    tools/audio/kernel/frankel_pdm_alsa/ddk-MODULE.bazel.in \
    tools/audio/kernel/frankel_pdm_alsa/ddk-WORKSPACE.bzlmod \
    tools/audio/kernel/frankel_pdm_alsa/ddk-device.bazelrc \
    tools/audio/kernel/frankel_pdm_alsa/frankel_pdm_alsa.c \
    tools/audio/kernel/frankel_pdm_dt_probe/bootstrap-frankel-ddk.sh \
    tools/audio/kernel/frankel_pdm_dt_probe/frankel-ddk-only.xml \
    work/upstream/frankel-gki-15739706/BUILD_INFO \
    work/upstream/frankel-gki-15739706/Image \
    work/upstream/frankel-gki-15739706/Image.gz \
    work/upstream/frankel-gki-15739706/Image.lz4 \
    work/upstream/frankel-gki-15739706/Module.symvers \
    work/upstream/frankel-gki-15739706/System.map \
    work/upstream/frankel-gki-15739706/abi_symbollist \
    work/upstream/frankel-gki-15739706/boot-gz.img \
    work/upstream/frankel-gki-15739706/boot-img.tar.gz \
    work/upstream/frankel-gki-15739706/boot-lz4.img \
    work/upstream/frankel-gki-15739706/boot.img \
    work/upstream/frankel-gki-15739706/build.config.constants \
    work/upstream/frankel-gki-15739706/ci_target_mapping.json \
    work/upstream/frankel-gki-15739706/ddk-workspace/.repo/manifests/kleaf.xml \
    work/upstream/frankel-gki-15739706/gki-info.txt \
    work/upstream/frankel-gki-15739706/init_ddk.zip \
    work/upstream/frankel-gki-15739706/kernel-headers.tar.gz \
    work/upstream/frankel-gki-15739706/kernel-uapi-headers.tar.gz \
    work/upstream/frankel-gki-15739706/kernel_aarch64_ddk_headers_archive.tar.gz \
    work/upstream/frankel-gki-15739706/kernel_aarch64_filegroup_decl.tar.gz \
    work/upstream/frankel-gki-15739706/manifest.xml \
    work/upstream/frankel-gki-15739706/modules.builtin \
    work/upstream/frankel-gki-15739706/modules.builtin.modinfo \
    work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.ko \
    work/upstream/frankel-gki-15739706/modules/frankel_pdm_alsa.unstripped.ko \
    work/upstream/frankel-gki-15739706/system_dlkm.modules.blocklist \
    work/upstream/frankel-gki-15739706/system_dlkm.modules.load \
    work/upstream/frankel-gki-15739706/system_dlkm_staging_archive.tar.gz \
    work/upstream/frankel-gki-15739706/unstripped_modules.tar.gz \
    work/upstream/frankel-gki-15739706/vmlinux \
    work/upstream/frankel-gki-15739706/vmlinux.symvers
}

frankel_pdm_provenance_validate_ddk() {
  local provenance_root=$1 artifacts ddk manifest template

  provenance_root=$(realpath -e -- "$provenance_root") || return 1
  artifacts="$provenance_root/work/upstream/frankel-gki-15739706"
  ddk="$artifacts/ddk-workspace"
  manifest="$ddk/.repo/manifests/kleaf.xml"
  template="$provenance_root/tools/audio/kernel/frankel_pdm_alsa"
  [[ -d "$ddk" && ! -L "$ddk" ]] || {
    printf 'Frankel DDK workspace is missing or unsafe: %s\n' "$ddk" >&2
    return 1
  }
  for path in \
    "$ddk/MODULE.bazel" \
    "$ddk/WORKSPACE.bzlmod" \
    "$ddk/device.bazelrc" \
    "$manifest"; do
    [[ -f "$path" && ! -L "$path" ]] || {
      printf 'Frankel DDK generated input is missing or unsafe: %s\n' \
        "$path" >&2
      return 1
    }
  done

  python3 - "$template" "$artifacts" "$ddk" "$manifest" <<'PY'
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET

template_dir = pathlib.Path(sys.argv[1])
artifacts = pathlib.Path(sys.argv[2])
workspace = pathlib.Path(sys.argv[3])
manifest = pathlib.Path(sys.argv[4])

expected_module = (template_dir / "ddk-MODULE.bazel.in").read_text(
    encoding="utf-8"
).replace("@FRANKEL_GKI_ARTIFACTS@", str(artifacts))
checks = {
    workspace / "MODULE.bazel": expected_module.encode(),
    workspace / "WORKSPACE.bzlmod": (
        template_dir / "ddk-WORKSPACE.bzlmod"
    ).read_bytes(),
    workspace / "device.bazelrc": (
        template_dir / "ddk-device.bazelrc"
    ).read_bytes(),
}
for path, expected in checks.items():
    if path.read_bytes() != expected:
        raise SystemExit(f"Frankel DDK generated input differs from template: {path}")

projects = {}
for project in ET.parse(manifest).getroot().findall("project"):
    path = project.get("path")
    revision = project.get("revision")
    if not path or not revision or path in projects:
        raise SystemExit("Frankel DDK manifest has an invalid project entry")
    if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
        raise SystemExit(f"Frankel DDK manifest revision is not pinned: {path}")
    projects[path] = revision

repo = workspace / ".repo/repo/repo"
actual_paths = set(
    subprocess.check_output([str(repo), "list", "-p"], cwd=workspace, text=True).split()
)
if actual_paths != set(projects):
    raise SystemExit("Frankel DDK checkout project set differs from pinned manifest")
for relative, revision in sorted(projects.items()):
    checkout = workspace / relative
    head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=checkout, text=True
    ).strip()
    if head != revision:
        raise SystemExit(
            f"Frankel DDK project {relative} is {head}, expected {revision}"
        )
    subprocess.run(["git", "diff-index", "--quiet", "HEAD", "--"], cwd=checkout,
                   check=True)
    untracked = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard"],
        cwd=checkout,
        text=True,
    ).strip()
    if untracked:
        raise SystemExit(f"Frankel DDK project has untracked files: {relative}")
PY
}

frankel_pdm_provenance_require_plain_path() {
  local provenance_root=$1 relative_path=$2 path resolved

  [[ "$relative_path" =~ ^[-A-Za-z0-9._]+(/[-A-Za-z0-9._]+)*$ ]] || {
    printf 'unsafe Frankel PDM provenance path: %s\n' "$relative_path" >&2
    return 1
  }
  [[ ! "$relative_path" =~ (^|/)\.\.?(/|$) ]] || {
    printf 'traversal in Frankel PDM provenance path: %s\n' "$relative_path" >&2
    return 1
  }
  path="$provenance_root/$relative_path"
  [[ -f "$path" && ! -L "$path" ]] || {
    printf 'Frankel PDM provenance input is missing or not a plain file: %s\n' \
      "$path" >&2
    return 1
  }
  resolved=$(realpath -e -- "$path") || return 1
  [[ "$resolved" == "$path" ]] || {
    printf 'Frankel PDM provenance input resolves through a symlink: %s\n' \
      "$path" >&2
    return 1
  }
}

frankel_pdm_provenance_validate_lock_at() {
  local provenance_root=$1 lock=$2 digest relative_path extra expected_path
  local -a expected_paths=()
  local -A expected=() seen=()

  provenance_root=$(realpath -e -- "$provenance_root") || return 1
  [[ -f "$lock" && ! -L "$lock" ]] || {
    printf 'Frankel PDM provenance lock is missing or unsafe: %s\n' "$lock" >&2
    return 1
  }
  [[ $(realpath -e -- "$lock") == "$lock" ]] || {
    printf 'Frankel PDM provenance lock resolves through a symlink: %s\n' \
      "$lock" >&2
    return 1
  }

  mapfile -t expected_paths < <(frankel_pdm_provenance_expected_paths)
  (( ${#expected_paths[@]} > 0 )) || {
    printf 'empty Frankel PDM provenance allowlist\n' >&2
    return 1
  }
  for expected_path in "${expected_paths[@]}"; do
    [[ -z "${expected[$expected_path]+present}" ]] || {
      printf 'duplicate Frankel PDM provenance allowlist path: %s\n' \
        "$expected_path" >&2
      return 1
    }
    expected[$expected_path]=1
  done

  while IFS=' ' read -r digest relative_path extra; do
    [[ "$digest" =~ ^[0-9a-f]{64}$ && -n "$relative_path" && \
       -z "$extra" ]] || {
      printf 'malformed Frankel PDM provenance lock entry\n' >&2
      return 1
    }
    [[ -n "${expected[$relative_path]+present}" ]] || {
      printf 'unexpected Frankel PDM provenance lock path: %s\n' \
        "$relative_path" >&2
      return 1
    }
    [[ -z "${seen[$relative_path]+present}" ]] || {
      printf 'duplicate Frankel PDM provenance lock path: %s\n' \
        "$relative_path" >&2
      return 1
    }
    frankel_pdm_provenance_require_plain_path \
      "$provenance_root" "$relative_path" || return 1
    seen[$relative_path]=1
  done < "$lock"

  (( ${#seen[@]} == ${#expected_paths[@]} )) || {
    printf 'Frankel PDM provenance lock does not cover its exact allowlist\n' >&2
    return 1
  }
  for expected_path in "${expected_paths[@]}"; do
    [[ -n "${seen[$expected_path]+present}" ]] || {
      printf 'Frankel PDM provenance lock omits: %s\n' "$expected_path" >&2
      return 1
    }
  done
  (
    cd "$provenance_root"
    sha256sum --check --strict --status "$lock"
  ) || {
    printf 'Frankel PDM provenance lock digest mismatch\n' >&2
    return 1
  }
}

frankel_pdm_provenance_validate_lock() {
  local provenance_root=$1
  provenance_root=$(realpath -e -- "$provenance_root") || return 1
  frankel_pdm_provenance_validate_lock_at "$provenance_root" \
    "$provenance_root/$frankel_pdm_provenance_lock_relative_path" && \
    frankel_pdm_provenance_validate_ddk "$provenance_root"
}

frankel_pdm_provenance_write_lock() {
  local provenance_root=$1 lock temporary relative_path
  local -a expected_paths=()

  provenance_root=$(realpath -e -- "$provenance_root") || return 1
  lock="$provenance_root/$frankel_pdm_provenance_lock_relative_path"
  [[ ! -e "$lock" || ( -f "$lock" && ! -L "$lock" ) ]] || {
    printf 'refusing to replace unsafe Frankel PDM provenance lock: %s\n' \
      "$lock" >&2
    return 1
  }
  mapfile -t expected_paths < <(frankel_pdm_provenance_expected_paths)
  for relative_path in "${expected_paths[@]}"; do
    frankel_pdm_provenance_require_plain_path \
      "$provenance_root" "$relative_path" || return 1
  done

  temporary=$(mktemp \
    "$(dirname -- "$lock")/.powerphone-pdm-provenance.XXXXXX") || return 1
  if ! (
    cd "$provenance_root"
    sha256sum -- "${expected_paths[@]}"
  ) > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0644 "$temporary"
  if ! frankel_pdm_provenance_validate_lock_at \
      "$provenance_root" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  mv -f -- "$temporary" "$lock"
  frankel_pdm_provenance_validate_lock "$provenance_root"
}
