#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
# shellcheck source=../lib/host-toolchain.sh
source "$project_root/scripts/lib/host-toolchain.sh"

test_parent="$project_root/work/host-toolchain-tests"
[[ ! -L "$project_root/work" && ! -L "$test_parent" ]] || {
  printf 'error: host-toolchain test root must not be a symlink\n' >&2
  exit 1
}
mkdir -p "$test_parent"
[[ -d "$test_parent" && ! -L "$test_parent" ]] || {
  printf 'error: host-toolchain test root is not a real directory\n' >&2
  exit 1
}
test_root=$(mktemp -d "$test_parent/.simulate.XXXXXX")
cleanup() {
  local status=$?
  if [[ -d "$test_root" && ! -L "$test_root" && \
        "$test_root" == "$test_parent"/.simulate.* ]]; then
    rm -rf -- "$test_root"
  fi
  return "$status"
}
trap cleanup EXIT
umask 077

node_root_name=node-v1.0.0-linux-x64
node_archive="$test_root/node.tar.xz"
yarn_archive="$test_root/yarn.tgz"
yarn_version=1.22.22
yarn_url=https://fixtures.invalid/yarn-1.22.22.tgz

python3 - "$test_root" "$node_root_name" <<'PY'
import io
import json
import os
import pathlib
import stat
import sys
import tarfile
import zipfile

root = pathlib.Path(sys.argv[1])
node_name = sys.argv[2]
source = root / "source" / node_name
(source / "bin").mkdir(parents=True)
(source / "lib/node_modules/npm/bin").mkdir(parents=True)
(source / "lib/node_modules/corepack/dist").mkdir(parents=True)
(source / "share/empty").mkdir(parents=True)
(source / "bin/node").write_text("#!/bin/sh\nprintf 'v1.0.0\\n'\n", encoding="utf-8")
os.chmod(source / "bin/node", 0o755)
(source / "lib/node_modules/npm/bin/npm-cli.js").write_text(
    "fixture npm\n", encoding="utf-8"
)
(source / "lib/node_modules/corepack/dist/yarn.js").write_text(
    "archive-owned yarn shim\n", encoding="utf-8"
)
os.symlink("../lib/node_modules/npm/bin/npm-cli.js", source / "bin/npm")

with tarfile.open(root / "node.tar.xz", "w:xz", format=tarfile.GNU_FORMAT) as archive:
    archive.add(source, arcname=node_name, recursive=True)

yarn_files = {
    "package/package.json": (
        json.dumps(
            {
                "name": "yarn",
                "version": "1.22.22",
                "license": "BSD-2-Clause",
                "bin": {"yarn": "./bin/yarn.js", "yarnpkg": "./bin/yarn.js"},
                "engines": {"node": ">=4.0.0"},
                "scripts": {"preinstall": "touch should-never-exist"},
            },
            sort_keys=True,
        ).encode(),
        0o644,
    ),
    "package/bin/yarn.js": (b"#!/bin/sh\nprintf '1.22.22\\n'\n", 0o755),
    "package/README.md": (b"fixture yarn\n", 0o644),
    "package/preinstall.js": (b"touch should-never-exist\n", 0o644),
}
with tarfile.open(root / "yarn.tgz", "w:gz", format=tarfile.USTAR_FORMAT) as archive:
    for name, (content, mode) in yarn_files.items():
        member = tarfile.TarInfo(name)
        member.size = len(content)
        member.mode = mode
        archive.addfile(member, io.BytesIO(content))


def one_member_archive(path, members):
    with tarfile.open(path, "w") as archive:
        for name, kind, target, mode in members:
            member = tarfile.TarInfo(name)
            member.mode = mode
            if kind == "file":
                data = b"x"
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            elif kind == "dir":
                member.type = tarfile.DIRTYPE
                archive.addfile(member)
            elif kind == "symlink":
                member.type = tarfile.SYMTYPE
                member.linkname = target
                archive.addfile(member)
            elif kind == "hardlink":
                member.type = tarfile.LNKTYPE
                member.linkname = target
                archive.addfile(member)
            elif kind == "fifo":
                member.type = tarfile.FIFOTYPE
                archive.addfile(member)


