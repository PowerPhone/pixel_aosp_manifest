#!/usr/bin/env bash
# Compile the Cubs vendor change against the partitions actually kept on this phone.
# Does not build Soong, install, flash, compute hashes, or alter the captured roots.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
aosp=${AOSP_DIR:-$repo/work/aosp}
live_root=$repo/work/audio-research/cubs/primary-hal-integration-20260923
host_bin=$aosp/out_pixel/cubs/host/linux-x86/bin
context_source=$aosp/vendor/google_devices/cubs/powerphone/sepolicy
generated=
out=

usage() {
    printf '%s\n' \
        'Usage: compile-primary-policy.sh --generated-selinux DIR --output-dir NEW_DIR' \
        '       [--live-root DIR] [--host-bin DIR] [--context-source DIR]' \
        'DIR must be the completed Cubs product/vendor/etc/selinux directory.' \
        'Output: NEW_DIR/vendor/etc/selinux plus compiler inputs/logs and COMPLETE.'
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --generated-selinux|--output-dir|--live-root|--host-bin|--context-source)
            (($# >= 2)) || die "missing argument for $1"
            case "$1" in
                --generated-selinux) generated=$2;;
                --output-dir) out=$2;;
                --live-root) live_root=$2;;
                --host-bin) host_bin=$2;;
                --context-source) context_source=$2;;
            esac
            shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown argument: $1";;
    esac
done
[[ -n $generated && -n $out ]] || { usage >&2; exit 1; }
[[ ! -e $out ]] || die "output already exists; choose a new directory: $out"
generated=$(realpath -e -- "$generated")
live_root=$(realpath -e -- "$live_root")
host_bin=$(realpath -e -- "$host_bin")
context_source=$(realpath -e -- "$context_source")
out=$(realpath -m -- "$out")
[[ $generated == */cubs/vendor/etc/selinux ]] ||
    die 'generated policy must come from target/product/cubs/vendor/etc/selinux'

plat=$live_root/live-policy/system
product=$live_root/live-policy/product
system_ext=$live_root/system_ext-root/etc/selinux
vendor=$live_root/vendor-root/etc/selinux
odm=$live_root/vendor-root/odm/etc/selinux
require_file() { [[ -r $1 && -f $1 ]] || die "missing readable input: $1"; }
for tool in secilc sepolicy-analyze; do
    [[ -x $host_bin/$tool ]] || die "missing built host tool: $host_bin/$tool"
done
for file in "$generated/vendor_sepolicy.cil" "$generated/plat_sepolicy_vers.txt" \
        "$vendor/plat_sepolicy_vers.txt" "$vendor/genfs_labels_version.txt" \
        "$vendor/plat_pub_versioned.cil" "$vendor/vendor_sepolicy.cil" \
        "$vendor/precompiled_sepolicy"; do
    require_file "$file"
done
mapping_version=$(tr -d '\r\n' < "$vendor/plat_sepolicy_vers.txt")
generated_version=$(tr -d '\r\n' < "$generated/plat_sepolicy_vers.txt")
genfs_version=$(tr -d '\r\n' < "$vendor/genfs_labels_version.txt")
[[ $mapping_version == 202604 && $generated_version == "$mapping_version" &&
   $genfs_version == 202604 ]] || die 'this live profile requires mapping/genfs version 202604'
# Reject the old installed policy if the caller starts before Soong finishes.
for type in cubs_powerphone_boot cubs_powerphone_boot_exec \
        powerphone_cubs_data_file powerphone_cubs_marker_file vendor_powerphone_cubs_prop; do
    rg -q "^\\(type ${type}\\)" "$generated/vendor_sepolicy.cil" ||
        die "new Cubs policy not ready: missing type $type"
done

# Match system/core/init/selinux.cpp OpenSplitPolicy input selection and order.
# Unlike init's fallback, retain neverallow checking (no -N).
inputs=("$plat/plat_sepolicy.cil" "$plat/mapping/$mapping_version.cil")
[[ ! -f $plat/mapping/$mapping_version.compat.cil ]] ||
    inputs+=("$plat/mapping/$mapping_version.compat.cil")
inputs+=("$system_ext/system_ext_sepolicy.cil" "$system_ext/mapping/$mapping_version.cil")
[[ ! -f $system_ext/mapping/$mapping_version.compat.cil ]] ||
    inputs+=("$system_ext/mapping/$mapping_version.compat.cil")
inputs+=("$product/product_sepolicy.cil" "$product/mapping/$mapping_version.cil"
    "$vendor/plat_pub_versioned.cil" "$generated/vendor_sepolicy.cil")
[[ ! -f $odm/odm_sepolicy.cil ]] || inputs+=("$odm/odm_sepolicy.cil")
inputs+=("$plat/plat_sepolicy_genfs_$genfs_version.cil")
for file in "${inputs[@]}"; do require_file "$file"; done
[[ ! -f $odm/precompiled_sepolicy ]] ||
    die 'ODM precompiled policy would take precedence; this helper only overlays vendor'

# Init compares these existing cache-ID files. No digest is calculated here.
for part in plat system_ext product; do
    case "$part" in
        plat) metadata_source=$plat;;
        system_ext) metadata_source=$system_ext;;
        product) metadata_source=$product;;
    esac
    metadata_name=${part}_sepolicy_and_mapping.sha256
    require_file "$metadata_source/$metadata_name"
    require_file "$vendor/precompiled_sepolicy.$metadata_name"
    cmp -s "$metadata_source/$metadata_name" "$vendor/precompiled_sepolicy.$metadata_name" ||
        die "live init cache IDs differ for $part; do not transplant generated metadata"
