#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest_root=$(cd -- "$script_dir/../../../.." && pwd)
source_repo=${FRANKEL_CS35L43_SOURCE_REPO:-"$manifest_root/work/upstream/cirrus-linux-cs35l43"}
artifacts=${FRANKEL_GKI_ARTIFACTS:-"$manifest_root/work/upstream/frankel-gki-15739706"}
stock_module=${FRANKEL_STOCK_CS35L43_MODULE:-"$manifest_root/work/aosp/vendor/google_devices/frankel/stock-kernel/snd-soc-cs35l43.ko"}
source_revision=52c12e1e7c342edccfe4fc76908870e9a0a0fff3
source_branch='google/v6.6-cs35l43'
expected_stock_sha256=8db0c2795f11585cb3d30382169606130e5f8aa9b6c001b6508b758b29ca99d3
expected_stock_scmversion=g852c20a29246
expected_release='6.6.118-4k-g1831c2a45d9b'
patch_file="$manifest_root/patches/cirrus-cs35l43/0001-frankel-192k-use-96k-ultrasonic-base.patch"
build_root="$artifacts/cs35l43-powerphone-build"
source_stage="$build_root/source"
module_stage="$build_root/module"
output_dir="$artifacts/modules"
output_module="$output_dir/snd-soc-cs35l43.powerphone-192k.ko"
output_unstripped="$output_dir/snd-soc-cs35l43.powerphone-192k.unstripped.ko"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" && ! -L "$1" ]] || die "missing or unsafe file: $1"
}

for required in \
    "$patch_file" \
    "$script_dir/Makefile.powerphone" \
    "$script_dir/frankel-core-exports.c" \
    "$script_dir/frankel-fw-compat.h" \
    "$stock_module" \
    "$artifacts/Module.symvers" \
    "$artifacts/kbuild-out/Makefile"; do
  require_file "$required"
done
[[ -d "$source_repo/.git" ]] || die "Cirrus source repository is absent: $source_repo"
git -C "$source_repo" cat-file -e "$source_revision^{commit}" 2>/dev/null ||
  die "fetch the pinned Cirrus $source_branch revision $source_revision"

actual_stock_sha256=$(sha256sum -- "$stock_module" | awk '{print $1}')
[[ "$actual_stock_sha256" == "$expected_stock_sha256" ]] ||
  die "unexpected stock snd-soc-cs35l43.ko identity: $actual_stock_sha256"
actual_stock_scmversion=$(modinfo -F scmversion "$stock_module")
[[ "$actual_stock_scmversion" == "$expected_stock_scmversion" ]] ||
  die "unexpected stock CS35L43 scmversion: $actual_stock_scmversion"

rm -rf -- "$build_root"
mkdir -p -- "$source_stage" "$module_stage/include/sound" "$output_dir"
git -C "$source_repo" archive "$source_revision" -- \
  sound/soc/codecs/cs35l43.c \
  sound/soc/codecs/cs35l43-tables.c \
  sound/soc/codecs/cs35l43.h \
  sound/soc/codecs/wm_adsp.h \
  include/sound/cs35l43.h | tar -x -C "$source_stage"
# The staging tree lives below the manifest Git worktree, so an ordinary
# `git apply` from inside it still resolves paths against the enclosing
# worktree root.  Pin the path prefix explicitly.
source_stage_relative=${source_stage#"$manifest_root/"}
[[ "$source_stage_relative" != "$source_stage" ]] ||
  die "source staging path escaped manifest root: $source_stage"
git -C "$manifest_root" apply --check --directory="$source_stage_relative" "$patch_file"
git -C "$manifest_root" apply --directory="$source_stage_relative" "$patch_file"

install -m 0644 "$source_stage/sound/soc/codecs/cs35l43.c" "$module_stage/cs35l43.c"
install -m 0644 "$source_stage/sound/soc/codecs/cs35l43-tables.c" \
  "$module_stage/cs35l43-tables.c"
install -m 0644 "$source_stage/sound/soc/codecs/cs35l43.h" "$module_stage/cs35l43.h"
install -m 0644 "$source_stage/sound/soc/codecs/wm_adsp.h" "$module_stage/wm_adsp.h"
install -m 0644 "$source_stage/include/sound/cs35l43.h" \
  "$module_stage/include/sound/cs35l43.h"
install -m 0644 "$script_dir/frankel-core-exports.c" \
  "$module_stage/frankel-core-exports.c"
install -m 0644 "$script_dir/frankel-fw-compat.h" \
  "$module_stage/frankel-fw-compat.h"
install -m 0644 "$script_dir/Makefile.powerphone" "$module_stage/Makefile"

# The core imports two symbols from fw_cs_dsp and nineteen from
# snd-soc-wm-adsp.  They are vendor modules, so the public GKI Module.symvers
# does not contain their CRCs.  Recover exactly those CRCs from the guarded
# Frankel module that already loads against the same vendor dependencies.
stock_versions="$build_root/stock-versions.txt"
extra_symvers="$module_stage/vendor-dependencies.symvers"
modprobe --show-modversions "$stock_module" >"$stock_versions"
: >"$extra_symvers"
while read -r crc symbol; do
  if awk -v name="$symbol" '$2 == name { found = 1 } END { exit !found }' \
      "$artifacts/Module.symvers"; then
    continue
  fi
  case "$symbol" in
    cs_dsp_load_coeff|cs_dsp_stop)
      printf '%s\t%s\tfw_cs_dsp\tEXPORT_SYMBOL_GPL\tFW_CS_DSP\n' \
        "$crc" "$symbol" >>"$extra_symvers"
      ;;
    wm_adsp*|wm_halo_init)
      printf '%s\t%s\tsnd_soc_wm_adsp\tEXPORT_SYMBOL_GPL\t\n' \
        "$crc" "$symbol" >>"$extra_symvers"
      ;;
    *)
      die "stock module imports unknown non-GKI symbol: $symbol"
      ;;
  esac