bad = root / "bad"
bad.mkdir()
one_member_archive(bad / "traversal.tar", [(f"{node_name}/../../escape", "file", "", 0o644)])
one_member_archive(bad / "absolute.tar", [("/absolute", "file", "", 0o644)])
one_member_archive(
    bad / "multiple-roots.tar",
    [(f"{node_name}/file", "file", "", 0o644), ("other/file", "file", "", 0o644)],
)
one_member_archive(
    bad / "duplicate.tar",
    [(f"{node_name}/file", "file", "", 0o644), (f"{node_name}/file", "file", "", 0o644)],
)
one_member_archive(
    bad / "hardlink.tar",
    [(f"{node_name}/hard", "hardlink", f"{node_name}/target", 0o644)],
)
one_member_archive(bad / "fifo.tar", [(f"{node_name}/fifo", "fifo", "", 0o644)])
one_member_archive(bad / "setuid.tar", [(f"{node_name}/file", "file", "", 0o4755)])
one_member_archive(
    bad / "escaping-link.tar",
    [(f"{node_name}/bin/link", "symlink", "../../escape", 0o777)],
)
one_member_archive(
    bad / "dangling-link.tar",
    [(f"{node_name}/bin/link", "symlink", "../missing", 0o777)],
)
one_member_archive(
    bad / "symlink-ancestor.tar",
    [
        (f"{node_name}/link", "symlink", "bin", 0o777),
        (f"{node_name}/link/child", "file", "", 0o644),
    ],
)
one_member_archive(
    bad / "file-ancestor.tar",
    [
        (f"{node_name}/file", "file", "", 0o644),
        (f"{node_name}/file/child", "file", "", 0o644),
    ],
)

with zipfile.ZipFile(root / "platform.zip", "w") as archive:
    for name, content, mode in (
        ("platform-tools/adb", b"#!/bin/sh\nprintf 'Version 1.0-1\\n'\n", 0o755),
        (
            "platform-tools/fastboot",
            b"#!/bin/sh\nprintf 'fastboot version 1.0-1\\n'\n",
            0o755,
        ),
        ("platform-tools/lib64/libc++.so", b"fixture library\n", 0o755),
        ("platform-tools/NOTICE.txt", b"fixture notice\n", 0o644),
    ):
        valid_zip = zipfile.ZipInfo(name)
        valid_zip.create_system = 3
        valid_zip.external_attr = (stat.S_IFREG | mode) << 16
        archive.writestr(valid_zip, content)
bad_zip = zipfile.ZipInfo("platform-tools/../../escape")
bad_zip.create_system = 3
bad_zip.external_attr = (stat.S_IFREG | 0o644) << 16
with zipfile.ZipFile(bad / "traversal.zip", "w") as archive:
    archive.writestr(bad_zip, b"escape")
PY

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

node_sha256=$(sha256_of "$node_archive")
yarn_sha256=$(sha256_of "$yarn_archive")
installed_parent="$test_root/installed"
mkdir "$installed_parent"
host_toolchain_safe_extract \
  "$node_archive" "$node_root_name" "$node_sha256" "$installed_parent"
installed="$installed_parent/$node_root_name"
host_toolchain_stage_yarn \
  "$yarn_archive" package "$yarn_sha256" "$installed" \
  "$yarn_version" "$yarn_url" "$test_root"

verify_node() {
  host_toolchain_verify_node \
    "$node_archive" "$node_root_name" "$node_sha256" "$1" "$test_root"
}

verify_yarn() {
  host_toolchain_verify_yarn \
    "$yarn_archive" package "$yarn_sha256" "$1" \
    "$yarn_version" "$yarn_url" "$test_root"
}

expect_failure() {
  local label=$1
  local expected_text=$2
  shift 2
  local output
  if output=$("$@" 2>&1); then
    printf 'error: expected failure was accepted: %s\n' "$label" >&2
    exit 1
  fi
  grep -Fq -- "$expected_text" <<<"$output" || {
    printf 'error: wrong diagnostic for %s; wanted %s, got:\n%s\n' \
      "$label" "$expected_text" "$output" >&2
    exit 1
  }
}

clone_install() {
  local name=$1
  clone_path="$test_root/cases/$name/$node_root_name"
  mkdir -p "$(dirname -- "$clone_path")"
  cp -a -- "$installed" "$clone_path"
}

# Exact trees pass, and timestamps are deliberately outside the attestation.
verify_node "$installed"
verify_yarn "$installed"
touch -m -d '2001-02-03 04:05:06 UTC' "$installed/bin/node"
verify_node "$installed"
[[ ! -e "$test_root/should-never-exist" ]] || {
  printf 'error: Yarn lifecycle fixture was executed\n' >&2
  exit 1
}