done

mkdir -p -- "$out/vendor/etc/selinux"
policy_out=$out/vendor/etc/selinux
install -m 0644 "$generated/vendor_sepolicy.cil" "$policy_out/vendor_sepolicy.cil"
# Preserve only the compatible part of the unrelated live debugging allowance.
# The old shell property_service set violates live property.te:496; the actual
# policy-v1 compile rejected it. Keep read access, not that write or its socket
# plumbing. Do not restore the separately sanitized vndservicemanager rule.
retained_allows=(
    '(allow shell_202604 vendor_gos_dhdutil_prop (file (read getattr map open)))'
)
printf '' > "$out/retained-live-debug-allowances.cil"
for rule in "${retained_allows[@]}"; do
    rg -q -x -F -- "$rule" "$vendor/vendor_sepolicy.cil" ||
        die "expected live debugging allowance absent: $rule"
    if ! rg -q -x -F -- "$rule" "$generated/vendor_sepolicy.cil"; then
        printf '%s\n' "$rule" >> "$out/retained-live-debug-allowances.cil"
        printf '\n%s\n' "$rule" >> "$policy_out/vendor_sepolicy.cil"
    fi
done
for i in "${!inputs[@]}"; do
    [[ ${inputs[i]} != "$generated/vendor_sepolicy.cil" ]] ||
        inputs[i]=$policy_out/vendor_sepolicy.cil
done
printf '%s\n' "${inputs[@]}" > "$out/policy-inputs.txt"
compile=("$host_bin/secilc" -m -M true -G -c 30 "${inputs[@]}"
    -o "$policy_out/precompiled_sepolicy.pending" -f /dev/null)
printf '%q ' "${compile[@]}" > "$out/compile-command.txt"
printf '\n' >> "$out/compile-command.txt"
"${compile[@]}" 2>&1 | tee "$out/compile.log"
"$host_bin/sepolicy-analyze" "$policy_out/precompiled_sepolicy.pending" permissive \
    | LC_ALL=C sort -u > "$out/permissive-domains.txt"
"$host_bin/sepolicy-analyze" "$vendor/precompiled_sepolicy" permissive \
    | LC_ALL=C sort -u > "$out/baseline-permissive-domains.txt"
LC_ALL=C comm -13 "$out/baseline-permissive-domains.txt" "$out/permissive-domains.txt" \
    > "$out/new-permissive-domains.txt"
[[ ! -s $out/new-permissive-domains.txt ]] ||
    die 'compiled policy adds permissive domains beyond the captured live baseline'

# Keep all live context entries. Add only owned, source-defined entries that
# also appear in the completed generated context output, rejecting conflicts.
merge_contexts() {
    local kind=$1
    require_file "$vendor/vendor_$kind"
    require_file "$generated/vendor_$kind"
    require_file "$context_source/$kind"
    awk '
        function norm(s) {
            sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s)
            gsub(/[ \t]+/, " ", s); return s
        }
        function fail(s) { print "ERROR: " s > "/dev/stderr"; bad=1; exit 1 }
        FILENAME == ARGV[1] {
            s=norm($0); if (s != "" && s !~ /^#/) generated[s]=1; next
        }
        FILENAME == ARGV[2] {
            s=norm($0); if (s == "" || s ~ /^#/) next
            if (!(s in generated)) fail("owned context missing from generated output: " s)
            split(s, fields, " "); key=fields[1]
            if (key in added && added[key] != s) fail("conflicting owned context: " key)
            added[key]=s; order[++count]=key; next
        }
        {
            s=norm($0); split(s, fields, " "); key=fields[1]
            if (key in added) {
                if (s != added[key]) fail("live context conflicts with owned addition: " key)
                seen[key]=1
            }
            print $0
        }
        END {
            if (bad) exit 1
            print "\n# Cubs PowerPhone primary additions (generated and source matched)."
            for (i=1; i<=count; i++) if (!(order[i] in seen)) print added[order[i]]
        }
    ' "$generated/vendor_$kind" "$context_source/$kind" "$vendor/vendor_$kind" \
        > "$policy_out/vendor_$kind"
}
merge_contexts file_contexts
merge_contexts property_contexts
for kind in service_contexts hwservice_contexts; do
    [[ ! -f $context_source/$kind ]] || merge_contexts "$kind"
done
for name in plat_pub_versioned.cil plat_sepolicy_vers.txt genfs_labels_version.txt \
        precompiled_sepolicy.plat_sepolicy_and_mapping.sha256 \
        precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256 \
        precompiled_sepolicy.product_sepolicy_and_mapping.sha256; do
    install -m 0644 "$vendor/$name" "$policy_out/$name"
done
mv -- "$policy_out/precompiled_sepolicy.pending" "$policy_out/precompiled_sepolicy"
printf '%s\n' 'Compiled actual Cubs policy; neverallow checks enabled; no new permissive domains.' \
    'Preserved live platform/product/system_ext/ODM and live init cache metadata.' \
    'No device operation or hardware qualification was performed.' > "$out/COMPLETE"
printf 'Policy overlay ready: %s\n' "$policy_out"
