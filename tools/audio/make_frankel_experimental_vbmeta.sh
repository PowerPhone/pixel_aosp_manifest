#!/usr/bin/env bash
# Rebase one experimental vendor_kernel_boot onto an explicit, coherent root set.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
guard="$script_dir/verify_frankel_vbmeta_image_set.py"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: make_frankel_experimental_vbmeta.sh \
  --image-set DIR --vendor-kernel-boot FILE --output FILE \
  --avbtool FILE --key FILE

DIR must be the complete, currently compatible Frankel image bundle. Its
vbmeta.img is verified against every partition image before a new root vbmeta
is signed. Only the vendor_kernel_boot descriptor digest may change.
EOF
  exit 2
}

image_set=
vendor_kernel_boot=
output=
avbtool=
key=
while (( $# )); do
  case "$1" in
    --image-set) (( $# >= 2 )) || usage; image_set=$2; shift 2 ;;
    --vendor-kernel-boot) (( $# >= 2 )) || usage; vendor_kernel_boot=$2; shift 2 ;;
    --output) (( $# >= 2 )) || usage; output=$2; shift 2 ;;
    --avbtool) (( $# >= 2 )) || usage; avbtool=$2; shift 2 ;;
    --key) (( $# >= 2 )) || usage; key=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$image_set" && -n "$vendor_kernel_boot" && -n "$output" && \
   -n "$avbtool" && -n "$key" ]] || usage

for command_name in head mktemp mv python3 realpath rm sed stat; do
  command -v "$command_name" >/dev/null 2>&1 || \
    die "missing command: $command_name"
done
[[ -f "$guard" && ! -L "$guard" ]] || die "missing descriptor guard: $guard"
image_set=$(realpath -e -- "$image_set")
vendor_kernel_boot=$(realpath -e -- "$vendor_kernel_boot")
avbtool=$(realpath -e -- "$avbtool")
key=$(realpath -e -- "$key")
root_vbmeta="$image_set/vbmeta.img"
for path in "$root_vbmeta" "$vendor_kernel_boot" "$avbtool" "$key"; do
  [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe input: $path"
done
output=$(realpath -m -- "$output")
[[ ! -e "$output" ]] || die "refusing to overwrite output: $output"
[[ -d "$(dirname -- "$output")" ]] || die "output directory does not exist"

# Refuse a directory assembled from multiple releases before using it as a
# descriptor donor. This is the check the historical pair builders lacked.
python3 "$guard" --avbtool "$avbtool" root-set \
  --vbmeta "$root_vbmeta" --image-set "$image_set" >/dev/null

root_info=$("$avbtool" info_image --image "$root_vbmeta")
algorithm=$(sed -n 's/^Algorithm:[[:space:]]*//p' <<<"$root_info")
rollback_index=$(sed -n 's/^Rollback Index:[[:space:]]*//p' <<<"$root_info")
flags=$(sed -n 's/^Flags:[[:space:]]*//p' <<<"$root_info" | head -n 1)
rollback_location=$(
  sed -n 's/^Rollback Index Location:[[:space:]]*//p' <<<"$root_info"
)
padding_size=$(stat -c '%s' -- "$root_vbmeta")
[[ "$algorithm" =~ ^SHA[0-9]+_RSA[0-9]+$ && \
   "$rollback_index" =~ ^[0-9]+$ && "$flags" =~ ^[0-9]+$ && \
   "$rollback_location" =~ ^[0-9]+$ && "$padding_size" =~ ^[1-9][0-9]*$ ]] || \
  die "could not parse signing parameters from $root_vbmeta"

stage=$(mktemp -d -- "$(dirname -- "$output")/.vbmeta.XXXXXX")
cleanup() {
  if [[ -n ${stage:-} && -d "$stage" && \
        "$stage" == "$(dirname -- "$output")"/.vbmeta.* ]]; then
    rm -r -- "$stage"
  fi
}
trap cleanup EXIT
donor="$stage/vbmeta.descriptor-donor.img"
candidate="$stage/vbmeta.img"
python3 "$guard" --avbtool "$avbtool" rewrite-vkb-digest \
  --vbmeta "$root_vbmeta" --vendor-kernel-boot "$vendor_kernel_boot" \
  --output "$donor"
"$avbtool" make_vbmeta_image \
  --output "$candidate" \
  --algorithm "$algorithm" --key "$key" \
  --rollback_index "$rollback_index" \
  --rollback_index_location "$rollback_location" \
  --flags "$flags" --padding_size "$padding_size" \
  --include_descriptors_from_image "$donor"
candidate_info=$("$avbtool" info_image --image "$candidate")
root_public_key=$(sed -n 's/^Public key (sha1):[[:space:]]*//p' <<<"$root_info")
candidate_public_key=$(
  sed -n 's/^Public key (sha1):[[:space:]]*//p' <<<"$candidate_info"
)
[[ "$root_public_key" =~ ^[0-9a-f]{40}$ && \
   "$candidate_public_key" == "$root_public_key" ]] || \
  die "new root vbmeta is not signed by the root-set key"
python3 "$guard" --avbtool "$avbtool" root-set \
  --vbmeta "$candidate" --image-set "$image_set" \
  --override "vendor_kernel_boot=$vendor_kernel_boot" >/dev/null
mv -- "$candidate" "$output"

printf 'compatible root vbmeta created: %s\n' "$output"
printf 'root image set: %s\n' "$image_set"