clone_install node-content
printf 'tampered\n' >>"$clone_path/bin/node"
expect_failure node-content 'equivalence mismatch at: bin/node' verify_node "$clone_path"

clone_install node-mode
chmod 0644 "$clone_path/bin/node"
expect_failure node-mode 'equivalence mismatch at: bin/node' verify_node "$clone_path"

clone_install node-symlink-target
unlink "$clone_path/bin/npm"
ln -s ../lib/node_modules/corepack/dist/yarn.js "$clone_path/bin/npm"
expect_failure node-symlink-target 'equivalence mismatch at: bin/npm' verify_node "$clone_path"

clone_install node-extra
printf 'extra\n' >"$clone_path/extra"
expect_failure node-extra 'unexpected entry: extra' verify_node "$clone_path"

clone_install archive-owned-yarn
printf 'tampered\n' >>"$clone_path/lib/node_modules/corepack/dist/yarn.js"
expect_failure archive-owned-yarn \
  'equivalence mismatch at: lib/node_modules/corepack/dist/yarn.js' \
  verify_node "$clone_path"

clone_install node-hardlink
ln "$clone_path/bin/node" "$test_root/cases/node-hardlink-alias"
expect_failure node-hardlink 'unsafe link count' verify_node "$clone_path"

clone_install yarn-content
printf 'tampered\n' >>"$clone_path/node_modules/yarn/README.md"
expect_failure yarn-content 'equivalence mismatch at: README.md' verify_yarn "$clone_path"

clone_install yarn-mode
chmod 0644 "$clone_path/node_modules/yarn/bin/yarn.js"
expect_failure yarn-mode 'equivalence mismatch at: bin/yarn.js' verify_yarn "$clone_path"

clone_install yarn-launcher
unlink "$clone_path/node_modules/.bin/yarn"
ln -s ../yarn/bin/../bin/yarn.js "$clone_path/node_modules/.bin/yarn"
expect_failure yarn-launcher 'Yarn launcher target is' verify_yarn "$clone_path"

clone_install yarn-regular-launcher
unlink "$clone_path/node_modules/.bin/yarn"
printf '#!/bin/sh\nprintf "1.22.22\\n"\n' >"$clone_path/node_modules/.bin/yarn"
chmod 0755 "$clone_path/node_modules/.bin/yarn"
expect_failure yarn-regular-launcher 'Yarn launcher is not a symbolic link' \
  verify_yarn "$clone_path"

clone_install yarn-extra
mkdir "$clone_path/node_modules/unpinned"
expect_failure yarn-extra 'Yarn node_modules entries differ' verify_yarn "$clone_path"

clone_install yarn-lock
python3 - "$clone_path/package-lock.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["unexpected"] = True
path.write_text(json.dumps(value))
PY
expect_failure yarn-lock 'root package-lock.json differs' verify_yarn "$clone_path"

fake_adb="$test_root/adb"
printf '#!/bin/sh\nprintf "Version 1.0-1\\n"\n' >"$fake_adb"
chmod 0755 "$fake_adb"
adb_sha256=$(sha256_of "$fake_adb")
host_toolchain_verify_regular_sha256 "$fake_adb" "$adb_sha256" adb
printf '# version remains identical\n' >>"$fake_adb"
expect_failure adb-bytes 'adb SHA-256 is' \
  host_toolchain_verify_regular_sha256 "$fake_adb" "$adb_sha256" adb
ln -s "$fake_adb" "$test_root/adb-link"
expect_failure adb-symlink 'cannot open adb' \
  host_toolchain_verify_regular_sha256 "$test_root/adb-link" \
  "$(sha256_of "$fake_adb")" adb

