#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh disable=SC1091
source "$script_dir/lib/common.sh"
# shellcheck source=lib/cubs-dexpreopt.sh disable=SC1091
source "$script_dir/lib/cubs-dexpreopt.sh"
# shellcheck source=lib/cubs-fstab.sh disable=SC1091
source "$script_dir/lib/cubs-fstab.sh"
# shellcheck source=lib/cubs-wifi-vintf.sh disable=SC1091
source "$script_dir/lib/cubs-wifi-vintf.sh"
# shellcheck source=lib/gsi-static-layout.sh disable=SC1091
source "$script_dir/lib/gsi-static-layout.sh"
# shellcheck source=lib/cubs-vendor-boot.sh disable=SC1091
source "$script_dir/lib/cubs-vendor-boot.sh"

require_pixel_target cubs "the legacy GSI/Cubs static validator"

usage() {
  local status=${1:-2}
  cat >&2 <<EOF
usage: $0 gsi|cubs|all

Read-only static validation of completed local flash bundles and the build
outputs that produced them. This script never contacts or writes a device.
EOF
  exit "$status"
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage 0
fi
[[ $# -eq 1 ]] || usage
selection=$1
case "$selection" in
  gsi|cubs|all) ;;
  *) usage ;;
esac

require_command \
  awk cat cmp cp date debugfs dump.erofs e2fsck find fsck.erofs grep jq ln lz4 \
  mkdir mktemp od realpath rm sed sha256sum sort stat strings tr \
  sha1sum unlink unzip wc xxd

source_dir=${AOSP_SOURCE_DIR:-"$project_root/work/aosp"}
source_dir=$(realpath -m -- "$source_dir")
gsi_out=${AOSP_OUT_DIR:-"$source_dir/out_pixel/gsi"}
cubs_out=${DEVICE_OUT_DIR:-"$source_dir/out_pixel/cubs"}
gsi_out=$(realpath -m -- "$gsi_out")
cubs_out=$(realpath -m -- "$cubs_out")
assert_inside_project "$source_dir"
assert_inside_project "$gsi_out"
assert_inside_project "$cubs_out"

scratch_parent="$project_root/work/static-validation"
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/.validate.XXXXXX")
cleanup() {
  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" && \
        "$scratch_dir" == "$scratch_parent"/.validate.* ]]; then
    rm -rf -- "$scratch_dir"
  fi
}
trap cleanup EXIT

cubs_firmware_partitions=(
  abl
  bl31
  cap
  cpm
  dbc
  dbl
  dram_init_0
  dram_init_1
  dram_init_2
  dram_init_3
  dram_init_4
  dram_init_5
  dram_init_6
  dram_init_7
  dram_init_8
  dram_init_9
  dram_init_10
  dram_init_11
  dram_phy
  gc
  gdmc
  gsa_bl1
  gsa_fw
  tzsw
  modem
)
cubs_firmware_images=()
for partition in "${cubs_firmware_partitions[@]}"; do
  cubs_firmware_images+=("$partition.img")
done
cubs_firmware_descriptor_partitions=(
  abl
  bl31
  cap
  cpm
  dbc
  dbl
  dram_init_0
  dram_init_1
  dram_init_10
  dram_init_11
  dram_init_2
  dram_init_3
  dram_init_4
  dram_init_5
  dram_init_6
  dram_init_7
  dram_init_8
  dram_init_9
  dram_phy
  gc
  gdmc
  gsa_bl1
  gsa_fw
  tzsw
)
cubs_firmware_carrier_images=()
for partition in "${cubs_firmware_descriptor_partitions[@]}"; do
  cubs_firmware_carrier_images+=("${partition}_vbfooted.img")
done
cubs_all_images=(
  "${cubs_firmware_images[@]}"
  boot.img init_boot.img dtbo.img vendor_boot.img vendor_kernel_boot.img
  pvmfw.img vbmeta.img vbmeta_system.img vbmeta_vendor.img
  system.img system_dlkm.img system_ext.img product.img vendor.img
  vendor_dlkm.img
)

hash_file() {
  local digest
  [[ -f "$1" && ! -L "$1" && -s "$1" ]] || \
    die "missing, empty, or unsafe regular file: $1"
  digest=$(sha256sum -- "$1")
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash $1"
  printf '%s\n' "$digest"
}

literal_sha256() {
  local digest
  digest=$(printf '%s' "$1" | sha256sum)
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash release identity"
  printf '%s\n' "$digest"
}

require_zip_entry_once() {
  local archive=$1
  local entry=$2
  local count
  count=$(unzip -Z1 "$archive" | grep -Fxc -- "$entry" || true)
  (( count == 1 )) || \
    die "expected exactly one $entry entry in $archive; found $count"
}

zip_entry_hash() {
  local archive=$1
  local entry=$2
  local digest
  require_zip_entry_once "$archive" "$entry"
  digest=$(unzip -p "$archive" "$entry" | sha256sum)
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "failed to hash $entry from $archive"
  printf '%s\n' "$digest"
}

load_exact_kv() {
  local path=$1
  local output_name=$2
  shift 2
  local -n output=$output_name
  local -A allowed=()
  local key line value
  local count=0

  output=()
  for key in "$@"; do
    allowed["$key"]=1
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != *$'\r'* && "$line" == *=* ]] || \
      die "malformed key/value line in $path"
    key=${line%%=*}
    value=${line#*=}
    [[ "$key" =~ ^[a-z0-9_]+$ && -n "$value" ]] || \
      die "malformed key/value entry in $path: $key"
    [[ -n "${allowed[$key]+present}" ]] || \
      die "unexpected key in $path: $key"
    [[ -z "${output[$key]+present}" ]] || \
      die "duplicate key in $path: $key"
    output["$key"]=$value
    ((count += 1))
  done < "$path"
  (( count == $# )) || die "$path does not contain its exact key allowlist"
  for key in "$@"; do
    [[ -n "${output[$key]+present}" ]] || die "$path is missing $key"
  done
}

require_value() {
  local actual=$1
  local expected=$2
  local description=$3
  [[ "$actual" == "$expected" ]] || \
    die "$description mismatch: expected $expected, found $actual"
}

normalized_words() {
  tr ' ' '\n' <<<"$1" | sed '/^$/d' | LC_ALL=C sort -u | tr '\n' ' ' | \
    sed 's/ $//'
}

require_word_set() {
  local actual expected
  actual=$(normalized_words "$1")
  expected=$(normalized_words "$2")
  [[ "$actual" == "$expected" ]] || \
    die "$3 mismatch: expected {$expected}, found {$actual}"
}

avb_metadata_value() {
  local info=$1
  local expression=$2
  local description=$3
  local -a values=()
  mapfile -t values < <(sed -n "$expression" "$info")
  (( ${#values[@]} == 1 )) || \
    die "$description must occur exactly once in AVB metadata"
  printf '%s\n' "${values[0]}"
}

firmware_hash_descriptor_value() {
  local info=$1
  local field=$2
  local description=$3
  local -a values=()
  mapfile -t values < <(
    awk -v field="$field" '
      / descriptor:$/ {
        in_hash = ($0 ~ /^[[:space:]]+Hash descriptor:$/)
        next
      }
      in_hash {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (index(line, field ":") == 1) {
          sub(/^[^:]*:[[:space:]]*/, "", line)
          print line
        }
      }
    ' "$info"
  )
  (( ${#values[@]} == 1 )) || \
    die "$description must occur exactly once in the carrier hash descriptor"
  printf '%s\n' "${values[0]}"
}

validate_vbmeta_firmware_carrier_args() {
  local misc=$1
  local args token basename
  local index
  local -a values=()
  local -a tokens=()
  local -a actual=()

  mapfile -t values < <(sed -n 's/^avb_vbmeta_args=//p' <<<"$misc")
  (( ${#values[@]} == 1 )) || \
    die "target-files must contain exactly one avb_vbmeta_args setting"
  args=${values[0]}
  read -r -a tokens <<<"$args"
  for ((index = 0; index < ${#tokens[@]}; index += 1)); do
    token=${tokens[$index]}
    [[ "$token" == --include_descriptors_from_image ]] || continue
    (( index + 1 < ${#tokens[@]} )) || \
      die "avb_vbmeta_args has an unterminated descriptor-carrier argument"
    ((index += 1))
    basename=${tokens[$index]##*/}
    [[ "$basename" =~ ^[a-z0-9_]+_vbfooted\.img$ ]] || \
      die "avb_vbmeta_args references an unsafe firmware descriptor carrier"
    actual+=("$basename")
  done
  (( ${#actual[@]} == ${#cubs_firmware_carrier_images[@]} )) && \
    [[ "${actual[*]}" == "${cubs_firmware_carrier_images[*]}" ]] || \
    die "avb_vbmeta_args does not include the exact ordered firmware descriptor-carrier set"
}

reject_firmware_carrier_leaks() {
  local listing=$1
  local destination=$2
  local entry basename
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    basename=${entry##*/}
    [[ ! "$basename" =~ ^[a-z0-9_]+_vbfooted\.img$ ]] || \
      die "$destination leaks firmware descriptor carrier $basename"
  done <<<"$listing"
}

derive_firmware_carrier_salt() {
  local build_number_file="$cubs_out/soong/build_number.txt"
  local build_date_file="$cubs_out/build_date.txt"
  local build_number_hash build_date_hash

  build_number_hash=$(hash_file "$build_number_file")
  build_date_hash=$(hash_file "$build_date_file")
  require_value "$build_number_hash" "$(literal_sha256 "$AOSP_BUILD_NUMBER")" \
    "cubs build-number file bytes"
  require_value "$build_date_hash" "$(literal_sha256 "$AOSP_BUILD_DATETIME")" \
    "cubs build-date file bytes"
  printf '%s%s\n' "$build_number_hash" "$build_date_hash"
}

validate_firmware_carrier() {
  local partition=$1
  local raw=$2
  local carrier=$3
  local expected_salt=$4
  local info=$5
  local verify_log=$6
  local raw_size carrier_size expected_carrier_size expected_digest digest
  local descriptor_count hash_descriptor_count

  raw_size=$(stat -c '%s' "$raw")
  carrier_size=$(stat -c '%s' "$carrier")
  (( raw_size > 0 )) || die "empty raw firmware image for $partition"
  expected_carrier_size=$((
    69632 + ((raw_size + 4095) / 4096) * 4096
  ))
  (( carrier_size == expected_carrier_size )) || die \
    "$partition descriptor carrier size mismatch: expected $expected_carrier_size, found $carrier_size"
  cmp -n "$raw_size" -s -- "$raw" "$carrier" || die \
    "$partition descriptor carrier does not preserve the raw firmware prefix"

  "${avbtool_command[@]}" info_image --image "$carrier" >"$info" || \
    die "$partition descriptor carrier has invalid AVB metadata"
  descriptor_count=$(grep -Ec \
    '^[[:space:]]+[^[:space:]].* descriptor:$' "$info" || true)
  hash_descriptor_count=$(grep -Ec \
    '^[[:space:]]+Hash descriptor:$' "$info" || true)
  (( descriptor_count == 1 && hash_descriptor_count == 1 )) || die \
    "$partition descriptor carrier must contain exactly one hash descriptor"
  require_value "$(avb_metadata_value "$info" \
      's/^Algorithm:[[:space:]]*//p' "$partition carrier algorithm")" \
    NONE "$partition carrier algorithm"
  require_value "$(avb_metadata_value "$info" \
      's/^Rollback Index:[[:space:]]*//p' "$partition carrier rollback index")" \
    0 "$partition carrier rollback index"
  require_value "$(avb_metadata_value "$info" \
      's/^Flags:[[:space:]]*//p' "$partition carrier flags")" \
    0 "$partition carrier flags"
  require_value "$(avb_metadata_value "$info" \
      's/^Image size:[[:space:]]*\([0-9][0-9]*\) bytes$/\1/p' \
      "$partition carrier image size")" \
    "$carrier_size" "$partition carrier footer size"
  require_value "$(avb_metadata_value "$info" \
      's/^Original image size:[[:space:]]*\([0-9][0-9]*\) bytes$/\1/p' \
      "$partition carrier original size")" \
    "$raw_size" "$partition carrier original size"
  require_value "$(firmware_hash_descriptor_value "$info" "Image Size" \
      "$partition descriptor image size")" \
    "$raw_size bytes" "$partition descriptor image size"
  require_value "$(firmware_hash_descriptor_value "$info" "Hash Algorithm" \
      "$partition descriptor hash algorithm")" \
    sha256 "$partition descriptor hash algorithm"
  require_value "$(firmware_hash_descriptor_value "$info" "Partition Name" \
      "$partition descriptor partition name")" \
    "$partition" "$partition descriptor partition name"
  require_value "$(firmware_hash_descriptor_value "$info" Salt \
      "$partition descriptor salt")" \
    "$expected_salt" "$partition descriptor salt"
  require_value "$(firmware_hash_descriptor_value "$info" Flags \
      "$partition descriptor flags")" \
    0 "$partition descriptor flags"

  expected_digest=$(
    { printf '%s' "$expected_salt" | xxd -r -p; cat -- "$raw"; } | \
      sha256sum
  )
  expected_digest=${expected_digest%% *}
  digest=$(firmware_hash_descriptor_value "$info" Digest \
    "$partition descriptor digest")
  require_value "$digest" "$expected_digest" "$partition descriptor digest"
  if ! "${avbtool_command[@]}" verify_image --image "$carrier" \
      >"$verify_log" 2>&1; then
    sed -n '1,120p' "$verify_log" >&2
    die "$partition descriptor carrier failed AVB hash verification"
  fi
}

kv_from_text() {
  local text=$1
  local key=$2
  local count value
  count=$(grep -c "^${key}=" <<<"$text" || true)
  (( count == 1 )) || die "expected exactly one $key entry; found $count"
  value=$(sed -n "s/^${key}=//p" <<<"$text")
  [[ -n "$value" ]] || die "empty $key value"
  printf '%s\n' "$value"
}

magic_at() {
  local path=$1
  local offset=$2
  local count=$3
  od -An -tx1 -j "$offset" -N "$count" -v "$path" | tr -d ' \n'
}

validate_partition_capacity() {
  local path=$1
  local capacity=$2
  local description=$3
  local size
  size=$(stat -c '%s' "$path")
  (( size > 0 && size <= capacity )) || \
    die "$description exceeds its $capacity-byte partition capacity"
  (( size % 4096 == 0 )) || \
    die "$description is not aligned to a 4 KiB AVB block"
}

u32_le_at() {
  local -a byte=()
  read -r -a byte < <(od -An -tx1 -j "$2" -N 4 -v "$1")
  (( ${#byte[@]} == 4 )) || die "short read from $1 at offset $2"
  printf '%u\n' "$((
    (16#${byte[3]} << 24) | (16#${byte[2]} << 16) |
    (16#${byte[1]} << 8) | 16#${byte[0]}
  ))"
}

u32_be_at() {
  local -a byte=()
  read -r -a byte < <(od -An -tx1 -j "$2" -N 4 -v "$1")
  (( ${#byte[@]} == 4 )) || die "short read from $1 at offset $2"
  printf '%u\n' "$((
    (16#${byte[0]} << 24) | (16#${byte[1]} << 16) |
    (16#${byte[2]} << 8) | 16#${byte[3]}
  ))"
}

u64_le_at() {
  local -a byte=()
  local value=0 index
  read -r -a byte < <(od -An -tx1 -j "$2" -N 8 -v "$1")
  (( ${#byte[@]} == 8 )) || die "short read from $1 at offset $2"
  for ((index = 7; index >= 0; index -= 1)); do
    value=$(( (value << 8) | 16#${byte[index]} ))
  done
  printf '%u\n' "$value"
}

declare -A raw_image=()
declare -A image_fs=()
declare -A expanded_size=()
declare -A cubs_attested_target_hash=()
declare -a simg2img_command=(simg2img)

prepare_filesystem_image() {
  local kind=$1
  local name=$2
  local path=$3
  local allowed_fs=$4
  local container first_magic raw raw_size block_size total_blocks expected_size
  local fs_magic ext_magic check_log

  first_magic=$(magic_at "$path" 0 4)
  if [[ "$first_magic" == 3aff26ed ]]; then
    container=sparse
    block_size=$(u32_le_at "$path" 12)
    total_blocks=$(u32_le_at "$path" 16)
    (( block_size >= 4096 && block_size <= 1048576 && \
       (block_size & (block_size - 1)) == 0 && total_blocks > 0 )) || \
      die "$name has an invalid Android sparse header"
    expected_size=$((block_size * total_blocks))
    raw="$scratch_dir/$kind-${name%.img}.raw.img"
    "${simg2img_command[@]}" "$path" "$raw" >/dev/null
    raw_size=$(stat -c '%s' "$raw")
    (( raw_size == expected_size )) || \
      die "$name sparse expansion size does not match its header"
  else
    container=raw
    raw=$path
    raw_size=$(stat -c '%s' "$raw")
  fi
  (( raw_size > 0 && raw_size % 4096 == 0 )) || \
    die "$name expanded size is not positive and 4 KiB aligned"

  fs_magic=$(magic_at "$raw" 1024 4)
  ext_magic=$(magic_at "$raw" 1080 2)
  if [[ "$fs_magic" == e2e1f5e0 ]]; then
    image_fs["$kind/$name"]=erofs
    check_log="$scratch_dir/$kind-${name%.img}.fsck-erofs.log"
    if ! fsck.erofs -d0 "$raw" >"$check_log" 2>&1; then
      sed -n '1,160p' "$check_log" >&2
      die "$name failed read-only EROFS integrity checking"
    fi
  elif [[ "$ext_magic" == 53ef ]]; then
    image_fs["$kind/$name"]=ext4
    check_log="$scratch_dir/$kind-${name%.img}.e2fsck.log"
    if ! e2fsck -f -n "$raw" >"$check_log" 2>&1; then
      sed -n '1,160p' "$check_log" >&2
      die "$name failed read-only ext4 integrity checking"
    fi
  else
    die "$name is neither an EROFS nor ext4 filesystem image after expansion"
  fi
  case ",${allowed_fs}," in
    *,"${image_fs[$kind/$name]}",*) ;;
    *) die "$name uses disallowed filesystem ${image_fs[$kind/$name]}" ;;
  esac

  raw_image["$kind/$name"]=$raw
  expanded_size["$kind/$name"]=$raw_size
  note "$kind $name: $container ${image_fs[$kind/$name]}, expanded bytes $raw_size"
}

extract_build_prop() {
  local kind=$1
  local name=$2
  local raw=${raw_image[$kind/$name]}
  local fs=${image_fs[$kind/$name]}
  local destination=$3
  local candidate attempt
  local -a candidates=(/build.prop /system/build.prop /system/system/build.prop)

  for candidate in "${candidates[@]}"; do
    attempt="$scratch_dir/$kind-${name%.img}-$(tr '/' '_' <<<"$candidate").prop"
    if [[ "$fs" == erofs ]]; then
      if dump.erofs --cat --path="$candidate" "$raw" >"$attempt" 2>/dev/null && \
          grep -qE '^[a-zA-Z0-9_.-]+=' "$attempt"; then
        cp -- "$attempt" "$destination"
        return 0
      fi
    elif debugfs -R "cat $candidate" "$raw" >"$attempt" 2>/dev/null && \
        grep -qE '^[a-zA-Z0-9_.-]+=' "$attempt"; then
      cp -- "$attempt" "$destination"
      return 0
    fi
  done
  die "could not extract build.prop from $name"
}

require_prop() {
  grep -Eq "$2" "$1" || die "$3 is absent from image build properties"
}

require_exact_prop_value() {
  local property_file=$1
  local property_name=$2
  local expected=$3
  local description=$4
  local -a values=()
  mapfile -t values < <(
    awk -v key="$property_name" \
      'index($0, key "=") == 1 {print substr($0, length(key) + 2)}' \
      "$property_file"
  )
  (( ${#values[@]} == 1 )) || \
    die "$description must occur exactly once"
  require_value "${values[0]}" "$expected" "$description"
}

declare -a avbtool_command=()
declare -a unpack_bootimg_command=()
expected_avb_rsa2048_sha1=
expected_avb_rsa4096_sha1=

derive_avb_public_key_sha1() {
  local bits=$1
  local key="$source_dir/external/avb/test/data/testkey_rsa$bits.pem"
  local public_key="$scratch_dir/expected-testkey-rsa$bits.avbpubkey"
  local digest
  [[ -f "$key" && ! -L "$key" && -s "$key" ]] || \
    die "pinned AOSP RSA-$bits AVB test key is missing or unsafe"
  "${avbtool_command[@]}" extract_public_key --key "$key" \
    --output "$public_key"
  digest=$(sha1sum -- "$public_key")
  digest=${digest%% *}
  [[ "$digest" =~ ^[0-9a-f]{40}$ ]] || \
    die "failed to identify pinned AOSP RSA-$bits AVB test key"
  printf '%s\n' "$digest"
}

select_aosp_tools() {
  local out_dir=$1
  local avbtool="$out_dir/host/linux-x86/bin/avbtool"
  local simg2img="$out_dir/host/linux-x86/bin/simg2img"
  local unpack_bootimg="$out_dir/host/linux-x86/bin/unpack_bootimg"

  [[ -f "$avbtool" && ! -L "$avbtool" && -x "$avbtool" ]] || \
    die "built avbtool is missing or unsafe: $avbtool"
  avbtool_command=("$avbtool")
  expected_avb_rsa2048_sha1=$(derive_avb_public_key_sha1 2048)
  expected_avb_rsa4096_sha1=$(derive_avb_public_key_sha1 4096)
  [[ -f "$simg2img" && ! -L "$simg2img" && -x "$simg2img" ]] || \
    die "built simg2img is missing or unsafe: $simg2img"
  simg2img_command=("$simg2img")
  if [[ -f "$unpack_bootimg" && ! -L "$unpack_bootimg" && \
        -x "$unpack_bootimg" ]]; then
    unpack_bootimg_command=("$unpack_bootimg")
  else
    require_command python3
    require_file "$source_dir/system/tools/mkbootimg/unpack_bootimg.py"
    unpack_bootimg_command=(
      python3 "$source_dir/system/tools/mkbootimg/unpack_bootimg.py"
    )
  fi
}

avb_info() {
  local image=$1
  local output=$2
  "${avbtool_command[@]}" info_image --image "$image" >"$output"
  grep -q '^Algorithm:' "$output" || die "incomplete AVB metadata for $image"
  grep -Eq '^Rollback Index:[[:space:]]+[0-9]+$' "$output" || \
    die "invalid AVB rollback index in $image"
  grep -Eq '^Algorithm:[[:space:]]+[^N]' "$output" || \
    die "unsigned AVB metadata in $image"
  grep -Eq '^Public key \(sha1\):[[:space:]]+[0-9a-f]{40}$' "$output" || \
    die "invalid AVB public-key identifier in $image"
}

verify_standalone_avb_image() {
  local image=$1
  local label=$2
  local info="$scratch_dir/$label-standalone-avb.info"
  local log="$scratch_dir/$label-standalone-avb-verify.log"
  avb_info "$image" "$info"
  if ! "${avbtool_command[@]}" verify_image --image "$image" \
      >"$log" 2>&1; then
    sed -n '1,160p' "$log" >&2
    die "$label AVB footer/signature/hash verification failed"
  fi
}

validate_pvmfw_avb_identity() {
  local image=$1
  local label=$2
  local info="$scratch_dir/$label-standalone-avb.info"
  local key="$source_dir/external/avb/test/data/testkey_rsa4096.pem"
  local expected_salt
  local hash_descriptor_count
  local -a partitions=()
  local -a salts=()

  expected_salt=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  verify_standalone_avb_image "$image" "$label"
  [[ $(awk '/^Algorithm:/ {print $2}' "$info") == SHA256_RSA4096 ]] || \
    die "$label uses an unexpected AVB algorithm"
  hash_descriptor_count=$(grep -c '^    Hash descriptor:$' "$info" || true)
  (( hash_descriptor_count == 1 )) || \
    die "$label must contain exactly one AVB hash descriptor"
  mapfile -t partitions < <(
    sed -n 's/^[[:space:]]*Partition Name:[[:space:]]*//p' "$info"
  )
  (( ${#partitions[@]} == 1 )) && [[ "${partitions[0]}" == pvmfw ]] || \
    die "$label has an unexpected AVB partition descriptor"
  mapfile -t salts < <(
    sed -n 's/^[[:space:]]*Salt:[[:space:]]*//p' "$info"
  )
  (( ${#salts[@]} == 1 )) && [[ "${salts[0]}" == "$expected_salt" ]] || \
    die "$label has an unexpected AVB hash salt"
  [[ -f "$key" && ! -L "$key" && -s "$key" ]] || \
    die "pinned pvmfw AVB signing key is missing or unsafe"
  "${avbtool_command[@]}" verify_image --image "$image" --key "$key" \
    >/dev/null || die "$label is not signed by the pinned RSA-4096 key"
}

descriptor_partitions() {
  sed -n 's/^[[:space:]]*Partition Name:[[:space:]]*//p' "$1"
}

hashtree_records() {
  awk '
    /Hashtree descriptor:/ { in_tree=1; name=""; hash=""; next }
    in_tree && /Partition Name:/ {
      name=$0
      sub(/^[[:space:]]*Partition Name:[[:space:]]*/, "", name)
    }
    in_tree && /Hash Algorithm:/ {
      hash=$0
      sub(/^[[:space:]]*Hash Algorithm:[[:space:]]*/, "", hash)
    }
    in_tree && name != "" && hash != "" {
      print name ":" hash
      in_tree=0
    }
  ' "$1"
}

require_exact_descriptor_partitions() {
  local info=$1
  local description=$2
  shift 2
  local partition
  local -a expected=("$@")
  local -a actual=()
  mapfile -t actual < <(descriptor_partitions "$info")
  for partition in "${actual[@]}"; do
    [[ "$partition" =~ ^[a-z0-9_]+$ ]] || \
      die "unsafe partition name in $description: $partition"
  done
  (( ${#actual[@]} == ${#expected[@]} )) || \
    die "$description descriptor count mismatch"
  require_word_set "$(printf '%s ' "${actual[@]}")" \
    "$(printf '%s ' "${expected[@]}")" "$description descriptors"
}

chain_records() {
  awk '
    /Chain Partition descriptor:/ { in_chain=1; name=""; location=""; next }
    in_chain && /Partition Name:/ {
      name=$0; sub(/^[[:space:]]*Partition Name:[[:space:]]*/, "", name); next
    }
    in_chain && /Rollback Index Location:/ {
      location=$0
      sub(/^[[:space:]]*Rollback Index Location:[[:space:]]*/, "", location)
      print name ":" location
      in_chain=0
    }
  ' "$1"
}

validate_avb_graph() {
  local kind=$1
  local bundle=$2
  local supplemental_zip=${3:-}
  shift 3
  local -a images=("$@")
  local graph="$scratch_dir/$kind-avb-graph"
  local info_root="$scratch_dir/$kind-vbmeta.info"
  local image_name info path partition entry_count rollback algorithm flags
  local public_key
  local chain_partition record expected_rollback
  local queue_index=0
  local -a descriptors=()
  local -a chains=()
  local -a reachable_queue=(vbmeta)
  local -A covered=()
  local -A chain_location=()
  local -A reachable_queued=([vbmeta]=1)

  mkdir -p "$graph"
  for image_name in "${images[@]}"; do
    ln -s -- "$bundle/$image_name" "$graph/$image_name"
  done

  avb_info "$bundle/vbmeta.img" "$info_root"
  rollback=$(sed -n 's/^Rollback Index:[[:space:]]*//p' "$info_root")
  algorithm=$(sed -n 's/^Algorithm:[[:space:]]*//p' "$info_root")
  flags=$(sed -n 's/^Flags:[[:space:]]*//p' "$info_root")
  public_key=$(sed -n 's/^Public key (sha1):[[:space:]]*//p' "$info_root")
  [[ "$rollback" =~ ^[0-9]+$ && -n "$algorithm" && "$algorithm" != NONE ]] || \
    die "$kind root vbmeta has invalid signing or rollback metadata"
  [[ "$flags" =~ ^[0-9]+$ ]] || die "$kind root vbmeta has invalid flags"
  require_value "$algorithm" SHA256_RSA4096 "$kind root vbmeta algorithm"
  require_value "$public_key" "$expected_avb_rsa4096_sha1" \
    "$kind root vbmeta public key"
  (( flags == 0 )) || die "$kind root vbmeta must not set AVB disable flags"
  if [[ "$kind" == gsi ]]; then
    (( rollback == 0 )) || die "GSI root vbmeta rollback index must be zero"
  else
    expected_rollback=$(date -u -d "$AOSP_SECURITY_PATCH 00:00:00" +%s)
    (( rollback == expected_rollback )) || die \
      "cubs root vbmeta rollback index does not match $AOSP_SECURITY_PATCH"
  fi

  mapfile -t chains < <(chain_records "$info_root" | LC_ALL=C sort -u)
  if [[ "$kind" == gsi ]]; then
    (( ${#chains[@]} == 1 )) && [[ ${chains[0]} == system:1 ]] || \
      die "GSI root vbmeta must contain exactly the system rollback-location-1 chain"
  else
    (( ${#chains[@]} == 4 )) || \
      die "cubs root vbmeta must contain exactly four chain records"
    require_word_set "$(printf '%s ' "${chains[@]}")" \
      'boot:2 init_boot:4 vbmeta_system:1 vbmeta_vendor:3' \
      "cubs root vbmeta chains"
  fi

  # Walk only vbmeta objects reachable from the root chain. A valid footer on
  # an unrelated image must never count as root-of-trust coverage.
  while (( queue_index < ${#reachable_queue[@]} )); do
    partition=${reachable_queue[$queue_index]}
    ((queue_index += 1))
    if [[ "$partition" == vbmeta ]]; then
      info=$info_root
    else
      path="$graph/$partition.img"
      if [[ ! -e "$path" ]]; then
        [[ "$kind" == cubs && -n "$supplemental_zip" ]] || \
          die "AVB chain references an unavailable image: $partition.img"
        entry_count=$(unzip -Z1 "$supplemental_zip" | \
          grep -Fxc -- "$partition.img" || true)
        (( entry_count == 1 )) || die \
          "AVB chain requires $partition.img, absent from reconstructed image ZIP"
        unzip -p "$supplemental_zip" "$partition.img" > "$path"
        [[ -s "$path" ]] || \
          die "empty supplemental AVB chain image: $partition.img"
      fi
      info="$scratch_dir/$kind-reachable-$partition.avb-info"
      avb_info "$path" "$info"
    fi

    while IFS= read -r chain_partition; do
      [[ "$chain_partition" =~ ^[a-z0-9_]+$ ]] || \
        die "unsafe partition name in reachable AVB metadata: $chain_partition"
      covered["$chain_partition"]=1
      descriptors+=("$chain_partition")
    done < <(descriptor_partitions "$info")

    while IFS= read -r record; do
      chain_partition=${record%%:*}
      rollback=${record#*:}
      [[ "$chain_partition" =~ ^[a-z0-9_]+$ && \
         "$rollback" =~ ^[0-9]+$ ]] || \
        die "malformed reachable AVB chain descriptor: $record"
      (( rollback > 0 )) || \
        die "AVB chain $chain_partition uses rollback location zero"
      [[ -z "${chain_location[$rollback]+present}" ]] || \
        die "duplicate reachable AVB chain rollback location $rollback"
      chain_location["$rollback"]=$chain_partition
      if [[ -z "${reachable_queued[$chain_partition]+present}" ]]; then
        reachable_queued["$chain_partition"]=1
        reachable_queue+=("$chain_partition")
      fi
    done < <(chain_records "$info")
  done

  if [[ "$kind" == gsi ]]; then
    [[ -n "${covered[system]+present}" ]] || \
      die "GSI vbmeta metadata does not cover system"
  else
    for partition in \
      boot init_boot dtbo vendor_boot vendor_kernel_boot pvmfw \
      vbmeta_system vbmeta_vendor \
      system system_dlkm system_ext product vendor vendor_dlkm; do
      [[ -n "${covered[$partition]+present}" ]] || \
        die "cubs AVB graph does not cover $partition"
    done
  fi

  # Resolve any descriptor image not already present in the bundle from the
  # reconstructed target-files image ZIP. The exact 25 individually slotted
  # cubs firmware payloads are bundle members; aggregate bootloader/radio
  # containers remain excluded.
  mapfile -t descriptors < <(printf '%s\n' "${descriptors[@]}" | \
    sed '/^$/d' | LC_ALL=C sort -u)
  for partition in "${descriptors[@]}"; do
    [[ -e "$graph/$partition.img" ]] && continue
    [[ "$kind" == cubs && -n "$supplemental_zip" ]] || \
      die "AVB graph references an unavailable image: $partition.img"
    entry_count=$(unzip -Z1 "$supplemental_zip" | \
      grep -Fxc -- "$partition.img" || true)
    (( entry_count == 1 )) || die \
      "AVB graph requires $partition.img, absent from reconstructed image ZIP"
    unzip -p "$supplemental_zip" "$partition.img" \
      > "$graph/$partition.img"
    [[ -s "$graph/$partition.img" ]] || \
      die "empty supplemental AVB graph image: $partition.img"
  done

  note "verifying the complete $kind AVB signature/hash/hashtree graph"
  if ! "${avbtool_command[@]}" verify_image \
      --image "$graph/vbmeta.img" --follow_chain_partitions \
      >"$scratch_dir/$kind-avb-verify.log" 2>&1; then
    sed -n '1,240p' "$scratch_dir/$kind-avb-verify.log" >&2
    die "$kind AVB graph verification failed"
  fi
}

validate_gsi_system_avb_policy() {
  local bundle=$1
  local info="$scratch_dir/gsi-system-policy.avb-info"
  local algorithm rollback flags public_key expected_rollback prop_lines
  local -a trees=()

  avb_info "$bundle/system.img" "$info"
  algorithm=$(sed -n 's/^Algorithm:[[:space:]]*//p' "$info")
  rollback=$(sed -n 's/^Rollback Index:[[:space:]]*//p' "$info")
  flags=$(sed -n 's/^Flags:[[:space:]]*//p' "$info")
  public_key=$(sed -n 's/^Public key (sha1):[[:space:]]*//p' "$info")
  require_value "$algorithm" SHA256_RSA2048 \
    "GSI chained system AVB algorithm"
  require_value "$public_key" "$expected_avb_rsa2048_sha1" \
    "GSI chained system AVB public key"
  expected_rollback=$(date -u -d "$AOSP_SECURITY_PATCH 00:00:00" +%s)
  require_value "$rollback" "$expected_rollback" \
    "GSI chained system rollback index"
  require_value "$flags" 0 "GSI chained system AVB flags"
  mapfile -t trees < <(hashtree_records "$info")
  (( ${#trees[@]} == 1 )) && [[ ${trees[0]} == system:sha256 ]] || \
    die "GSI chained system must contain exactly one sha256 system hashtree"
  prop_lines=$(sed 's/^[[:space:]]*//' "$info")
  [[ $(grep -Fxc \
      "Prop: com.android.build.system.os_version -> '17'" \
      <<<"$prop_lines") -eq 1 ]] || \
    die "GSI system AVB metadata does not attest Android 17"
  [[ $(grep -Fxc \
      "Prop: com.android.build.system.security_patch -> '$AOSP_SECURITY_PATCH'" \
      <<<"$prop_lines") -eq 1 ]] || \
    die "GSI system AVB metadata does not attest $AOSP_SECURITY_PATCH"
}

validate_cubs_chained_avb_policy() {
  local bundle=$1
  local partition=$2
  shift 2
  local info="$scratch_dir/cubs-$partition-policy.avb-info"
  local algorithm rollback flags public_key expected_rollback

  avb_info "$bundle/$partition.img" "$info"
  algorithm=$(sed -n 's/^Algorithm:[[:space:]]*//p' "$info")
  rollback=$(sed -n 's/^Rollback Index:[[:space:]]*//p' "$info")
  flags=$(sed -n 's/^Flags:[[:space:]]*//p' "$info")
  public_key=$(sed -n 's/^Public key (sha1):[[:space:]]*//p' "$info")
  require_value "$algorithm" SHA256_RSA4096 \
    "cubs chained $partition AVB algorithm"
  require_value "$public_key" "$expected_avb_rsa4096_sha1" \
    "cubs chained $partition AVB public key"
  expected_rollback=$(date -u -d "$AOSP_SECURITY_PATCH 00:00:00" +%s)
  require_value "$rollback" "$expected_rollback" \
    "cubs chained $partition rollback index"
  require_value "$flags" 0 "cubs chained $partition AVB flags"
  require_exact_descriptor_partitions "$info" \
    "cubs chained $partition" "$@"
}

validate_cubs_fstab_avb_topology() {
  local root_info=$1
  local generated_root="$source_dir/vendor/google_devices/$DEVICE_CODENAME/proprietary"
  local generated_ramdisk_fstab="$generated_root/vendor_ramdisk/system/etc/fstab.malibu"
  local generated_vendor_fstab="$generated_root/vendor/etc/fstab.malibu"
  local target_ramdisk_fstab="$scratch_dir/cubs-target-vendor-ramdisk-fstab.malibu"
  local target_vendor_fstab="$scratch_dir/cubs-target-vendor-fstab.malibu"
  local entry path description index
  local root_chain_records
  local -a target_entries=(
    VENDOR_BOOT/RAMDISK/first_stage_ramdisk/system/etc/fstab.malibu
    VENDOR/etc/fstab.malibu
  )
  local -a target_paths=(
    "$target_ramdisk_fstab"
    "$target_vendor_fstab"
  )
  local -a fstabs=(
    "$generated_ramdisk_fstab"
    "$generated_vendor_fstab"
    "$target_ramdisk_fstab"
    "$target_vendor_fstab"
  )
  local -a descriptions=(
    "generated vendor-ramdisk fstab.malibu"
    "generated vendor fstab.malibu"
    "target-files vendor-ramdisk fstab.malibu"
    "target-files vendor fstab.malibu"
  )

  for index in "${!target_entries[@]}"; do
    entry=${target_entries[$index]}
    require_zip_entry_once "$target_files" "$entry"
    unzip -p "$target_files" "$entry" >"${target_paths[$index]}" || \
      die "failed to extract $entry from cubs target-files"
  done

  for index in "${!fstabs[@]}"; do
    path=${fstabs[$index]}
    description=${descriptions[$index]}
    verify_sha256 "$CUBS_CHAINED_AVB_FSTAB_SHA256" "$path"
    cubs_validate_fstab_avb_mapping "$path" chained "$description"
  done
  for path in \
      "$generated_vendor_fstab" \
      "$target_ramdisk_fstab" \
      "$target_vendor_fstab"; do
    cmp -s -- "$generated_ramdisk_fstab" "$path" || \
      die "generated and target-files cubs fstab.malibu copies differ"
  done

  root_chain_records=$(chain_records "$root_info")
  cubs_validate_fstab_against_root_chains \
    "$target_ramdisk_fstab" "$root_chain_records" \
    "target-files vendor-ramdisk fstab.malibu"
  note "cubs generated and target-files fstabs match the root AVB child chain"
}

validate_cubs_avb_policy() {
  local bundle=$1
  local info="$scratch_dir/cubs-root-policy.avb-info"
  local stock_image="$scratch_dir/pinned-stock-vbmeta.img"
  local stock_info="$scratch_dir/pinned-stock-vbmeta.avb-info"
  local partition count
  local -a chains=()
  local -a stock_partitions=()

  avb_info "$bundle/vbmeta.img" "$info"
  [[ -n "$stock_inner" ]] || \
    die "internal error: stock AVB topology was not initialized"
  require_zip_entry_once "$stock_inner" vbmeta.img
  unzip -p "$stock_inner" vbmeta.img > "$stock_image"
  [[ -s "$stock_image" ]] || die "pinned stock vbmeta image is empty"
  avb_info "$stock_image" "$stock_info"
  mapfile -t stock_partitions < <(descriptor_partitions "$stock_info")
  (( ${#stock_partitions[@]} > 8 )) || \
    die "pinned stock root vbmeta has an incomplete descriptor topology"
  require_exact_descriptor_partitions "$info" \
    "cubs root versus pinned stock topology" "${stock_partitions[@]}"
  mapfile -t chains < <(chain_records "$info" | LC_ALL=C sort -u)
  (( ${#chains[@]} == 4 )) || \
    die "cubs root vbmeta must contain exactly four chain records"
  require_word_set "$(printf '%s ' "${chains[@]}")" \
    'boot:2 init_boot:4 vbmeta_system:1 vbmeta_vendor:3' \
    "cubs root vbmeta chains"

  # Each chain target appears exactly once at root. Grouped payloads must not
  # also be duplicated into root vbmeta, while these stock-shaped boot support
  # descriptors stay root-direct.
  for partition in boot init_boot vbmeta_system vbmeta_vendor \
      dtbo vendor_boot vendor_kernel_boot vendor_dlkm; do
    count=$(descriptor_partitions "$info" | grep -Fxc -- "$partition" || true)
    (( count == 1 )) || \
      die "cubs root vbmeta must reference $partition exactly once"
  done
  for partition in pvmfw product system system_dlkm system_ext vendor; do
    count=$(descriptor_partitions "$info" | grep -Fxc -- "$partition" || true)
    (( count == 0 )) || \
      die "cubs root vbmeta duplicates child-group partition $partition"
  done

  # Stock root AVB directly authenticates 24 of the 25 bundled firmware
  # payloads. The modem payload is not in the stock descriptor topology, so it
  # is instead bound byte-for-byte to the checksum-pinned stock inner ZIP.
  for partition in "${cubs_firmware_partitions[@]}"; do
    count=$(descriptor_partitions "$info" | grep -Fxc -- "$partition" || true)
    if [[ "$partition" == modem ]]; then
      (( count == 0 )) || \
        die "cubs root vbmeta unexpectedly describes modem"
    else
      (( count == 1 )) || \
        die "cubs root vbmeta must describe firmware partition $partition exactly once"
    fi
  done

  validate_cubs_chained_avb_policy "$bundle" boot boot
  validate_cubs_chained_avb_policy "$bundle" init_boot init_boot
  validate_cubs_chained_avb_policy "$bundle" vbmeta_system \
    pvmfw product system system_dlkm system_ext
  validate_cubs_chained_avb_policy "$bundle" vbmeta_vendor vendor
  validate_cubs_fstab_avb_topology "$info"
}

validate_exact_bundle() {
  local kind=$1
  local bundle=$2
  shift 2
  local -a images=("$@")
  local -a expected=(
    BUILD_ATTESTATION.txt
    BUNDLE_INFO.txt
    SHA256SUMS
    bundle-kind
    firmware-requirements.txt
    flash-all.sh
    "${images[@]}"
  )
  local -a actual=()
  local -a expected_sorted=()
  local -a manifest_files=(
    BUILD_ATTESTATION.txt
    BUNDLE_INFO.txt
    bundle-kind
    firmware-requirements.txt
    flash-all.sh
    "${images[@]}"
  )
  local -A expected_manifest=()
  local -A seen=()
  local digest name extra image_name count=0

  [[ -d "$bundle" && ! -L "$bundle" ]] || \
    die "$kind bundle directory is missing or unsafe: $bundle"
  mapfile -t actual < <(
    find "$bundle" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort
  )
  mapfile -t expected_sorted < <(printf '%s\n' "${expected[@]}" | LC_ALL=C sort)
  [[ "${actual[*]}" == "${expected_sorted[*]}" ]] || {
    printf 'expected bundle files: %s\n' "${expected_sorted[*]}" >&2
    printf 'actual bundle files:   %s\n' "${actual[*]}" >&2
    die "$kind bundle does not match its exact file allowlist"
  }
  for name in "${expected[@]}"; do
    [[ -f "$bundle/$name" && ! -L "$bundle/$name" ]] || \
      die "unsafe bundle entry: $name"
  done
  [[ -x "$bundle/flash-all.sh" ]] || die "bundle flash-all.sh is not executable"
  cmp -s -- "$script_dir/flash-a.sh" "$bundle/flash-all.sh" || \
    die "bundle flash-all.sh differs from the reviewed source runner"

  for name in "${manifest_files[@]}"; do
    expected_manifest["$name"]=1
  done
  while read -r digest name extra; do
    [[ -n "$digest" && -n "$name" && -z "${extra:-}" ]] || \
      die "malformed checksum manifest in $kind bundle"
    name=${name#\*}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || \
      die "malformed SHA-256 for $name"
    [[ -n "${expected_manifest[$name]+present}" ]] || \
      die "unexpected file in $kind SHA256SUMS: $name"
    [[ -z "${seen[$name]+present}" ]] || \
      die "duplicate file in $kind SHA256SUMS: $name"
    seen["$name"]=1
    ((count += 1))
  done < "$bundle/SHA256SUMS"
  (( count == ${#manifest_files[@]} )) || \
    die "$kind SHA256SUMS does not cover its exact manifest allowlist"
  for name in "${manifest_files[@]}"; do
    [[ -n "${seen[$name]+present}" ]] || die "$kind SHA256SUMS omits $name"
  done
  (
    cd "$bundle"
    sha256sum --check --strict SHA256SUMS
  ) >/dev/null || die "$kind bundle checksum verification failed"
  for image_name in "${images[@]}"; do
    [[ -s "$bundle/$image_name" && ! -x "$bundle/$image_name" ]] || \
      die "empty or executable image in $kind bundle: $image_name"
  done
}

stock_validated=
stock_inner=
validate_stock_reference() {
  [[ -n "$stock_validated" ]] && return 0
  local factory="$project_root/downloads/$FACTORY_IMAGE_FILENAME"
  local stock_dir="$project_root/work/stock/${FACTORY_IMAGE_FILENAME%-factory-*}"
  local sentinel="$stock_dir/.pixel-aosp-complete"
  local outer_entry inner_expected inner_actual
  local -A sentinel_info=()

  verify_sha256 "$FACTORY_IMAGE_SHA256" "$factory"
  stock_inner="$stock_dir/image-${DEVICE_CODENAME}-${STOCK_BUILD_ID,,}.zip"
  [[ -f "$stock_inner" && ! -L "$stock_inner" ]] || \
    die "verified stock inner image archive is missing: $stock_inner"
  require_file "$sentinel"
  load_exact_kv "$sentinel" sentinel_info factory_sha256 inner_sha256
  require_value "${sentinel_info[factory_sha256]}" "$FACTORY_IMAGE_SHA256" \
    "stock extraction factory hash"
  inner_actual=$(hash_file "$stock_inner")
  require_value "$inner_actual" "${sentinel_info[inner_sha256]}" \
    "stock inner archive hash"
  outer_entry="${FACTORY_IMAGE_FILENAME%-factory-*}/$(basename -- "$stock_inner")"
  require_zip_entry_once "$factory" "$outer_entry"
  inner_expected=$(zip_entry_hash "$factory" "$outer_entry")
  require_value "$inner_actual" "$inner_expected" \
    "stock inner archive provenance"
  unzip -tq "$stock_inner" >/dev/null || die "invalid stock inner image ZIP"
  stock_validated=1
}

validate_firmware_requirements() {
  local requirements=$1
  local stock_info board bootloader baseband
  validate_stock_reference
  require_zip_entry_once "$stock_inner" android-info.txt
  stock_info=$(unzip -p "$stock_inner" android-info.txt)
  board=$(sed -n 's/^require board=//p' <<<"$stock_info")
  bootloader=$(sed -n 's/^require version-bootloader=//p' <<<"$stock_info")
  baseband=$(sed -n 's/^require version-baseband=//p' <<<"$stock_info")
  [[ "|$board|" == *"|$DEVICE_CODENAME|"* ]] || \
    die "pinned stock archive does not allow $DEVICE_CODENAME"
  [[ -n "$bootloader" && -n "$baseband" ]] || \
    die "pinned stock archive lacks firmware requirements"
  [[ $(wc -l < "$requirements") -eq 3 ]] || \
    die "firmware-requirements.txt must have exactly three lines"
  grep -Fxq "require product=$DEVICE_CODENAME" "$requirements" || \
    die "bundle product firmware requirement is wrong"
  grep -Fxq "require version-bootloader=$bootloader" "$requirements" || \
    die "bundle bootloader requirement differs from pinned stock"
  grep -Fxq "require version-baseband=$baseband" "$requirements" || \
    die "bundle baseband requirement differs from pinned stock"
}

validate_bundle_metadata() {
  local kind=$1
  local bundle=$2
  local out_dir=$3
  local -a keys=(
    bundle_kind device aosp_revision source_aosp_build_id output_build_id
    framework_security_patch build_variant
    stock_vendor_build platform_tools build_attestation_sha256
    flash_scope recovery_anchor
  )
  local -A info=()
  local marker="$out_dir/build-completion-$kind.attestation"
  local marker_hash

  if [[ "$kind" == gsi ]]; then
    keys+=(system_sha256)
  else
    keys+=(target_files_sha256 generated_images_zip_sha256)
  fi
  load_exact_kv "$bundle/BUNDLE_INFO.txt" info "${keys[@]}"
  require_value "${info[bundle_kind]}" "$kind" "bundle kind"
  require_value "${info[device]}" "$DEVICE_CODENAME" "bundle device"
  require_value "${info[aosp_revision]}" "$AOSP_REVISION" "AOSP revision"
  require_value "${info[source_aosp_build_id]}" "$AOSP_BUILD_ID" \
    "source AOSP build ID"
  if [[ "$kind" == gsi ]]; then
    require_value "${info[output_build_id]}" "$AOSP_BUILD_ID" \
      "GSI output build ID"
  else
    require_value "${info[output_build_id]}" "$STOCK_BUILD_ID" \
      "cubs stock-shaped output build ID"
  fi
  require_value "${info[framework_security_patch]}" "$AOSP_SECURITY_PATCH" \
    "framework security patch"
  require_value "${info[build_variant]}" userdebug "build variant"
  require_value "${info[stock_vendor_build]}" "$STOCK_BUILD_ID" \
    "stock vendor build"
  require_value "${info[platform_tools]}" "$PLATFORM_TOOLS_VERSION" \
    "Platform-Tools version"
  require_value "${info[flash_scope]}" \
    slot_a_partition_names_shared_super "flash scope"
  require_value "${info[recovery_anchor]}" \
    slot_b_physical_fastbootd_lifeboat "recovery anchor"
  [[ -f "$marker" && ! -L "$marker" ]] || \
    die "missing safe successful-build attestation: $marker"
  cmp -s -- "$marker" "$bundle/BUILD_ATTESTATION.txt" || \
    die "$kind bundle contains a stale or foreign successful-build attestation"
  marker_hash=$(hash_file "$bundle/BUILD_ATTESTATION.txt")
  require_value "${info[build_attestation_sha256]}" "$marker_hash" \
    "build attestation hash"

  # Copy out values needed after this local nameref's lifetime.
  current_system_sha256=${info[system_sha256]:-}
  current_target_files_sha256=${info[target_files_sha256]:-}
  current_generated_images_zip_sha256=${info[generated_images_zip_sha256]:-}
}

validate_strict_soong_policy() {
  local kind=$1
  local out_dir=$2
  local soong_variables=$3
  local soong_environment_used=$4
  local soong_product relative_out_dir expected_build_datetime_file

  if [[ "$kind" == gsi ]]; then
    soong_product=gsi_arm64
  else
    soong_product=$DEVICE_CODENAME
  fi
  jq -e --arg kind "$kind" '
    .Allow_missing_dependencies == false and
    .SelinuxIgnoreNeverallows == false and
    .Unbundled_build == false and
    .Unbundled_build_apps == [] and
    .Unbundled_build_image == false and
    .SanitizeHost == [] and
    .SanitizeDevice == (if $kind == "cubs" then ["memtag_heap"] else [] end) and
    .SanitizeDeviceDiag == [] and
    .SanitizeDeviceArch == [] and
    .GcovCoverage == false and
    .ClangCoverage == false and
    .ClangCoverageContinuousMode == false and
    .JavaCoveragePaths == [] and
    .JavaCoverageExcludePaths == [] and
    .NativeCoveragePaths == [] and
    .NativeCoverageExcludePaths == [] and
    .Debuggable == true and
    .Eng == false and
    .BuildType == "release" and
    .BuildBrokenPluginValidation == [] and
    .BuildBrokenClangProperty == false and
    .BuildBrokenClangAsFlags == false and
    .BuildBrokenClangCFlags == false and
    .BuildBrokenEnforceSyspropOwner == false and
    .BuildBrokenTrebleSyspropNeverallow == false and
    .BuildBrokenVendorPropertyNamespace == false and
    .BuildBrokenIncorrectPartitionImages == false and
    .BuildBrokenInputDirModules == [] and
    .BuildBrokenDontCheckSystemSdk == false and
    .BuildBrokenDupSysprop == false and
    .BuildBrokenPrebuiltELFFiles == false and
    .WithDexpreopt == true and
    .ClangTidy == false
  ' "$soong_variables" >/dev/null || \
    die "$kind output violates the independently checked strict Soong policy"

  relative_out_dir=$(realpath --relative-to="$source_dir" "$out_dir")
  [[ "$relative_out_dir" != ../* && "$relative_out_dir" != .. ]] || \
    die "$kind output directory is outside the AOSP source tree"
  expected_build_datetime_file="$relative_out_dir/build_date.txt"
  jq -e \
    --arg kind "$kind" \
    --arg product "$soong_product" \
    --arg out_dir "$relative_out_dir" \
    --arg build_datetime_file "$expected_build_datetime_file" \
    --arg build_number "$AOSP_BUILD_NUMBER" \
    --arg build_username "$AOSP_BUILD_USERNAME" \
    --arg build_hostname "$AOSP_BUILD_HOSTNAME" \
    --arg build_datetime "$AOSP_BUILD_DATETIME" '
    type == "array" and
    all(.[];
      type == "object" and
      (keys | sort) == ["Key", "Value"] and
      (.Key | type) == "string" and
      (.Value | type) == "string"
    ) and
    ((map(.Key) | length) == (map(.Key) | unique | length)) and
    all(.[];
      .Value == "" or
      (.Key == "ANDROID_JAVA8_HOME" and
        .Value == "prebuilts/jdk/jdk8/linux-x86") or
      (.Key == "ANDROID_JAVA_HOME" and
        .Value == "prebuilts/jdk/jdk21/linux-x86") or
      (.Key == "BUILD_DATETIME_FILE" and .Value == $build_datetime_file) or
      (.Key == "BUILD_DATETIME" and .Value == $build_datetime) or
      (.Key == "BUILD_HOSTNAME" and .Value == $build_hostname) or
      (.Key == "BUILD_NUMBER" and .Value == $build_number) or
      (.Key == "BUILD_USERNAME" and .Value == $build_username) or
      (.Key == "CC_WRAPPER" and .Value == "/usr/bin/ccache") or
      (.Key == "OUT_DIR" and .Value == $out_dir) or
      (.Key == "SOONG_GENERATES_NINJA_HINT" and .Value == "depend") or
      (.Key == "TARGET_PRODUCT" and .Value == $product) or
      (.Key == "TARGET_RELEASE" and .Value == "aosp_current") or
      (.Key == "USE_CCACHE" and (.Value == "0" or .Value == "1")) or
      (.Key == "USE_STOCK_KERNEL" and $kind == "cubs" and .Value == "true")
    )
  ' "$soong_environment_used" >/dev/null || \
    die "$kind output used an independently rejected build environment value"
}

validate_attestation() {
  local kind=$1
  local bundle=$2
  local out_dir=$3
  local marker="$bundle/BUILD_ATTESTATION.txt"
  local -a common_keys=(
    format kind source_lock_sha256 resolved_manifest_sha256 patch_lock_sha256
    base_revisions_sha256 release_env_sha256 target_release_env_sha256
    repo_revision aosp_revision source_aosp_build_id output_build_id
    framework_security_patch build_variant
    allow_missing_dependencies selinux_ignore_neverallows
    strict_build_policy soong_variables_sha256 soong_environment_used_sha256
    build_number build_username build_hostname build_datetime
    build_timezone build_locale system_build_prop_sha256
    target product
  )
  local -a keys=("${common_keys[@]}")
  local -A attest=()
  local image_name key digest soong_variables soong_environment_used
  local source_lock_actual
  local resolved_manifest_sha256 patch_lock_sha256
  local base_revisions_sha256 release_env_sha256 target_release_env_sha256
  local expected_boot_identity_salt

  if [[ "$kind" == gsi ]]; then
    keys+=(
      output_system_sha256 output_pvmfw_sha256 output_vbmeta_sha256
      host_avbtool_sha256
    )
  else
    keys+=(
      stock_vendor_build generated_vendor_attestation_sha256
      boot_identity_salt
      dexpreopt_config_sha256
      malibu_dexpreopt_semantic_config_sha256
      target_files_name target_files_sha256
      wifi_hostapd_vendor_manifest_sha256
      wifi_supplicant_vendor_manifest_sha256
      malibu_plugin_provider_jar_sha256
      malibu_plugin_provider_arm64_odex_sha256
      malibu_plugin_provider_arm64_vdex_sha256
      malibu_dexpreopt_invocation_sha256 cubs_host_oatdump_sha256
      malibu_target_classes_dex_crc32
      malibu_effective_class_loader_context_sha256
      malibu_oatdump_semantics_sha256
      output_boot_sha256 output_init_boot_sha256 output_dtbo_sha256
      output_vendor_boot_sha256 output_vendor_kernel_boot_sha256
      output_pvmfw_sha256 output_vbmeta_sha256
      host_img_from_target_files_sha256
      host_avbtool_sha256 host_check_target_files_vintf_sha256
      host_checkvintf_sha256
    )
  fi
  load_exact_kv "$marker" attest "${keys[@]}"
  require_value "${attest[format]}" pixel-aosp-build-completion-v1 \
    "build attestation format"
  require_value "${attest[kind]}" "$kind" "attested build kind"
  resolved_manifest_sha256=$(hash_file "$project_root/manifests/resolved.xml")
  patch_lock_sha256=$(hash_file "$project_root/patches/SHA256SUMS")
  base_revisions_sha256=$(hash_file "$project_root/patches/BASE_REVISIONS")
  release_env_sha256=$(hash_file "$project_root/config/release.env")
  target_release_env_sha256=$(hash_file \
    "$project_root/config/targets/$DEVICE_CODENAME/release.env")
  require_value "${attest[resolved_manifest_sha256]}" \
    "$resolved_manifest_sha256" "attested resolved-manifest hash"
  require_value "${attest[patch_lock_sha256]}" "$patch_lock_sha256" \
    "attested patch-lock hash"
  require_value "${attest[base_revisions_sha256]}" \
    "$base_revisions_sha256" "attested base-revision-lock hash"
  require_value "${attest[release_env_sha256]}" "$release_env_sha256" \
    "attested release-configuration hash"
  require_value "${attest[target_release_env_sha256]}" \
    "$target_release_env_sha256" "attested target release-configuration hash"
  source_lock_actual=$(
    {
      printf 'resolved_manifest_sha256=%s\n' "$resolved_manifest_sha256"
      printf 'patch_lock_sha256=%s\n' "$patch_lock_sha256"
      printf 'base_revisions_sha256=%s\n' "$base_revisions_sha256"
      printf 'release_env_sha256=%s\n' "$release_env_sha256"
      printf 'target_release_env_sha256=%s\n' "$target_release_env_sha256"
    } | sha256sum
  )
  source_lock_actual=${source_lock_actual%% *}
  require_value "${attest[source_lock_sha256]}" "$source_lock_actual" \
    "attested source-closure hash"
  require_value "${attest[aosp_revision]}" "$AOSP_REVISION" \
    "attested AOSP revision"
  require_value "${attest[repo_revision]}" "$REPO_REVISION" \
    "attested Repo implementation revision"
  require_value "${attest[source_aosp_build_id]}" "$AOSP_BUILD_ID" \
    "attested source AOSP build ID"
  require_value "${attest[framework_security_patch]}" "$AOSP_SECURITY_PATCH" \
    "attested framework security patch"
  require_value "${attest[build_variant]}" userdebug \
    "attested build variant"
  require_value "${attest[allow_missing_dependencies]}" false \
    "attested missing-dependency relaxation policy"
  require_value "${attest[selinux_ignore_neverallows]}" false \
    "attested SELinux neverallow policy"
  require_value "${attest[strict_build_policy]}" true \
    "attested strict build policy"
  if [[ "$kind" == gsi ]]; then
    soong_variables="$out_dir/soong/soong.gsi_arm64.variables"
    soong_environment_used="$out_dir/soong/soong.environment.used.gsi_arm64.build"
  else
    soong_variables="$out_dir/soong/soong.$DEVICE_CODENAME.variables"
    soong_environment_used="$out_dir/soong/soong.environment.used.$DEVICE_CODENAME.build"
  fi
  require_value "${attest[soong_variables_sha256]}" \
    "$(hash_file "$soong_variables")" "attested Soong variables hash"
  require_value "${attest[soong_environment_used_sha256]}" \
    "$(hash_file "$soong_environment_used")" \
    "attested Soong consumed-environment hash"
  validate_strict_soong_policy "$kind" "$out_dir" "$soong_variables" \
    "$soong_environment_used"
  require_value "${attest[build_number]}" "$AOSP_BUILD_NUMBER" \
    "attested deterministic build number"
  require_value "${attest[build_username]}" "$AOSP_BUILD_USERNAME" \
    "attested deterministic build username"
  require_value "${attest[build_hostname]}" "$AOSP_BUILD_HOSTNAME" \
    "attested deterministic build hostname"
  require_value "${attest[build_datetime]}" "$AOSP_BUILD_DATETIME" \
    "attested deterministic build timestamp"
  require_value "${attest[build_timezone]}" "$AOSP_BUILD_TIMEZONE" \
    "attested deterministic build timezone"
  require_value "${attest[build_locale]}" "$AOSP_BUILD_LOCALE" \
    "attested deterministic build locale"
  require_value "${attest[system_build_prop_sha256]}" \
    "$(hash_file "$out_dir/soong/.intermediates/build/soong/system-build.prop/android_common/build.prop")" \
    "attested system build-property hash"
  if [[ "$kind" == gsi ]]; then
    require_value "${attest[output_build_id]}" "$AOSP_BUILD_ID" \
      "attested GSI output build ID"
    require_value "${attest[target]}" gsi_arm64-aosp_current-userdebug \
      "attested GSI target"
    require_value "${attest[product]}" generic_arm64 \
      "attested GSI product"
    for image_name in system.img pvmfw.img vbmeta.img; do
      key=output_${image_name%.img}_sha256
      digest=$(hash_file "$bundle/$image_name")
      require_value "${attest[$key]}" "$digest" \
        "attested GSI $image_name hash"
    done
    require_value "${attest[host_avbtool_sha256]}" \
      "$(hash_file "$out_dir/host/linux-x86/bin/avbtool")" \
      "attested avbtool hash"
  else
    local product_out="$out_dir/target/product/$DEVICE_CODENAME"
    local dexpreopt_config="$out_dir/soong/dexpreopt-$DEVICE_CODENAME.config"
    local malibu_semantic_config="$project_root/config/cubs-dexpreopt.env"
    validate_cubs_wifi_vintf_soong_installs "$source_dir" "$out_dir"
    require_value "${attest[output_build_id]}" "$STOCK_BUILD_ID" \
      "attested cubs stock-shaped output build ID"
    require_value "${attest[target]}" \
      "${DEVICE_CODENAME}-aosp_current-userdebug" "attested cubs target"
    require_value "${attest[product]}" "$DEVICE_CODENAME" \
      "attested cubs product"
    require_value "${attest[stock_vendor_build]}" "$STOCK_BUILD_ID" \
      "attested stock vendor build"
    validate_cubs_dexpreopt_config "$dexpreopt_config"
    require_value "${attest[dexpreopt_config_sha256]}" \
      "$(hash_file "$dexpreopt_config")" \
      "attested cubs dexpreopt-configuration hash"
    require_value "${attest[malibu_dexpreopt_semantic_config_sha256]}" \
      "$(hash_file "$malibu_semantic_config")" \
      "attested cubs Malibu dexpreopt semantic-policy hash"
    require_value "${attest[host_avbtool_sha256]}" \
      "$(hash_file "$out_dir/host/linux-x86/bin/avbtool")" \
      "attested avbtool hash"
    require_value "${attest[host_img_from_target_files_sha256]}" \
      "$(hash_file "$out_dir/host/linux-x86/bin/img_from_target_files")" \
      "attested img_from_target_files hash"
    for key in check_target_files_vintf checkvintf; do
      [[ -x "$out_dir/host/linux-x86/bin/$key" && \
         ! -L "$out_dir/host/linux-x86/bin/$key" ]] || \
        die "attested VINTF checker is missing or unsafe: $key"
      require_value "${attest[host_${key}_sha256]}" \
        "$(hash_file "$out_dir/host/linux-x86/bin/$key")" \
        "attested $key hash"
    done
    expected_boot_identity_salt="$(
      hash_file "$out_dir/soong/build_number.txt"
    )$(
      hash_file "$out_dir/build_date.txt"
    )"
    require_value "${attest[boot_identity_salt]}" \
      "$expected_boot_identity_salt" "attested boot-image identity salt"
    cubs_attested_target_hash=()
    for image_name in \
        boot.img init_boot.img dtbo.img vendor_boot.img \
        vendor_kernel_boot.img; do
      key=output_${image_name%.img}_sha256
      digest=$(hash_file "$product_out/$image_name")
      require_value "${attest[$key]}" "$digest" \
        "attested current cubs product-output $image_name hash"
      cubs_attested_target_hash["$image_name"]=${attest[$key]}
    done
    cubs_attested_target_hash[pvmfw.img]=${attest[output_pvmfw_sha256]}
    cubs_attested_target_hash[vbmeta.img]=${attest[output_vbmeta_sha256]}
    current_malibu_plugin_provider_jar_sha256=${attest[malibu_plugin_provider_jar_sha256]}
    current_malibu_plugin_provider_arm64_odex_sha256=${attest[malibu_plugin_provider_arm64_odex_sha256]}
    current_malibu_plugin_provider_arm64_vdex_sha256=${attest[malibu_plugin_provider_arm64_vdex_sha256]}
    current_malibu_dexpreopt_invocation_sha256=${attest[malibu_dexpreopt_invocation_sha256]}
    current_cubs_host_oatdump_sha256=${attest[cubs_host_oatdump_sha256]}
    current_malibu_target_classes_dex_crc32=${attest[malibu_target_classes_dex_crc32]}
    current_malibu_effective_class_loader_context_sha256=${attest[malibu_effective_class_loader_context_sha256]}
    current_malibu_oatdump_semantics_sha256=${attest[malibu_oatdump_semantics_sha256]}
    current_wifi_hostapd_vendor_manifest_sha256=${attest[wifi_hostapd_vendor_manifest_sha256]}
    current_wifi_supplicant_vendor_manifest_sha256=${attest[wifi_supplicant_vendor_manifest_sha256]}
  fi
  current_attestation_target_files_name=${attest[target_files_name]:-}
  current_attestation_target_files_sha256=${attest[target_files_sha256]:-}
  current_system_build_prop_sha256=${attest[system_build_prop_sha256]}
}

validate_gsi() {
  local bundle=${GSI_ARTIFACT_DIR:-"$project_root/artifacts/gsi"}
  local product_out="$gsi_out/target/product/generic_arm64"
  local -a images=(system.img pvmfw.img vbmeta.img)
  local image_name digest prop_file info patch_month

  bundle=$(realpath -m -- "$bundle")
  assert_inside_project "$bundle"
  validate_exact_bundle gsi "$bundle" "${images[@]}"
  "$script_dir/attest-build-output.sh" verify gsi
  validate_bundle_metadata gsi "$bundle" "$gsi_out"
  validate_attestation gsi "$bundle" "$gsi_out"
  validate_firmware_requirements "$bundle/firmware-requirements.txt"
  select_aosp_tools "$gsi_out"

  for image_name in "${images[@]}"; do
    digest=$(hash_file "$product_out/$image_name")
    require_value "$digest" "$(hash_file "$bundle/$image_name")" \
      "GSI product-output $image_name hash"
  done
  require_value "$current_system_sha256" "$(hash_file "$bundle/system.img")" \
    "GSI system image metadata hash"
  validate_partition_capacity "$bundle/vbmeta.img" 65536 "GSI vbmeta.img"

  prepare_filesystem_image gsi system.img "$bundle/system.img" ext4
  validate_gsi_static_layout \
    "$bundle/system.img" "$scratch_dir" \
    "$AOSP_BUILD_ID" "$AOSP_BUILD_NUMBER"
  prop_file="$scratch_dir/gsi-system-build.prop"
  extract_build_prop gsi system.img "$prop_file"
  require_value "$(hash_file "$prop_file")" \
    "$current_system_build_prop_sha256" \
    "GSI system-image build-property hash"
  require_prop "$prop_file" '^ro\.(system\.)?build\.type=userdebug$' \
    "GSI userdebug identity"
  require_prop "$prop_file" '^ro\.(system\.)?build\.version\.sdk=37$' \
    "GSI Android SDK 37 identity"
  require_prop "$prop_file" '^ro\.(system\.)?build\.version\.release=17$' \
    "GSI Android 17 identity"
  require_prop "$prop_file" \
    "^ro\\.(system\\.)?build\\.id=${AOSP_BUILD_ID//./\\.}$" \
    "GSI stable release build ID"
  require_prop "$prop_file" \
    "^ro\\.(system\\.)?build\\.version\\.security_patch=${AOSP_SECURITY_PATCH}$" \
    "GSI source security patch"
  require_prop "$prop_file" '^ro\.(system\.)?build\.tags=test-keys$' \
    "GSI userdebug signing tags"

  [[ $(magic_at "$bundle/pvmfw.img" 0 8) == 414e44524f494421 ]] || \
    die "GSI pvmfw.img is not an Android boot image"
  validate_partition_capacity "$bundle/pvmfw.img" 1048576 \
    "GSI pvmfw.img"
  mkdir -p "$scratch_dir/gsi-pvmfw"
  "${unpack_bootimg_command[@]}" --boot_img "$bundle/pvmfw.img" \
    --out "$scratch_dir/gsi-pvmfw" >"$scratch_dir/gsi-pvmfw.info"
  grep -qx 'boot image header version: 3' "$scratch_dir/gsi-pvmfw.info" || \
    die "GSI pvmfw.img does not use boot header v3"
  grep -qx 'os version: 17.0.0' "$scratch_dir/gsi-pvmfw.info" || \
    die "GSI pvmfw.img does not identify Android 17"
  patch_month=${AOSP_SECURITY_PATCH%-*}
  grep -qx "os patch level: $patch_month" "$scratch_dir/gsi-pvmfw.info" || \
    die "GSI pvmfw.img security-patch month is wrong"
  validate_pvmfw_avb_identity "$bundle/pvmfw.img" gsi-pvmfw

  validate_gsi_system_avb_policy "$bundle"
  validate_avb_graph gsi "$bundle" "" "${images[@]}"
  info="$scratch_dir/gsi-vbmeta.info"
  avb_info "$bundle/vbmeta.img" "$info"
  note "GSI static image validation passed"
}

locate_cubs_target_files() {
  local root="$cubs_out/target/product/$DEVICE_CODENAME/obj/PACKAGING/target_files_intermediates"
  local candidate digest
  local -a candidates=()
  [[ -d "$root" && ! -L "$root" ]] || die "cubs target-files directory is missing"
  root=$(realpath -e -- "$root")
  if [[ -n "${CUBS_TARGET_FILES:-}" ]]; then
    [[ -f "$CUBS_TARGET_FILES" && ! -L "$CUBS_TARGET_FILES" ]] || \
      die "CUBS_TARGET_FILES is not a safe regular file"
    target_files=$(realpath -e -- "$CUBS_TARGET_FILES")
    case "$target_files" in
      "$root"/*) ;;
      *) die "CUBS_TARGET_FILES must be inside the current cubs output tree" ;;
    esac
    candidates=("$target_files")
  else
    mapfile -t candidates < <(
      find "$root" -type f -name "$current_attestation_target_files_name" \
        -print | LC_ALL=C sort
    )
  fi
  target_files=
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" && ! -L "$candidate" ]] || continue
    digest=$(hash_file "$candidate")
    if [[ "$digest" == "$current_target_files_sha256" && \
          "$digest" == "$current_attestation_target_files_sha256" ]]; then
      [[ -z "$target_files" ]] || \
        die "multiple target-files packages match the cubs attestation"
      target_files=$candidate
    fi
  done
  [[ -n "$target_files" ]] || \
    die "no target-files package matches the completed cubs bundle"
  require_value "${target_files##*/}" "$current_attestation_target_files_name" \
    "attested target-files name"
  unzip -tq "$target_files" >/dev/null || die "invalid cubs target-files ZIP"
}

validate_cubs_dexpreopt_attestation() {
  local product_out="$cubs_out/target/product/$DEVICE_CODENAME"
  local source_jar="$source_dir/vendor/google_devices/$DEVICE_CODENAME/proprietary/system_ext/framework/malibu-plugin-provider.jar"
  local artifact_scratch="$scratch_dir/cubs-malibu-plugin-provider.artifact"
  local semantic_scratch="$scratch_dir/cubs-malibu-plugin-provider.oatdump"
  local semantic_config="$project_root/config/cubs-dexpreopt.env"
  local intermediate="$cubs_out/soong/.intermediates/vendor/google_devices/$DEVICE_CODENAME/proprietary/malibu-plugin-provider/android_common"
  local product_framework="$product_out/system_ext/framework"
  local -A hashes=()
  local -A semantics=()
  validate_cubs_standalone_dexpreopt \
    "$target_files" "$product_out" "$source_jar" "$artifact_scratch" hashes
  require_value "${hashes[malibu_plugin_provider_jar_sha256]}" \
    "$current_malibu_plugin_provider_jar_sha256" \
    "attested malibu-plugin-provider.jar hash"
  require_value "${hashes[malibu_plugin_provider_arm64_odex_sha256]}" \
    "$current_malibu_plugin_provider_arm64_odex_sha256" \
    "attested malibu-plugin-provider arm64 odex hash"
  require_value "${hashes[malibu_plugin_provider_arm64_vdex_sha256]}" \
    "$current_malibu_plugin_provider_arm64_vdex_sha256" \
    "attested malibu-plugin-provider arm64 vdex hash"
  validate_cubs_malibu_dexpreopt_semantics \
    "$intermediate/dexpreopt/malibu-plugin-provider/oat/arm64/javalib.invocation" \
    "$cubs_out/host/linux-x86/bin/oatdump" \
    "$product_framework/malibu-plugin-provider.jar" \
    "$product_framework/oat/arm64/malibu-plugin-provider.odex" \
    "$product_framework/oat/arm64/malibu-plugin-provider.vdex" \
    "$semantic_scratch" "$semantic_config" semantics
  require_value "${semantics[malibu_dexpreopt_invocation_sha256]}" \
    "$current_malibu_dexpreopt_invocation_sha256" \
    "attested Malibu dexpreopt invocation hash"
  require_value "${semantics[cubs_host_oatdump_sha256]}" \
    "$current_cubs_host_oatdump_sha256" "attested cubs oatdump hash"
  require_value "${semantics[malibu_target_classes_dex_crc32]}" \
    "$current_malibu_target_classes_dex_crc32" \
    "attested Malibu target classes.dex CRC32"
  require_value \
    "${semantics[malibu_effective_class_loader_context_sha256]}" \
    "$current_malibu_effective_class_loader_context_sha256" \
    "attested Malibu checksum-bearing class-loader-context hash"
  require_value "${semantics[malibu_oatdump_semantics_sha256]}" \
    "$current_malibu_oatdump_semantics_sha256" \
    "attested Malibu normalized oatdump-semantics hash"
  note "cubs standalone system_server JAR and arm64 dexpreopt artifacts and semantics match their attestation"
}

validate_cubs_wifi_vintf_attestation() {
  local -A hashes=()
  validate_cubs_wifi_vintf_target_files "$target_files" hashes
  require_value "${hashes[wifi_hostapd_vendor_manifest_sha256]}" \
    "$current_wifi_hostapd_vendor_manifest_sha256" \
    "attested cubs hostapd vendor-manifest hash"
  require_value "${hashes[wifi_supplicant_vendor_manifest_sha256]}" \
    "$current_wifi_supplicant_vendor_manifest_sha256" \
    "attested cubs supplicant vendor-manifest hash"
  note "cubs Wi-Fi VINTF fragments have single AOSP-owned install and target-files provenance"
}

validate_target_files_metadata() {
  local misc system_props entry prefix prop_file type_line image_name index=0
  local partition
  local ab_partitions_text
  local -a prop_entries=()
  local -a actual_ab_partitions=()
  local -a actual_ab_partitions_sorted=()
  local -a expected_ab_partitions=()
  local -a canonical_entries=(
    SYSTEM/build.prop
    PRODUCT/etc/build.prop
    SYSTEM_EXT/etc/build.prop
    SYSTEM_DLKM/etc/build.prop
    VENDOR/build.prop
    VENDOR_DLKM/etc/build.prop
  )
  local -A canonical_prefix=(
    [SYSTEM/build.prop]=system
    [PRODUCT/etc/build.prop]=product
    [SYSTEM_EXT/etc/build.prop]=system_ext
    [SYSTEM_DLKM/etc/build.prop]=system_dlkm
    [VENDOR/build.prop]=vendor
    [VENDOR_DLKM/etc/build.prop]=vendor_dlkm
  )
  local -A canonical_device=(
    [SYSTEM/build.prop]=generic
    [PRODUCT/etc/build.prop]="$DEVICE_CODENAME"
    [SYSTEM_EXT/etc/build.prop]="$DEVICE_CODENAME"
    [SYSTEM_DLKM/etc/build.prop]="$DEVICE_CODENAME"
    [VENDOR/build.prop]="$DEVICE_CODENAME"
    [VENDOR_DLKM/etc/build.prop]="$DEVICE_CODENAME"
  )
  require_zip_entry_once "$target_files" META/misc_info.txt
  misc=$(unzip -p "$target_files" META/misc_info.txt)
  require_value "$(kv_from_text "$misc" ab_update)" true "A/B update setting"
  require_value "$(kv_from_text "$misc" use_dynamic_partitions)" true \
    "dynamic partition setting"
  require_value "$(kv_from_text "$misc" avb_enable)" true "AVB setting"
  validate_vbmeta_firmware_carrier_args "$misc"
  require_value "$(kv_from_text "$misc" vintf_enforce)" true \
    "target-files VINTF enforcement setting"
  require_value "$(kv_from_text "$misc" super_partition_size)" 10737418240 \
    "cubs super partition size"
  require_value "$(kv_from_text "$misc" super_block_devices)" super \
    "cubs super block-device list"
  require_value "$(kv_from_text "$misc" super_super_device_size)" 10737418240 \
    "cubs super block-device size"
  require_word_set "$(kv_from_text "$misc" super_partition_groups)" \
    google_dynamic_partitions "cubs dynamic partition group"
  require_value \
    "$(kv_from_text "$misc" super_google_dynamic_partitions_group_size)" \
    10733223936 "cubs dynamic group size"
  require_word_set "$(kv_from_text "$misc" dynamic_partition_list)" \
    'system system_dlkm system_ext product vendor vendor_dlkm' \
    "cubs dynamic partition list"
  require_word_set \
    "$(kv_from_text "$misc" super_google_dynamic_partitions_partition_list)" \
    'system system_dlkm system_ext product vendor vendor_dlkm' \
    "cubs dynamic group membership"
  if grep -q '^super_partition_error_limit=' <<<"$misc"; then
    require_value "$(kv_from_text "$misc" super_partition_error_limit)" \
      10213130240 "cubs super partition error limit"
  fi

  require_zip_entry_once "$target_files" META/ab_partitions.txt
  ab_partitions_text=$(unzip -p "$target_files" META/ab_partitions.txt)
  while IFS= read -r partition || [[ -n "$partition" ]]; do
    [[ "$partition" =~ ^[a-z0-9_]+$ ]] || \
      die "malformed partition in target-files META/ab_partitions.txt"
    actual_ab_partitions+=("$partition")
  done <<<"$ab_partitions_text"
  for image_name in "${cubs_all_images[@]}"; do
    expected_ab_partitions+=("${image_name%.img}")
  done
  mapfile -t actual_ab_partitions_sorted < <(
    printf '%s\n' "${actual_ab_partitions[@]}" | LC_ALL=C sort
  )
  mapfile -t expected_ab_partitions < <(
    printf '%s\n' "${expected_ab_partitions[@]}" | LC_ALL=C sort
  )
  (( ${#actual_ab_partitions[@]} == ${#expected_ab_partitions[@]} )) && \
    [[ "${actual_ab_partitions_sorted[*]}" == \
       "${expected_ab_partitions[*]}" ]] || \
    die "target-files A/B partition manifest does not match the exact 40-image cubs set"

  mapfile -t prop_entries < <(
    unzip -Z1 "$target_files" | awk '/(^|\/)build\.prop$/ {print}' | \
      LC_ALL=C sort
  )
  (( ${#prop_entries[@]} > 0 )) || die "target-files has no build properties"
  # Reject every explicitly declared non-userdebug partition property, not
  # merely the first aggregate match.
  for entry in "${prop_entries[@]}"; do
    prop_file="$scratch_dir/cubs-build-prop-scan-$index"
    ((index += 1))
    unzip -p "$target_files" "$entry" > "$prop_file"
    while IFS= read -r type_line; do
      [[ ${type_line#*=} == userdebug ]] || \
        die "$entry contains non-userdebug build identity: $type_line"
    done < <(
      grep -E '^ro\.([^.]+\.)?build\.type=' "$prop_file" || true
    )
  done

  for entry in "${canonical_entries[@]}"; do
    require_zip_entry_once "$target_files" "$entry"
    prefix=${canonical_prefix[$entry]}
    prop_file="$scratch_dir/cubs-$prefix-build.prop"
    unzip -p "$target_files" "$entry" > "$prop_file"
    require_exact_prop_value "$prop_file" "ro.$prefix.build.type" userdebug \
      "$prefix partition build type"
    require_exact_prop_value "$prop_file" "ro.$prefix.build.version.sdk" 37 \
      "$prefix partition SDK"
    require_exact_prop_value "$prop_file" \
      "ro.$prefix.build.version.release" 17 \
      "$prefix partition Android release"
    require_exact_prop_value "$prop_file" "ro.$prefix.build.id" \
      "$STOCK_BUILD_ID" "$prefix partition build ID"
    require_exact_prop_value "$prop_file" "ro.$prefix.build.tags" test-keys \
      "$prefix partition build tags"
    require_exact_prop_value "$prop_file" "ro.product.$prefix.device" \
      "${canonical_device[$entry]}" "$prefix partition product device"
    if [[ "$entry" == SYSTEM/build.prop ]]; then
      system_props=$prop_file
    fi
  done

  require_value "$(hash_file "$system_props")" \
    "$current_system_build_prop_sha256" \
    "target-files SYSTEM/build.prop hash"
  require_exact_prop_value "$system_props" ro.build.id "$STOCK_BUILD_ID" \
    "target-files top-level build ID"
  require_exact_prop_value "$system_props" ro.build.type userdebug \
    "target-files top-level build type"
  require_exact_prop_value "$system_props" ro.build.version.sdk 37 \
    "target-files top-level SDK"
  require_exact_prop_value "$system_props" ro.build.version.release 17 \
    "target-files top-level Android release"
  require_exact_prop_value "$system_props" ro.build.version.security_patch \
    "$AOSP_SECURITY_PATCH" "target-files framework security patch"
  require_exact_prop_value "$system_props" ro.build.tags test-keys \
    "target-files top-level build tags"
}

validate_target_files_vbmeta_digest() {
  local bundle=$1
  local digest_file="$scratch_dir/cubs-vbmeta-digest.txt"
  local recorded_digest calculated_digest byte_count

  require_zip_entry_once "$target_files" META/vbmeta_digest.txt
  unzip -p "$target_files" META/vbmeta_digest.txt > "$digest_file" || \
    die "failed to read target-files META/vbmeta_digest.txt"
  byte_count=$(wc -c < "$digest_file")
  (( byte_count == 65 )) || \
    die "target-files META/vbmeta_digest.txt is not canonical lowercase SHA-256 plus LF"
  recorded_digest=$(< "$digest_file")
  [[ "$recorded_digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "target-files META/vbmeta_digest.txt is not canonical lowercase SHA-256 plus LF"

  calculated_digest=$(
    "${avbtool_command[@]}" calculate_vbmeta_digest \
      --image "$bundle/vbmeta.img"
  ) || die "failed to calculate the packaged cubs vbmeta graph digest"
  [[ "$calculated_digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "calculated cubs vbmeta graph digest is not lowercase SHA-256"
  require_value "$recorded_digest" "$calculated_digest" \
    "target-files META/vbmeta_digest.txt versus packaged AVB graph"
  note "target-files vbmeta digest matches the packaged AVB graph"
}

reproduce_cubs_images_zip() {
  local tool="$cubs_out/host/linux-x86/bin/img_from_target_files"
  local digest
  [[ -f "$tool" && ! -L "$tool" && -x "$tool" ]] || \
    die "built img_from_target_files is missing or unsafe: $tool"
  reproduced_images_zip="$scratch_dir/cubs-images.zip"
  note "reconstructing the image ZIP to reject stale or mixed cubs outputs"
  if ! "$tool" "$target_files" "$reproduced_images_zip" \
      >"$scratch_dir/img-from-target-files.log" 2>&1; then
    sed -n '1,200p' "$scratch_dir/img-from-target-files.log" >&2
    die "img_from_target_files reconstruction failed"
  fi
  unzip -tq "$reproduced_images_zip" >/dev/null || \
    die "reconstructed cubs image ZIP is invalid"
  digest=$(hash_file "$reproduced_images_zip")
  require_value "$digest" "$current_generated_images_zip_sha256" \
    "reconstructed cubs image ZIP hash"
}

validate_cubs_firmware_provenance() {
  local source_firmware_dir=
  local image_name source_hash target_hash reconstructed_hash bundle_hash
  local stock_hash forbidden_image forbidden_count partition raw_image
  local carrier_image carrier_salt carrier_dir
  local -a expected_source_images=(
    bootloader.img
    radio.img
    "${cubs_firmware_images[@]}"
  )
  local -a expected_source_images_sorted=()
  local -a actual_source_images=()
  local -a expected_radio_entries=()
  local -a actual_radio_entries=()
  local -a reconstructed_entries=()

  [[ -n "$stock_inner" ]] || \
    die "internal error: pinned stock archive was not initialized"
  source_firmware_dir="$source_dir/vendor/google_devices/$DEVICE_CODENAME/firmware"
  [[ -d "$source_firmware_dir" && ! -L "$source_firmware_dir" ]] || \
    die "generated cubs firmware source directory is missing or unsafe"

  mapfile -t expected_source_images_sorted < <(
    printf '%s\n' "${expected_source_images[@]}" | LC_ALL=C sort
  )
  mapfile -t actual_source_images < <(
    find "$source_firmware_dir" -mindepth 1 -maxdepth 1 -type f \
      -name '*.img' -printf '%f\n' | LC_ALL=C sort
  )
  [[ "${actual_source_images[*]}" == \
     "${expected_source_images_sorted[*]}" ]] || \
    die "generated cubs firmware source does not match its exact image allowlist"

  mapfile -t expected_radio_entries < <(
    printf 'RADIO/%s\n' \
      "${expected_source_images[@]}" "${cubs_firmware_carrier_images[@]}" | \
      LC_ALL=C sort
  )
  mapfile -t actual_radio_entries < <(
    unzip -Z1 "$target_files" | \
      awk '/^RADIO\/[^/]+\.img$/ {print}' | LC_ALL=C sort
  )
  [[ "${actual_radio_entries[*]}" == \
     "${expected_radio_entries[*]}" ]] || \
    die "target-files RADIO directory does not match the exact raw and descriptor-carrier allowlist"

  mapfile -t reconstructed_entries < <(unzip -Z1 "$reproduced_images_zip")
  for forbidden_image in \
      bootloader.img radio.img "${cubs_firmware_carrier_images[@]}"; do
    forbidden_count=$(printf '%s\n' "${reconstructed_entries[@]}" | \
      grep -Fxc -- "$forbidden_image" || true)
    (( forbidden_count == 0 )) || \
      die "reconstructed image ZIP contains target-files-only $forbidden_image"
    [[ ! -e "$bundle/$forbidden_image" && ! -L "$bundle/$forbidden_image" ]] || \
      die "cubs bundle contains target-files-only $forbidden_image"
  done
  reject_firmware_carrier_leaks \
    "$(printf '%s\n' "${reconstructed_entries[@]}")" \
    "reconstructed image ZIP"

  carrier_salt=$(derive_firmware_carrier_salt)
  [[ "$carrier_salt" =~ ^[0-9a-f]{128}$ ]] || \
    die "failed to derive the cubs firmware descriptor-carrier salt"
  carrier_dir="$scratch_dir/cubs-firmware-descriptor-carriers"
  mkdir -p "$carrier_dir"
  for partition in "${cubs_firmware_descriptor_partitions[@]}"; do
    raw_image="$carrier_dir/$partition.img"
    carrier_image="$carrier_dir/${partition}_vbfooted.img"
    unzip -p "$target_files" "RADIO/$partition.img" >"$raw_image"
    unzip -p "$target_files" "RADIO/${partition}_vbfooted.img" \
      >"$carrier_image"
    [[ -s "$raw_image" && -s "$carrier_image" ]] || \
      die "empty raw image or descriptor carrier for $partition"
    validate_firmware_carrier \
      "$partition" "$raw_image" "$carrier_image" "$carrier_salt" \
      "$carrier_dir/$partition.info" "$carrier_dir/$partition.verify.log"
  done

  for image_name in "${cubs_firmware_images[@]}"; do
    source_hash=$(hash_file "$source_firmware_dir/$image_name")
    target_hash=$(zip_entry_hash "$target_files" "RADIO/$image_name")
    reconstructed_hash=$(zip_entry_hash "$reproduced_images_zip" "$image_name")
    bundle_hash=$(hash_file "$bundle/$image_name")
    stock_hash=$(zip_entry_hash "$stock_inner" "$image_name")
    require_value "$target_hash" "$source_hash" \
      "$image_name target-files RADIO versus generated source hash"
    require_value "$reconstructed_hash" "$source_hash" \
      "$image_name reconstructed ZIP versus generated source hash"
    require_value "$bundle_hash" "$source_hash" \
      "$image_name bundle versus generated source hash"
    require_value "$stock_hash" "$source_hash" \
      "$image_name pinned-stock versus generated source hash"
  done
  note "25 raw cubs firmware payloads match generated source, target-files, reconstructed ZIP, bundle, and pinned stock"
  note "24 target-files-only firmware descriptor carriers match the pinned release identity and raw payloads"
}

validate_boot_image() {
  local bundle=$1
  local name=$2
  local expected_size=$3
  local expected_magic=$4
  local expected_header=$5
  local size_policy=${6:-exact}
  local output="$scratch_dir/cubs-${name%.img}.unpacked"
  local info="$scratch_dir/cubs-${name%.img}.boot-info"
  local size magic
  size=$(stat -c '%s' "$bundle/$name")
  case "$size_policy" in
    exact)
      (( size == expected_size )) || \
        die "$name size mismatch: expected $expected_size, found $size"
      ;;
    capacity)
      validate_partition_capacity "$bundle/$name" "$expected_size" "$name"
      ;;
    *) die "internal error: unsupported boot-image size policy $size_policy" ;;
  esac
  magic=$(magic_at "$bundle/$name" 0 8)
  require_value "$magic" "$expected_magic" "$name magic"
  mkdir -p "$output"
  "${unpack_bootimg_command[@]}" --boot_img "$bundle/$name" --out "$output" \
    > "$info"
  if [[ "$expected_magic" == 414e44524f494421 ]]; then
    grep -qx "boot image header version: $expected_header" "$info" || \
      die "$name boot header version mismatch"
  else
    grep -qx "vendor boot image header version: $expected_header" "$info" || \
      die "$name vendor boot header version mismatch"
    grep -qx 'page size: 0x00000800' "$info" || \
      die "$name vendor boot page size is not the pinned 2048 bytes"
  fi
}

validate_dtbo() {
  local path=$1
  local total header entry_size entry_count entries_offset page_size size
  require_value "$(magic_at "$path" 0 4)" d7b7ab1e "dtbo image magic"
  total=$(u32_be_at "$path" 4)
  header=$(u32_be_at "$path" 8)
  entry_size=$(u32_be_at "$path" 12)
  entry_count=$(u32_be_at "$path" 16)
  entries_offset=$(u32_be_at "$path" 20)
  page_size=$(u32_be_at "$path" 24)
  size=$(stat -c '%s' "$path")
  (( total > 32 && total <= size && header == 32 && entry_size >= 32 && \
     entry_count > 0 && entries_offset == header && page_size == 4096 )) || \
    die "dtbo image has invalid table sizing or page metadata"
}

validate_stock_kernel() {
  local compressed="$scratch_dir/cubs-boot.unpacked/kernel"
  local image="$scratch_dir/cubs-boot.unpacked/Image"
  local spec="$source_dir/vendor/adevtool/vendor-specs/google_devices/cubs.yml"
  local generated="$source_dir/vendor/google_devices/cubs/stock-kernel/Image.lz4"
  local expected_hash actual_hash flags page_code version count

  [[ -s "$compressed" ]] || die "boot.img contains no kernel"
  require_value "$(magic_at "$compressed" 0 4)" 02214c18 \
    "stock kernel LZ4 legacy-frame magic"
  require_file "$spec"
  count=$(grep -c '^stock-kernel/Image\.lz4: [0-9a-f]\{64\}$' "$spec" || true)
  (( count == 1 )) || die "adevtool spec does not pin exactly one stock kernel"
  expected_hash=$(sed -n 's/^stock-kernel\/Image\.lz4: //p' "$spec")
  actual_hash=$(hash_file "$compressed")
  require_value "$actual_hash" "$expected_hash" "boot.img stock kernel hash"
  require_value "$(hash_file "$generated")" "$expected_hash" \
    "generated-vendor stock kernel hash"
  lz4 -d -f "$compressed" "$image" >/dev/null
  require_value "$(magic_at "$image" 56 4)" 41524d64 \
    "decompressed arm64 kernel magic"
  flags=$(u64_le_at "$image" 24)
  page_code=$(( (flags >> 1) & 3 ))
  (( page_code == 1 )) || \
    die "arm64 Image header does not declare a 4 KiB kernel page size"
  version=$(strings -a "$image" | \
    awk '/^Linux version / && !found {print; found=1}')
  [[ "$version" == *'-4k '* ]] || \
    die "kernel version does not identify the pinned 4K build"
  note "cubs kernel: $version"
}

validate_cubs() {
  local bundle=${CUBS_ARTIFACT_DIR:-"$project_root/artifacts/cubs"}
  local -a images=("${cubs_all_images[@]}")
  local -a dynamic_images=(
    system.img system_dlkm.img system_ext.img product.img vendor.img
    vendor_dlkm.img
  )
  local image_name bundle_hash zip_hash total_dynamic=0 prop_file patch_month
  local vendor_boot_info vendor_boot_original_size

  bundle=$(realpath -m -- "$bundle")
  assert_inside_project "$bundle"
  validate_exact_bundle cubs "$bundle" "${images[@]}"
  "$script_dir/attest-build-output.sh" verify cubs
  validate_bundle_metadata cubs "$bundle" "$cubs_out"
  validate_attestation cubs "$bundle" "$cubs_out"
  validate_firmware_requirements "$bundle/firmware-requirements.txt"
  select_aosp_tools "$cubs_out"
  locate_cubs_target_files
  validate_cubs_wifi_vintf_attestation
  validate_cubs_dexpreopt_attestation
  validate_target_files_metadata
  reproduce_cubs_images_zip
  validate_cubs_firmware_provenance

  for image_name in "${images[@]}"; do
    require_zip_entry_once "$reproduced_images_zip" "$image_name"
    bundle_hash=$(hash_file "$bundle/$image_name")
    zip_hash=$(zip_entry_hash "$reproduced_images_zip" "$image_name")
    require_value "$bundle_hash" "$zip_hash" \
      "cubs $image_name target-files provenance hash"
    if [[ -n "${cubs_attested_target_hash[$image_name]+present}" ]]; then
      require_zip_entry_once "$target_files" "IMAGES/$image_name"
      require_value "${cubs_attested_target_hash[$image_name]}" \
        "$(zip_entry_hash "$target_files" "IMAGES/$image_name")" \
        "attested cubs $image_name target-files image hash"
      require_value "${cubs_attested_target_hash[$image_name]}" "$zip_hash" \
        "attested cubs $image_name reconstructed image hash"
    fi
  done
  validate_target_files_vbmeta_digest "$bundle"

  for image_name in "${dynamic_images[@]}"; do
    prepare_filesystem_image cubs "$image_name" "$bundle/$image_name" erofs
    total_dynamic=$((total_dynamic + expanded_size[cubs/$image_name]))
  done
  (( total_dynamic <= 10733223936 )) || die \
    "expanded cubs dynamic images exceed the 10,733,223,936-byte group"
  note "cubs dynamic images: expanded bytes $total_dynamic / 10733223936"
  for image_name in vbmeta.img vbmeta_system.img vbmeta_vendor.img; do
    validate_partition_capacity "$bundle/$image_name" 65536 "$image_name"
  done
  prop_file="$scratch_dir/cubs-system-build.prop"
  extract_build_prop cubs system.img "$prop_file"
  require_value "$(hash_file "$prop_file")" \
    "$current_system_build_prop_sha256" \
    "cubs system-image build-property hash"
  require_prop "$prop_file" '^ro\.(system\.)?build\.type=userdebug$' \
    "cubs system userdebug identity"
  require_prop "$prop_file" '^ro\.(system\.)?build\.version\.sdk=37$' \
    "cubs system Android SDK 37 identity"
  require_prop "$prop_file" '^ro\.(system\.)?build\.version\.release=17$' \
    "cubs system Android 17 identity"
  require_prop "$prop_file" \
    "^ro\\.(system\\.)?build\\.version\\.security_patch=${AOSP_SECURITY_PATCH}$" \
    "cubs AOSP system security patch"

  validate_boot_image "$bundle" boot.img 67108864 414e44524f494421 4
  validate_boot_image "$bundle" init_boot.img 8388608 414e44524f494421 4
  validate_boot_image "$bundle" vendor_boot.img 67108864 564e4452424f4f54 4
  validate_boot_image "$bundle" vendor_kernel_boot.img 67108864 \
    564e4452424f4f54 4
  validate_boot_image "$bundle" pvmfw.img 1048576 414e44524f494421 3 \
    capacity
  vendor_boot_info="$scratch_dir/cubs-vendor_boot-v4.avb-info"
  "${avbtool_command[@]}" info_image --image "$bundle/vendor_boot.img" \
    >"$vendor_boot_info" || \
    die "cubs vendor_boot has invalid AVB metadata"
  vendor_boot_original_size=$(avb_metadata_value "$vendor_boot_info" \
    's/^Original image size:[[:space:]]*\([0-9][0-9]*\) bytes$/\1/p' \
    "cubs vendor_boot AVB original size")
  validate_cubs_vendor_boot_v4_layout \
    "$bundle/vendor_boot.img" "$vendor_boot_original_size"
  [[ $(stat -c '%s' "$bundle/dtbo.img") -eq 16777216 ]] || \
    die "dtbo.img does not match the 16 MiB partition size"
  validate_dtbo "$bundle/dtbo.img"
  grep -qx 'kernel_size: 0' "$scratch_dir/cubs-init_boot.boot-info" || \
    die "init_boot.img unexpectedly contains a kernel"
  grep -Eq '^ramdisk size: [1-9][0-9]*$' \
    "$scratch_dir/cubs-init_boot.boot-info" || \
    die "init_boot.img contains no ramdisk"
  grep -qx 'ramdisk size: 0' "$scratch_dir/cubs-boot.boot-info" || \
    die "boot.img unexpectedly contains a generic ramdisk"
  grep -Eq '^kernel_size: [1-9][0-9]*$' "$scratch_dir/cubs-boot.boot-info" || \
    die "boot.img contains no kernel"
  grep -Eq '^dtb size: [1-9][0-9]*$' \
    "$scratch_dir/cubs-vendor_kernel_boot.boot-info" || \
    die "vendor_kernel_boot.img contains no DTB"
  patch_month=${AOSP_SECURITY_PATCH%-*}
  for image_name in init_boot pvmfw; do
    grep -qx 'os version: 17.0.0' \
      "$scratch_dir/cubs-$image_name.boot-info" || \
      die "$image_name does not identify Android 17"
    grep -qx "os patch level: $patch_month" \
      "$scratch_dir/cubs-$image_name.boot-info" || \
      die "$image_name has the wrong security-patch month"
  done
  validate_pvmfw_avb_identity "$bundle/pvmfw.img" cubs-pvmfw
  validate_stock_kernel

  validate_cubs_avb_policy "$bundle"
  validate_avb_graph cubs "$bundle" "$reproduced_images_zip" "${images[@]}"
  note "cubs static image validation passed"
}

case "$selection" in
  gsi) validate_gsi ;;
  cubs) validate_cubs ;;
  all)
    validate_gsi
    validate_cubs
    ;;
esac

note "requested static image validation completed without device access"
