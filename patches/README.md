# Compatibility patch provenance

These patches are the audited delta from exact `android-17.0.0_r1` source. They
are applied idempotently by `scripts/apply-source-patches.sh`.

`BASE_REVISIONS` is the machine-enforced project/base lock. The patch driver
rejects a stack unless its repository is at the exact locked commit, and lint
cross-checks every entry against `manifests/resolved.xml`.

Exact bases:

- `build/make`: `5ce6f787337d0223710bf7d4a16dbe6d2a35f777`
- `build/soong`: `6722dd8833db7482df1a2543ca3fcf67ddf0f7b1`
- `frameworks/base`: `94b4c163b7dfe5ce3607f7bb8456f9573f7de57d`
- `frameworks/native`: `ae266dcb706d083868578cfedce381ef44488a07`
- `external/tinyalsa_new`: `faac725f32811c68eb40e2d5956eadc51dbb8a60`
- `hardware/interfaces`: `0162af698935100a590b7359581ac8b1b80693e5`
- `packages/apps/CarrierConfig2`: `9d56beab5824252e6fcdd09c04726d276343b247`
- `system/core`: `545d2487e38192a2ce25040897ced877cf6b4f53`
- `system/sepolicy`: `e066568e98d86db31a9346d30977f3632fa7073c`
- `tools/apksig`: `179f60df00d242f6bb22acf828b0884eac2d5f72`
- `vendor/adevtool`: `b01ccecab3468f3bcfa0d23adc361ad074989674`

## Upstream patches

The imported patches below target five Apache-2.0 AOSP repositories maintained
as GrapheneOS forks. The linked commits are the upstream provenance; all other
patches in this tree are the project-authored adapters described separately.