for bad_archive in "$test_root"/bad/*.tar; do
  destination="$test_root/reject-$(basename -- "$bad_archive" .tar)"
  mkdir "$destination"
  expect_failure "$(basename -- "$bad_archive")" 'error:' \
    host_toolchain_safe_extract "$bad_archive" "$node_root_name" \
    "$(sha256_of "$bad_archive")" "$destination"
  [[ -z "$(find "$destination" -mindepth 1 -print -quit)" ]] || {
    printf 'error: unsafe archive was partly extracted: %s\n' "$bad_archive" >&2
    exit 1
  }
done
[[ ! -e "$test_root/escape" ]] || {
  printf 'error: archive traversal escaped its destination\n' >&2
  exit 1
}

wrong_digest_destination="$test_root/reject-wrong-digest"
mkdir "$wrong_digest_destination"
expect_failure archive-digest 'toolchain archive SHA-256 is' \
  host_toolchain_safe_extract "$node_archive" "$node_root_name" \
  0000000000000000000000000000000000000000000000000000000000000000 \
  "$wrong_digest_destination"
ln -s "$node_archive" "$test_root/node-link.tar.xz"
symlink_destination="$test_root/reject-archive-symlink"
mkdir "$symlink_destination"
expect_failure archive-symlink 'cannot open toolchain archive' \
  host_toolchain_safe_extract "$test_root/node-link.tar.xz" "$node_root_name" \
  "$node_sha256" "$symlink_destination"

platform_archive="$test_root/platform.zip"
platform_sha256=$(sha256_of "$platform_archive")
platform_extract="$test_root/platform-extract"
mkdir "$platform_extract"
host_toolchain_safe_extract_zip \
  "$platform_archive" platform-tools "$platform_sha256" "$platform_extract"
platform_install="$platform_extract/platform-tools"
platform_adb="$platform_install/adb"
host_toolchain_verify_zip_tree \
  "$platform_archive" platform-tools "$platform_sha256" \
  "$platform_install" "$test_root"
host_toolchain_verify_regular_sha256 \
  "$platform_adb" "$(sha256_of "$platform_adb")" 'extracted adb'

platform_extra="$test_root/platform-extra"
cp -a -- "$platform_install" "$platform_extra"
# Fixture expands the marker only if executed.
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf shadow >"$HOST_TOOLCHAIN_SHADOW_MARKER"\n' \
  >"$platform_extra/python3"
chmod 0755 "$platform_extra/python3"
expect_failure platform-shadow 'unexpected entry: python3' \
  host_toolchain_verify_zip_tree \
  "$platform_archive" platform-tools "$platform_sha256" \
  "$platform_extra" "$test_root"

platform_tampered="$test_root/platform-tampered"
cp -a -- "$platform_install" "$platform_tampered"
printf '# same reported version, different bytes\n' >>"$platform_tampered/adb"
expect_failure platform-content 'equivalence mismatch at: adb' \
  host_toolchain_verify_zip_tree \
  "$platform_archive" platform-tools "$platform_sha256" \
  "$platform_tampered" "$test_root"
bad_zip="$test_root/bad/traversal.zip"
bad_zip_extract="$test_root/reject-bad-zip"
mkdir "$bad_zip_extract"
expect_failure zip-traversal 'archive member name is not canonical' \
  host_toolchain_safe_extract_zip \
  "$bad_zip" platform-tools "$(sha256_of "$bad_zip")" "$bad_zip_extract"
[[ -z "$(find "$bad_zip_extract" -mindepth 1 -print -quit)" ]] || {
  printf 'error: unsafe ZIP was partly extracted\n' >&2
  exit 1
}

# PATH-resolved bootstrap commands must never run, even if common.sh was loaded
# first and workspace candidates were prepended as in the historical sequence.
shadow_directory="$test_root/bootstrap-shadow"
mkdir "$shadow_directory"
bootstrap_marker="$test_root/bootstrap-shadow-ran"
export HOST_TOOLCHAIN_SHADOW_MARKER="$bootstrap_marker"
for shadow_command in python3 dirname; do
  # Generated shim expands in its own process.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s\\n" "$0" >>"$HOST_TOOLCHAIN_SHADOW_MARKER"\nexit 97\n' \
    >"$shadow_directory/$shadow_command"
  chmod 0755 "$shadow_directory/$shadow_command"
done
bootstrap_payload="$test_root/bootstrap-payload"
printf 'trusted bootstrap payload\n' >"$bootstrap_payload"
bootstrap_sha256=$(sha256_of "$bootstrap_payload")
PATH="$shadow_directory:$PATH" /bin/bash -c '
  set -euo pipefail
  source "$1"
  source "$2"
  host_toolchain_verify_regular_sha256 "$3" "$4" bootstrap
' _ \
  "$project_root/scripts/lib/common.sh" \
  "$project_root/scripts/lib/host-toolchain.sh" \
  "$bootstrap_payload" "$bootstrap_sha256"
[[ ! -e "$bootstrap_marker" ]] || {
  printf 'error: PATH-shadowed bootstrap command was executed\n' >&2
  exit 1
}

# Directory-FD flock serializes cooperating installers without a stale path.
lock_directory="$test_root/toolchain-lock"
mkdir "$lock_directory"
lock_ready="$test_root/toolchain-lock-ready"
(
  exec {first_lock_fd}<"$lock_directory"
  /usr/bin/flock -x "$first_lock_fd"
  : >"$lock_ready"
  /bin/sleep 0.2
) &
first_lock_pid=$!
while [[ ! -e "$lock_ready" ]]; do
  /bin/sleep 0.01
done
(
  exec {second_lock_fd}<"$lock_directory"
  if /usr/bin/flock -n "$second_lock_fd"; then
    printf 'error: concurrent directory lock unexpectedly succeeded\n' >&2
    exit 1
  fi
)
wait "$first_lock_pid"

# Publication is recoverable at either rename boundary and links have no gap.
publication_root="$test_root/publication"
mkdir "$publication_root"
publish_target="$publication_root/tool-v1"
publish_staged="$publication_root/staged-v1"
mkdir "$publish_target" "$publish_staged"
printf 'old\n' >"$publish_target/value"
printf 'new\n' >"$publish_staged/value"
host_toolchain_publish_version_directory \
  "$publish_staged" "$publish_target" 'fixture tool'
[[ $(<"$publish_target/value") == new ]] || {
  printf 'error: staged version directory was not published\n' >&2
  exit 1
}
compgen -G "$publish_target.invalid.*" >/dev/null || {
  printf 'error: replaced version directory was not retained recoverably\n' >&2
  exit 1
}

rollback_target="$publication_root/rollback-v1"
mkdir "$rollback_target"
printf 'rollback\n' >"$rollback_target/value"
/usr/bin/mv --no-target-directory -- \
  "$rollback_target" "$rollback_target.previous"
host_toolchain_reconcile_version_directory "$rollback_target" 'rollback fixture'
[[ $(<"$rollback_target/value") == rollback && \
   ! -e "$rollback_target.previous" ]] || {
  printf 'error: interrupted version replacement was not rolled back\n' >&2
  exit 1
}

committed_target="$publication_root/committed-v1"
mkdir "$committed_target" "$committed_target.previous"
printf 'new\n' >"$committed_target/value"
printf 'old\n' >"$committed_target.previous/value"
host_toolchain_reconcile_version_directory "$committed_target" 'commit fixture'
[[ $(<"$committed_target/value") == new && \
   ! -e "$committed_target.previous" ]] || {
  printf 'error: committed version replacement was not reconciled\n' >&2
  exit 1
}
compgen -G "$committed_target.invalid.*" >/dev/null || {
  printf 'error: reconciled previous version was not retained\n' >&2
  exit 1
}

link_path="$publication_root/tool"
/usr/bin/ln -s old-target "$link_path"
host_toolchain_replace_symlink_atomic new-target "$link_path" 'fixture tool'
[[ $(/usr/bin/readlink -- "$link_path") == new-target && \
   ! -e "$publication_root/.tool.next" && \
   ! -L "$publication_root/.tool.next" ]] || {
  printf 'error: convenience link replacement was not atomic\n' >&2
  exit 1
}
/usr/bin/ln -s stale-target "$publication_root/.tool.next"
host_toolchain_replace_symlink_atomic final-target "$link_path" 'fixture tool'
[[ $(/usr/bin/readlink -- "$link_path") == final-target ]] || {
  printf 'error: stale temporary convenience link was not reconciled\n' >&2
  exit 1
}

unsafe_link="$publication_root/unsafe-link"
printf 'preserve\n' >"$unsafe_link"
expect_failure unsafe-link 'convenience path is not a symlink' \
  host_toolchain_replace_symlink_atomic target "$unsafe_link" 'unsafe fixture'
[[ $(<"$unsafe_link") == preserve ]] || {
  printf 'error: unsafe convenience path was overwritten\n' >&2
  exit 1
}

grep -Fq 'PLATFORM_TOOLS_ADB_SHA256' "$project_root/scripts/install-host-deps.sh"
grep -Fq 'PLATFORM_TOOLS_ADB_SHA256' "$project_root/scripts/check-host.sh"
grep -Fq 'host_toolchain_verify_zip_tree' "$project_root/scripts/check-host.sh"
grep -Fq 'exec {toolchain_lock_fd}' "$project_root/scripts/install-host-deps.sh"
grep -Fq 'host_toolchain_stage_yarn' "$project_root/scripts/install-host-deps.sh"
if grep -Fq 'npm-cli.js' "$project_root/scripts/install-host-deps.sh"; then
  printf 'error: host installer must not execute npm to stage Yarn\n' >&2
  exit 1
fi

printf 'host-toolchain integrity simulation passed\n'
