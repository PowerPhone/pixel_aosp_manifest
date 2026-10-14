# Cubs primary HAL policy compilation

This helper supports the saved live Cubs partition set in
`work/audio-research/cubs/primary-hal-integration-20260923`. It does not replace
the phone's platform, product, system_ext, or ODM policy with policy from the
populated build tree. It performs real policy compilation only; no device,
Soong, Ninja, hash generation, or flashing operation is included.

Run it after the **Cubs** build has completed the new vendor CIL and contexts:

```bash
cd /mnt/wsl/aosp_workspace/pixel_aosp_manifest
tools/audio/cubs/compile-primary-policy.sh \
  --generated-selinux "$PWD/work/aosp/out_pixel/cubs/target/product/cubs/vendor/etc/selinux" \
  --output-dir "$PWD/work/audio-research/cubs/primary-hal-integration-20260923/policy-primary-compiled"
```

The output directory must not already exist. An incomplete or failed attempt
has no `COMPLETE` marker and must not be packaged. Required host utilities are
Bash, coreutils, awk, ripgrep, and the already-built Cubs `secilc` and
`sepolicy-analyze` under `out_pixel/cubs/host/linux-x86/bin`. `--host-bin` can
select another local directory containing those compiler tools, but not
another target's policy. The helper rejects a generated policy without the
new Cubs types or the matching `202604` policy version.

## Exact input closure

The compiler invocation follows `system/core/init/selinux.cpp`'s
`OpenSplitPolicy` selection with binary policy version 30, MLS enabled, and
multiple-declaration/generated-attribute handling (`-m -M true -G -c 30`):

1. Live `live-policy/system/plat_sepolicy.cil`, its `mapping/202604.cil`, and
   its versioned compatibility CIL if present.
2. Live `system_ext-root/etc/selinux/system_ext_sepolicy.cil`, its
   `mapping/202604.cil`, and its compatibility CIL if present.
3. Live `live-policy/product/product_sepolicy.cil` and `mapping/202604.cil`.
4. Live `vendor-root/etc/selinux/plat_pub_versioned.cil`.
5. Newly built **Cubs** `vendor_sepolicy.cil`, with only the retained live shell
   debugging allowances described below appended if missing.
6. Live `vendor-root/odm/etc/selinux/odm_sepolicy.cil` if present.
7. Live platform `plat_sepolicy_genfs_202604.cil`, selected by the live vendor
   `genfs_labels_version.txt`.

Unlike init's fallback invocation, the helper does **not** pass `-N`: normal
neverallow checking remains enabled. A missing public-policy symbol or a
neverallow violation is a real integration failure; do not work around it by
substituting generated platform CIL. The finished binary must have no
**new** permissive domains relative to the captured live precompiled policy.
The current live userdebug baseline intentionally has permissive `su`; that
existing debugging access is preserved, while no HAL/helper permissiveness is
added. This does not itself set the device's global SELinux mode; the packaged
image must still boot and be tested under Enforcing.

The exact command, input paths, compiler diagnostics, baseline/result
permissive-domain lists, and newly permissive-domain difference are retained
alongside the resulting overlay.

The live vendor baseline additionally allowed shell to set/read
`vendor_gos_dhdutil_prop`. The first actual `policy-v1` compile established that
restoring the write violates the live platform neverallow at
`system/sepolicy/private/property.te:496`; that failed compile log is retained.
Only the exact compatible property-file read/getattr/map/open allowance is
preserved when missing from the new generated policy. The property set and its
socket plumbing are not restored. The retained rule must already exist
verbatim in the captured live policy, is recorded in
`retained-live-debug-allowances.cil`, and undergoes the same compiler and
neverallow checks. This is not a broad policy delta transplant. In particular,
the older `vndservicemanager` transfer rule intentionally removed by the AOSP
compatibility transformation is **not** restored.

## Files to package

After `COMPLETE` exists, overlay the output's `vendor/etc/selinux/` into a
**copy** of the captured live vendor root. It contains:

- `precompiled_sepolicy` built against the complete live-partition closure;
- new `vendor_sepolicy.cil` plus those retained debugging allowances, so init
  fallback compilation sees the same rules;
- `vendor_file_contexts` and `vendor_property_contexts`, preserving all live
  entries and adding only source-owned Cubs entries also present in the new
  generated context files; conflicting entries cause failure;
- unchanged live `plat_pub_versioned.cil`, policy/genfs version files, and
  `precompiled_sepolicy.*_sepolicy_and_mapping.sha256` cache-ID files.

The three existing cache-ID files are compared with their saved live platform
counterparts exactly as init does, then copied verbatim. They identify the
unchanged platform inputs, not the modified vendor policy. No hashes are
computed or attested. Never replace them with IDs generated for the local
tree's different platform/system_ext/product partitions.

New executable/data/marker file labels and the new readiness-property labels
must be included in image generation. In particular, the image builder must
use the merged file-context file when assigning filesystem labels, not only
copy that text file into `/vendor/etc/selinux`. No additional service-context
entry is needed for the existing `IModule/default`, `IConfig/default`, or
effect factory `IFactory/default` names: their live platform service labels
already exist. If the owned source later adds service/hwservice context files,
the helper merges those using the same generated-entry/conflict guards.

Do not replace unrelated generated vendor contexts, the live system_ext
policy, or any platform policy as part of this step. An ODM precompiled policy
would take precedence over vendor's; the helper refuses that unexpected
layout instead of leaving the new vendor binary ignored.

## Actual compile result, September 23

The completed Cubs outputs were compiled successfully into
`work/audio-research/cubs/primary-hal-integration-20260923/policy-v2/`.
`COMPLETE` exists, `compile.log` is empty, and `precompiled_sepolicy` is
1,274,490 bytes. Both baseline and resulting permissive-domain lists contain
only `su`; the newly permissive-domain list is empty. All five owned file
context entries and six readiness-property entries were matched against the
generated outputs and merged into their live tables.

The earlier `policy-v1/` is a rejected compile with the incompatible baseline
shell-property write restored. Do not package it. The v2 success proves policy
compilation and the declared context closure, not boot, Binder registration,
firmware initialization, or audio API behavior under Enforcing; those require
root's exact packaged-image hardware trial.

That separate gate subsequently passed on the exact v7 images: two enforcing
boots, automatic native readiness, the isolated Java/AAudio endpoint matrix,
direct/API acoustic trials and post-reboot operation. See
[the final scoped qualification](../../../docs/cubs-powerphone-qualification-20260923.md).
Compilation alone still does not qualify a newly rebuilt image.