| Local patch | Upstream commit |
| --- | --- |
| `build/0001-per-product-build-id.patch` | [`ddd3c728381776d403cd0e1d68a92ffedab10373`](https://github.com/GrapheneOS/platform_build/commit/ddd3c728381776d403cd0e1d68a92ffedab10373) |
| `build-soong/0002-disable-dexpreopt-check-for-prebuilt-standalone-jars.patch` | [`1f8a2eb90fd78ddefc98d57a968ea009096406b3`](https://github.com/GrapheneOS/platform_build_soong/commit/1f8a2eb90fd78ddefc98d57a968ea009096406b3) |
| `frameworks-base/0001-aapt2-stringified-configuration.patch` | [`e32622a9af583b1cf73555fb985b49e0f73223f7`](https://github.com/GrapheneOS/platform_frameworks_base/commit/e32622a9af583b1cf73555fb985b49e0f73223f7) |
| `frameworks-base/0002-aapt2-proto-adevtool-conversion.patch` | [`f18597e43abd313efb82d349c0cd425dd6ca3389`](https://github.com/GrapheneOS/platform_frameworks_base/commit/f18597e43abd313efb82d349c0cd425dd6ca3389) |
| `frameworks-base/0003-aapt2-brief-package-info.patch` | [`7b672d6832764cf122456a9ae383445dcfe88c73`](https://github.com/GrapheneOS/platform_frameworks_base/commit/7b672d6832764cf122456a9ae383445dcfe88c73) |
| `frameworks-base/0004-aapt2-proto-java-library.patch` | [`040c88b56c6a0e454d23afcd356e21b10ad6e42e`](https://github.com/GrapheneOS/platform_frameworks_base/commit/040c88b56c6a0e454d23afcd356e21b10ad6e42e) |
| `frameworks-base/0005-aapt2-brief-package-library.patch` | [`255257eb3a8ccaef7787e462ee27da6cf9b37538`](https://github.com/GrapheneOS/platform_frameworks_base/commit/255257eb3a8ccaef7787e462ee27da6cf9b37538) |
| `system-sepolicy/0001-support-extending-sepolicy-cils.patch` | [`c31a4b7f23144ff9f27bcca999a6b3ccb1032bbc`](https://github.com/GrapheneOS/platform_system_sepolicy/commit/c31a4b7f23144ff9f27bcca999a6b3ccb1032bbc) |
| `apksig/0001-add-print-certs-command-for-adevtool.patch` | [`ba4d984e1a360d427307d669d2f789212130e9e8`](https://github.com/GrapheneOS/platform_tools_apksig/commit/ba4d984e1a360d427307d669d2f789212130e9e8) |

The first five numbered `frameworks-base` AAPT2 patches must remain in that
order; the device-selected eUICC provider follows them in the same explicit
stack.

The `apksig` patch adds `adevtool`'s batched `print-certs` command. That mode
extracts signer certificates without verifying APK content, exactly as the
upstream commit documents. Its inputs are restricted to files extracted from
the checksum-pinned stock factory archive; `adevtool generate-all` verification
itself remains enabled, and this workflow never passes `--noVerify`.

## Project-authored adapters

- `adevtool/0001-pristine-aosp-compatibility.patch` adapts the pinned MIT
  GrapheneOS adevtool configuration to public AOSP resources/policy and keeps
  the secondary-slot odex image out of the bring-up product. Its upstream
  notice is retained at `../LICENSES/adevtool-MIT.txt`.
- `carrierconfig2/0001-omit-grapheneos-test-apis.patch` excludes two debug-only
  classes from the pinned MIT CarrierConfig2 project because they import APIs
  absent from AOSP. Runtime carrier configuration remains included; the
  upstream notice is retained at `../LICENSES/carrierconfig2-MIT.txt`.
- `adevtool/0002-malibu-avb-chain-topology.patch` reconstructs the stock
  Pixel 11 AVB chain layout missing from pristine AOSP device support. It
  groups `pvmfw` and framework partitions under `vbmeta_system` at rollback
  location 1, `vendor` under `vbmeta_vendor` at location 3, and chains
  `boot`/`init_boot` at locations 2/4. Source-built userdebug images use the
  public AOSP RSA-4096 test key and the AOSP release SPL rollback index.
  Adevtool's generic extraction pass subsequently collapses named fstab AVB
  dependencies to root `vbmeta`; the post-FileTreeSpec sanitizer restores the
  exact corresponding child names in both generated `fstab.malibu` copies.
  Static validation ties those installed mappings back to this root chain.
- `adevtool/0003-strict-aosp17-sepolicy.patch` removes the GrapheneOS-only
  debug-shell write to the vendor-owned `gos-dhdutil` property. Pristine AOSP
  17 deliberately forbids this core-to-vendor property write; the patch keeps
  the confined helper and its result writer without adding a property-owner
  violator attribute or weakening neverallow enforcement.
- `adevtool/0004-malibu-firmware-avb-descriptors.patch` restores the public
  AOSP side of Pixel 11 bootloader packaging. It declares the exact 24 stock
  A/B firmware partitions, supplies a dependency-free strict FBPK v2 unpacker,
  and creates legacy-Make descriptor carriers without changing the extracted
  raw firmware. Each carrier is a raw image copy with an AVB hash footer. Its
  salt is the concatenation of the lowercase hexadecimal SHA-256 digests of
  `BUILD_NUMBER_FILE` and `BUILD_DATETIME_FILE`; its partition size is
  `64 KiB + 4 KiB + round_up(raw_size, 4 KiB)`. Both identity files, the raw
  image, and `avbtool` are normal build prerequisites. A static pattern rule
  enumerates only the reviewed 24 carrier targets, as required by Kati. The
  carriers enter the root-vbmeta descriptor arguments and target-files radio
  inputs, while the direct root vbmeta target depends on every carrier.
- `adevtool/0005-laguna-pristine-aosp-compatibility.patch` adapts the Pixel 10
  Laguna templates to pristine AOSP. It disables the unused secondary-slot
  odex image, omits the GrapheneOS-only platform init module and private
  framework overlay resources while retaining the stock display color modes,
  and leaves adevtool's verified generated bytes otherwise intact. The
  Frankel post-generation sanitizer removes the broad BoardConfig bring-up
  switches only after the immutable upstream FileTreeSpec has passed.
- `frameworks-native/0001-define-missing-feature-prebuilts.patch` defines
  eight Frankel-prefixed feature-XML modules absent from the pinned AOSP 17
  source. After adevtool verifies its generated bytes, the Frankel sanitizer
  rewrites exactly that product's eight generic requests to the scoped names.
  Explicit `filename` properties preserve the original vendor permission paths
  and XML bytes. Unchanged Cubs and future-target requests cannot resolve
  through this adapter. Without the Frankel producers, Make retains the names
  in `product_packages.txt` while silently omitting their files; notably,
  omitting Wi-Fi Aware prevents the framework service required by Pixel Modem
  Service from starting.
- `frameworks-base/0006-pixel-euicc-gservices-flags-provider.patch` adds a
  standalone, device-selected provider for the six immutable Gservices flags
  extracted for Pixel's proprietary eUICC firmware helper. The provider owns
  the exact authority expected by that helper, defines its
  `signature|privileged` read permission, and independently rejects every
  caller except the installed system/privileged `com.google.euiccpixel`
  package. This preserves eSIM firmware update and recovery on pristine AOSP
  without installing Google Services Framework. Direct authority ownership is
  intentional for this GSF-free product and would conflict with later adding
  real GSF; a GSF-capable derivative should instead implement authority
  redirection. The narrow design follows the behavior documented by the
  upstream GrapheneOS [framework redirect](https://github.com/GrapheneOS/platform_frameworks_base/commit/ea88c6ad9911b10fd6ab88de4713ce2ddf3a030d)
  and [flags provider](https://github.com/GrapheneOS/platform_packages_apps_GmsCompat/commit/94c24533e7ba5df979621d3ffbb859dd3f989c6c)
  commits, but is an independent Apache-2.0 implementation for pristine AOSP.
- `build/0008-propagate-pvmfw-signing-metadata.patch` introduces distinct
  signing-only `misc_info` fields for the inherited RSA-4096 AVB key and
  algorithm used to reconstruct pVM firmware. Releasetools consumes and can
  replace those fields without interpreting `pvmfw` as a separately chained
  partition; incomplete or mixed signing modes fail closed. The patch also
  pins the direct image's empty-payload identity salt, avoids injecting a
  second global salt, and tracks both the fingerprint and selected signing key
  as normal prerequisites. This prevents target-files from replacing the
  valid pVM footer with unsigned `Algorithm: NONE` metadata or a different
  hash identity.
- `build-soong/0005-select-adevtool-fbpack-unpacker.patch` makes fsgen prefer
  the reviewed `vendor/adevtool` FBPK unpacker when it exists, while retaining
  the original Google-prebuilt path as a backwards-compatible fallback. It
  rejects a configured bootloader when neither executable exists and tracks
  all Python files beside the selected tool as dependencies. It also promotes
  the build-number and date inputs of each Soong firmware carrier from
  order-only to normal dependencies, preventing stale descriptors after an
  incremental identity change. Focused tests pin the exact Malibu preferred
  and fallback paths, salt command, size expression, and dependency class.
- `build/0002-align-soong-gsi-avb-policy.patch` makes the Soong-built GSI
  system image honor `BoardConfigGsiCommon.mk`'s existing RSA-2048 chain key
  and security-patch rollback index. The tag-locked patch pins the UTC epoch
  for the release's `2026-06-05` SPL because Soong's filesystem
  `rollback_index` property is not configurable. Without it, AOSP 17's root `vbmeta.img`
  cannot authenticate the selected Soong `system.img`. This adapter is scoped
  to GSI filesystem defaults and leaves other generic system images unchanged.
- `build/0003-render-make-build-dates-in-utc.patch` and
  `build-soong/0001-render-build-props-in-utc.patch` make both legacy Make
  sysprops and Soong's `gen_build_prop` render the pinned epoch in UTC. Ninja
  deliberately filters ambient `TZ`, so exporting it in a wrapper alone is not
  a reproducible input.
- `build/0004-propagate-deterministic-dtbo-salt.patch` moves Make's existing
  deterministic DTBO salt expression into the footer-argument set shared with
  `misc_info.txt`. `build-soong/0003-propagate-deterministic-dtbo-salt.patch`
  generates the same salt once and binds both the fsgen direct signer and its
  target-files metadata to it. Without these paired fixes, releasetools strips
  and rebuilds the prebuilt DTBO footer with the generic fingerprint-derived
  salt, so product, target-files, and reconstructed DTBO—and consequently root
  vbmeta—differ despite identical inputs. The byte derivation intentionally
  remains AOSP's concatenated SHA-256 digests of the build-number and date
  files. These are project-authored Android 17 fixes; neither the pinned AOSP
  tag nor current upstream AOSP/GrapheneOS propagates the salt into DTBO
  metadata.
- `build/0005-track-dtbo-avb-identity-inputs.patch` declares the product
  fingerprint and conditional deterministic-salt files as normal prerequisites
  of Make's 4K and 16K AVB DTBO targets. It applies the same dependencies to
  `misc_info.txt` only when that file emits AVB metadata for a prebuilt DTBO.
  This prevents an incremental build from retaining a stale footer or
  releasetools argument after an identity input changes, without rebuilding
  non-AVB or non-DTBO products. This is a project-authored Android 17 fix.
- `system-core/0001-preserve-devnode-description-modes.patch` makes
  `mkbootfs -n` entries retain the explicit modes and device numbers from the
  node description even when releasetools also supplies a canned filesystem
  config. It zero-initializes synthetic `stat` records and adds a host test
  that proves option-order-independent CPIO bytes and the intended `0755`
  directory/`0600` character-device metadata. This prevents a rebuilt
  `init_boot` from silently changing its `/dev` permissions.
- `system-core/0002-do-not-revive-stopped-audioserver-from-zygote.patch`
  makes both zygote restart hooks use init's `--only-if-running` guard. A
  zygote recovery still restarts a live audioserver, but cannot override an
  intentional bounded boot-time audioserver stop.
- `build/0006-merge-vendor-ramdisk-staging.patch` overlays the vendor
  ramdisk and optional recovery root into a clean intermediate tree before
  one `mkbootfs` invocation. This gives direct Make output the same global
  path ordering and clean-staging semantics as target-files reconstruction,
  avoiding byte drift in `vendor_boot` while preserving the existing overlay
  precedence. `build-soong/0006-merge-cpio-roots-before-archiving.patch`
  applies the same rule to fsgen filesystems with `include_files_of`: it uses
  the tracked host `acp`, keeps every included partition image as a normal
  input, and tests cleanup, overlay order, and a single merged-root archive
  invocation. Together the paired patches keep Make, Soong diff-test, and
  releasetools CPIO bytes aligned.
- `build/0007-propagate-make-boot-salts.patch` adds Make's deterministic
  build-number/date salt to the target-files metadata for each Make-signed
  `init_boot`, `vendor_boot`, and `vendor_kernel_boot` image. It also makes
  those direct image targets and `misc_info.txt` depend normally on the two
  identity files. Without this patch, direct and target-files ramdisk bytes
  are identical but releasetools substitutes the fingerprint digest as the
  AVB salt, changing all three images and root `vbmeta`. This is a
  project-authored Android 17 fix.
- `build-soong/0004-propagate-deterministic-boot-salts.patch` makes each
  fsgen `make_legacy` boot-image module generate its AVB salt once and bind
  both the product image signer and target-files `misc_info.txt` to that exact
  value. `boot` retains AOSP's SHA-256 digest of the kernel, while `init_boot`,
  `vendor_boot`, and `vendor_kernel_boot` retain the concatenated SHA-256
  digests of the build-number and date files. Without the metadata argument,
  releasetools chooses a different default salt when reconstructing the three
  non-kernel images, so their bytes and root vbmeta differ from the directly
  built product. This is a project-authored Android 17 fix.
- `build-soong/0002-disable-dexpreopt-check-for-prebuilt-standalone-jars.patch`
  is the exact GrapheneOS AOSP 17 fix for 10th-generation Pixel prebuilt
  standalone `system_server` JARs. The upstream checker cannot resolve such a
  JAR from its generated proprietary Soong namespace; the patch disables only
  that build-time dexpreopt artifact check and leaves the prebuilt JAR,
  `PRODUCT_STANDALONE_SYSTEM_SERVER_JARS`, and dexpreopt configuration intact.
  The cubs completion attestation compensates for the disabled generic check:
  it requires dexpreopt to remain enabled for exactly
  `system_ext:malibu-plugin-provider`, then binds the installed JAR and its
  arm64 ODEX/VDEX artifacts byte-for-byte between the product output and
  target-files. The installed JAR must also equal the generated-vendor source
  JAR and all three copies must pass ZIP/JAR integrity checking. Static
  validation independently repeats those checks and minimum OAT/VDEX magic
  validation against the attested digests before and after bundle publication.
- `external-tinyalsa/0001-report-tinyplay-progress-and-xruns.patch` instruments
  the legacy-v1 `tinyplay` used for direct PCM0,D0 qualification. It reports
  the exact byte offset and PCM error on a failed write, every cumulative xrun
  transition, and final byte/xrun counts. This patch is deliberately separate
  from `external/tinyalsa_new`: the two Repo projects provide different
  tinyALSA ABIs in the same process.
- `external-tinyalsa-new/0001-expose-pcm-xrun-counter.patch` exposes the
  implementation's existing cumulative xrun count through `pcm_get_xruns`.
  The count includes EPIPEs tinyALSA recovers internally, allowing the
  PowerPhone HAL to reject a nominally successful transfer that actually
  underruns or overruns.
- `external-tinyalsa-new/0002-honor-explicit-avail-min.patch` makes a nonzero
  `pcm_config.avail_min` reach `SNDRV_PCM_IOCTL_SW_PARAMS`, while retaining the
  historical one-period default when callers leave it zero.
- `external-tinyalsa-new/0003-report-tinyplay-xruns.patch` includes the
  cumulative recovered-xrun count in the tinyalsa-v2 `tinyplay` completion
  summary used by direct-hardware qualification.
- `hardware-interfaces/0001-add-powerphone-192k-capture-module.patch`
  adds the initial input-only AIDL `IModule/powerphone`. It opens the fixed
  `CARD_1_DEV_0`, `_2`, and `_3` ALSA endpoints directly as mono S32_LE at
  exactly 192000 Hz. The service deliberately registers no `IConfig` or
  effects factory and therefore does not replace Frankel's proprietary AoC
  primary module. Product installation, the matching device framework
  compatibility matrix, and the two target-specific SELinux labels are
  materialized only when the generated-vendor sanitizer runs with
  `POWERPHONE_AUDIO_SIDECAR=true`.
- `hardware-interfaces/0002-add-powerphone-192k-speaker-output.patch`
  first converts all three capture devices to exact, non-default `IN_BUS`
  addresses, then extends the module with one normal-mixer
  PCM32/192000 Hz/four-channel-index
  output profile for Frankel PCM 0,28. Three non-default, uniquely addressed
  `OUT_BUS` ports select the Main amp (earpiece), R amp (bottom candidate), or
  both without entering Android's ordinary media/ring/call strategies. A
  custom tinyALSA route controller refuses a busy stock TDM route, serializes
  ownership among sidecar streams, snapshots non-power controls, enables the
  dedicated US route and selected amp last, and splits writes on ALSA period
  boundaries. Before every period and cleanup it verifies the complete owned
  mixer state, including partial setup; drift aborts and latches a fault
  without writing over a newly active proprietary-HAL route. With ownership
  intact it closes PCM before forcing both amps/routes off and restoring
  state. The VINTF HAL
  process now stays registered from boot so audio discovery cannot deadlock;
  AudioPolicyManager may construct inert STANDBY streams but `StreamAlsa`
  opens no PCM until start. Input and output start/transfer fail independently
  unless the
  volatile `vendor.powerphone.pdm.ready` and
  `vendor.powerphone.aoc_speaker_192k.ready` properties certify their exact
  runtime topologies. Both properties remain false unless their confined
  certifiers explicitly establish them; the D10 bootstrap clears both before
  its boot-local mutation. Merely
  seeing the advertised profiles is therefore not readiness or hardware
  qualification.
- `hardware-interfaces/0003-use-qualified-frankel-d10-capture.patch`
  replaces the superseded card-1/S32 input assumption with the hardware-proven
  AoC D10 path: card 0, device 10, mono S16_LE at exactly 192000 Hz. Its three
  addressed `IN_BUS` ports select logical microphone 0, 1, or 2 through
  `BUILDIN MIC ID CAPTURE LIST`, then exclusively own
  `EP3 TX Mixer INTERNAL_MIC_TX`. Input start requires the boot-volatile D10
  readiness property, every conflicting EP1/2/3/5 TX route and microphone
  power control idle, and the exact RAW/no-effects mixer profile. PCM open is
  accepted only with the live-qualified 1920-frame/four-period geometry; PCM
  closes before the route and MIC0..MIC2 controls are forced off. Mixer drift
  aborts the stream. The patch intentionally does not apply the F1 mutation:
  the resident pre-audioserver certifier described in
  `../docs/frankel-powerphone-image-integration.md` must establish that
  separate boot invariant before setting readiness.
- `hardware-interfaces/0004-fix-powerphone-d10-build.patch` uses the media-common
  `AudioIoFlags` type required by `Module` and reads the public tinyALSA proxy
  configuration for the four-period assertion. This is the compile-only
  follow-up proven by the named PowerPhone HAL build.
- `hardware-interfaces/0005-keep-readiness-writes-in-certifier-domains.patch`
  removes both typed readiness-property writes from the vendor init RC. The
  selected D10 bootstrap domain initializes the flags instead, while its
  system-ext companion RC owns the platform-private audioserver lifecycle.
- `hardware-interfaces/0006-use-qualified-d0-single-amp-output.patch` moves the
  speaker sidecar to the hardware-stable PCM0,D0 stereo S32 480x4 frontend.
  It removes the simultaneous-amplifier BUS that watchdogs FF1 and exposes
  only independently selectable earpiece and R/bottom-candidate outputs.
- `hardware-interfaces/0007-use-direct-cs35l43-high-rate-route.patch` aligns the
  Android sidecar with the raw-stable D0 path: EP1/source-0 is the only
  enabled TDM route, the ordinary CS35L43 `PCM Source` is held at `Zero`, and
  only `High Rate PCM Source=ASPRX1` feeds the 192 kHz DAC input. Ownership and
  cleanup verify EP1 on and the legacy US route off, then force both routes off
  before restoring the saved codec state. Stock `mixer_paths.xml` routes are
  intentionally unchanged because they belong to Google's ordinary primary
  HAL rather than the explicitly addressed PowerPhone sidecar. The patch also
  removes the optional sidecar's `onrestart restart audioserver`: binder death
  must fail research streams, not bypass the early certification gate or
  restart platform audio from a vendor-owned research service.
- `hardware-interfaces/0008-do-not-request-undefined-device-gain.patch` leaves
  the optional gain absent from the sidecar's initial device configs. The BUS
  ports expose no gain controls, so a present default-constructed gain is still
  an invalid request and causes the generic AIDL module to reject AudioPolicy's
  startup probe before the devices can be marked available.
- `hardware-interfaces/0009-keep-mixer-io-off-realtime-playback.patch` removes
  full mixer-control audits from the input and output transfer paths. Those
  dozens of synchronous reads starved PCM0,D0 and caused xrun recovery and an
  eventual AoC watchdog. Full ownership checks remain at route setup and before
  cleanup; the real-time path checks only the boot certificate and in-process
  lease before blocking PCM I/O.
- `hardware-interfaces/0010-expand-powerphone-playback-ring.patch` decouples
  a provisional 40 ms framework/FMQ buffer from the independently tested PCM0,D0
  480-by-four ALSA geometry. The HAL opens the fixed 1,920-frame AoC frontend
  ring explicitly and splits larger framework transfers into complete-ring
  writes without intervening mixer I/O. Patch 0012 supersedes the framework
  queue geometry and write subdivision while retaining the decoupling.
- `hardware-interfaces/0011-make-powerphone-pcm-activation-xrun-strict.patch`
  zero-initializes tinyALSA profile/config storage, validates the full exact
  PCM format, and makes the EP1/D10 bind the final mixer ioctl before PCM open.
  The framework queue remains decoupled, while PCM0,D0 writes use its 480-frame
  hardware period. Capture and playback fail closed on every observed xrun,
  including tinyALSA's internally recovered underruns, and log the PCM error;
  complete mixer ownership is audited only after PCM has closed.
- `hardware-interfaces/0012-match-qualified-pcm-rings-and-thresholds.patch`
  exposes a 1,920-frame (10 ms) framework/FMQ queue in both directions while
  explicitly retaining PCM0,D10's 1920-by-four ALSA ring and PCM0,D0's
  480-by-four ALSA ring. D0 uses the raw-stable tinyplay one-period start
  threshold and is fed in 480-frame hardware periods.
- `hardware-interfaces/0013-prime-asynchronous-speaker-sink.patch` performs
  bounded silent D0 priming before any client audio is consumed and records
  the resulting xrun baseline. Every subsequent client-time xrun remains
  fatal.
- `hardware-interfaces/0014-reopen-startup-eio-before-client-audio.patch`
  permits close/reopen recovery only when the asynchronous AoC sink returns a
  negative EIO during silent startup, while keeping EP1 bound. This exception
  is unavailable after client audio begins.
- `hardware-interfaces/0015-require-clocked-speaker-prime.patch` rejects
  write-count-only false stability while AoC accepts silence faster than its
  sink can consume it. It requires a 100 ms warm-up and 32 clean periods
  spanning at least 60 ms of their nominal 80 ms before client audio begins.
- `hardware-interfaces/0016-isolate-and-defer-legacy-d0-transport.patch`
  supersedes the final playback transaction, queue, and priming behavior from
  patches 0012--0015. It statically embeds legacy tinyALSA behind a
  scalar-only, version-scripted C facade so its private PCM object cannot be
  interposed with `libtinyalsav2`. At this point playback remained
  `SCHED_OTHER`; it defers EP1
  binding and PCM open until the first complete nonzero client burst, exposes
  a 7,680-frame framework queue, and submits only complete 1,920-frame rings
  through the legacy blocking byte API. It also skips the generic playback
  `SYNC_PTR` position refinement that made the following D0 `WRITEI` fail,
  keeps capture at FIFO/3, and closes the legacy PCM before route teardown.
  Every observed playback xrun or nonzero write status remains fatal.
- `hardware-interfaces/0017-split-powerphone-output-probe-ports.patch` gives
  the earpiece and bottom BUS sinks distinct normal output mix ports. Android
  probes address-distinguished attached outputs separately; sharing one mix
  port made both probes reuse one AIDL port config, so the second open was
  rejected and neither device received a framework Port ID. The exact BUS
  addresses, S32/stereo/192 kHz profile, float-client conversion, and global
  PCM0,D0 playback lease remain unchanged.
- `hardware-interfaces/0018-require-qualified-fifo90-playback.patch` promotes
  the playback worker to `SCHED_FIFO/90` before it can acquire or bind the
  asynchronous AoC route, and fails the start if promotion is unavailable.
  The service RT-priority limit is raised from 10 to 90. This matches the
  60-second real-device D0 byte-transfer run which completed with zero xruns
  at FIFO/90; its otherwise-identical `SCHED_OTHER` run recovered an EPIPE.
  Later elapsed-time evidence proved the q48 path consumes at 48 kHz rather
  than its declared 192 kHz, so this is a stability constraint, not physical
  192 kHz qualification. Capture keeps its independently qualified FIFO/3
  policy, and no software-time pacer is introduced.
- `hardware-interfaces/0019-match-tinyplay-params-preflight.patch` reproduces
  the qualified legacy `tinyplay` transaction that precedes its configured
  PCM open with `pcm_params_get()`. That call temporarily opens PCM0,D0,
  issues `HW_REFINE`, and closes it; Frankel's AoC driver makes this lifecycle
  hardware-visible by allocating and releasing the audio service, workqueue,
  ring snapshot, and interrupt handler. The facade checks the same rate,
  channel, sample-bit, period-size, and period-count bounds before its real
  open. A focused test fixes the preflight/free/open ordering and preserves
  the existing blocking RW-interleaved geometry and threshold contract.
- `hardware-interfaces/0020-scope-d0-pcm-open-wait.patch` reproduces the
  stable raw D0 startup window by saving the card-wide
  `PCM Stream Wait Time in MSec` control, setting it to 200 immediately before
  the final EP1 bind and PCM open, then restoring it as soon as `pcm_open()`
  returns. Every setup and cleanup failure retries restoration, and a failed
  restore is terminal. This narrows the compatibility setting to the driver's
  `hw_params` snapshot without changing another ALSA client's later opens.
  It is only a D0 startup-stability result: q48/source0 consumed 960,000
  nominal 192 kHz frames in 19.98 seconds (an actual 48 kHz clock), so native
  q192 and physical-bandwidth qualification remain unresolved.
- `hardware-interfaces/0021-use-qualified-native-q192-speaker-path.patch`
  moves the sidecar from that q48 compatibility transport to the direct-test
  contract: q192/source0, two S32 TDM slots at 12.288 MHz, PCM0,D0
  S32_LE/stereo/192000 with 1920-by-two geometry and a one-period 1,920-frame
  start threshold. It prepares once, then bypasses tinyALSA-v1's state-resetting
  `pcm_write()` path with raw `SNDRV_PCM_IOCTL_WRITEI_FRAMES`. The first
  1,920-frame submission has no retry; only the second submission at byte
  offset 15,360 receives the hardware-qualified bounded EFAULT retry. Every
  later failure and all xruns remain terminal. The 7,680-frame framework/FMQ
  transaction remains decoupled from the 3,840-frame ALSA ring. Both physical
  amplifiers passed direct native-q192 tests with this geometry and the
  one-period-lag D0 module. A complete ten-second speaker payload and concurrent
  D10 transport both completed with the 1,920-frame start threshold. These
  results establish native 192 kHz clock/cadence. Because both Cirrus codec
  `Digital PCM Volume` controls reset to zero, the route snapshots and sets
  only the selected endpoint to the stock value 817 (`Digital PCM Volume` for
  earpiece, `R Digital PCM Volume` for bottom). Ownership checks cover that
  selected control, and cleanup restores it only after both amplifiers and EP1
  have been proved hard-off; the inactive endpoint control is never touched;
  endpoint bandwidth still requires independent Nyquist-domain measurement.

## Retired experiments

An earlier Frankel experiment added 96 kHz and 192 kHz profiles to
`hardware/interfaces/audio/aidl/default/Configuration.cpp`, selected by
`ro.product.device=frankel`. It was removed from the active patch stack after
the extracted VINTF and service binary established that Pixel 10 registers the
proprietary `android.hardware.audio.service-aidl.aoc` primary module instead of
the AOSP example/default implementation. That proprietary HAL's built-in
output table fixes primary, deep, raw, and mmap playback at 48000 Hz. A
separate dynamic ALSA profile helper contains 192000 Hz but is used for USB
discovery, not the built-in speaker mix ports. The ownership and binary
evidence are retained in
[`../docs/frankel-audio-api.md`](../docs/frankel-audio-api.md).