done <"$stock_versions"
[[ $(wc -l <"$extra_symvers") -eq 21 ]] ||
  die "expected exactly 21 vendor dependency symbols"

clang_bin="$artifacts/ddk-workspace/kleaf/prebuilts/clang/host/linux-x86/clang-r510928/bin"
build_tools_bin="$artifacts/ddk-workspace/kleaf/prebuilts/build-tools/path/linux-x86"
[[ -x "$clang_bin/clang" ]] || die "missing pinned DDK clang: $clang_bin/clang"
[[ -d "$build_tools_bin" ]] || die "missing pinned DDK build tools: $build_tools_bin"

PATH="$clang_bin:$build_tools_bin:$PATH" \
  make -C "$artifacts/kbuild-out" \
    M="$module_stage" \
    ARCH=arm64 \
    LLVM=1 \
    LLVM_IAS=1 \
    KCFLAGS='-Wno-error=unknown-attributes -Wno-unknown-attributes' \
    KBUILD_EXTRA_SYMBOLS="$artifacts/Module.symvers $extra_symvers" \
    modules

require_file "$module_stage/snd-soc-cs35l43.ko"
stock_export_crcs="$build_root/stock-kcrctab-gpl.bin"
new_export_crcs="$build_root/new-kcrctab-gpl.bin"
stock_export_names="$build_root/stock-export-names.txt"
new_export_names="$build_root/new-export-names.txt"
"$clang_bin/llvm-objcopy" --dump-section \
  "__kcrctab_gpl=$stock_export_crcs" "$stock_module"
[[ $(stat -c %s -- "$stock_export_crcs") -eq 36 ]] ||
  die "stock CS35L43 export CRC section is not nine words"
readelf -Ws "$stock_module" | awk \
  '$8 ~ /^__crc_cs35l43_/ { print $2, $8 }' | sort >"$stock_export_names"
readelf -Ws "$module_stage/snd-soc-cs35l43.ko" | awk \
  '$8 ~ /^__crc_cs35l43_/ { print $2, $8 }' | sort >"$new_export_names"
cmp -s -- "$stock_export_names" "$new_export_names" ||
  die "replacement export order differs from the stock split-core ABI"

# Public headers from the selected newer GKI produce different genksyms CRCs
# for seven unchanged core declarations. The stock I2C/SPI transport modules
# consume the old CRCs. Preserve the complete nine-word stock export table;
# the symbol names/order check above makes this a fail-closed ABI adaptation.
"$clang_bin/llvm-objcopy" \
  --update-section "__kcrctab_gpl=$stock_export_crcs" \
  "$module_stage/snd-soc-cs35l43.ko" "$output_unstripped"
"$clang_bin/llvm-objcopy" --dump-section \
  "__kcrctab_gpl=$new_export_crcs" "$output_unstripped"
cmp -s -- "$stock_export_crcs" "$new_export_crcs" ||
  die "replacement export CRC table does not match stock"
"$clang_bin/llvm-strip" --strip-debug \
  -o "$output_module" "$output_unstripped"

actual_release=$(modinfo -F vermagic "$output_module")
[[ "$actual_release" == "$expected_release "* ]] ||
  die "unexpected replacement vermagic: $actual_release"
[[ $(modinfo -F name "$output_module") == snd_soc_cs35l43 ]] ||
  die "replacement module name does not match stock"
[[ $(modinfo -F depends "$output_module") == *snd_soc_wm_adsp* &&
   $(modinfo -F depends "$output_module") == *fw_cs_dsp* ]] ||
  die "replacement module dependency metadata is incomplete"

for exported in \
    cs35l43_pm_ops cs35l43_precious_reg cs35l43_probe \
    cs35l43_readable_reg cs35l43_reg cs35l43_remove \
    cs35l43_resume_runtime cs35l43_suspend_runtime cs35l43_volatile_reg; do
  nm "$output_unstripped" | grep -q " __ksymtab_${exported}$" ||
    die "replacement module does not export $exported"
done

# All versioned imports must carry either the selected GKI CRC or the exact
# CRC recovered from the stock module.  This also catches accidental source
# API drift before an image is assembled.
while read -r crc symbol; do
  expected_crc=$(awk -v name="$symbol" '$2 == name { print $1; exit }' \
    "$artifacts/Module.symvers")
  if [[ -z "$expected_crc" ]]; then
    expected_crc=$(awk -v name="$symbol" '$2 == name { print $1; exit }' \
      "$extra_symvers")
  fi
  [[ -n "$expected_crc" && "${crc,,}" == "${expected_crc,,}" ]] ||
    die "replacement CRC mismatch: $symbol module=$crc expected=${expected_crc:-missing}"
done < <(modprobe --show-modversions "$output_module")

grep -q 'rate == 192000 ? 0x04 : 0x03' "$module_stage/cs35l43.c" ||
  die "guarded 192 kHz source change is absent from staged source"

(
  cd -- "$output_dir"
  sha256sum -- \
    "$(basename -- "$output_module")" \
    "$(basename -- "$output_unstripped")" \
    >snd-soc-cs35l43.powerphone-192k.SHA256SUMS
)

printf 'Built Frankel PowerPhone CS35L43 core: %s\n' "$output_module"
printf 'Unstripped module: %s\n' "$output_unstripped"
printf 'Source: %s @ %s\n' "$source_branch" "$source_revision"
printf 'Vermagic: %s\n' "$actual_release"
