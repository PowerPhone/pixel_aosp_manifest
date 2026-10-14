# Cubs native early-boot firmware applier

`cubs_powerphone_boot --apply` embeds the hardware-tested **mono receiver
edge0 / RAW MCPS112 + D5 two-slot192 ENTRY96** closure. It does not include
RAW3, install kernel modules, alter amplifier tuning, or qualify a new
packaged image. The original OEM-authenticated AoC binary remains unchanged.
`--status` prints properties and the current boot/AoC generation without writes.
`--check-idle` performs only the kernel PCM reservation queries, reports the
device/stream counts and required D5/D10 closure, and returns nonzero if any
reservation is open. It does not change readiness, mixers, or firmware.

## Build and stage

From the repository root:

```sh
python3 tools/audio/cubs/generate_boot_profile.py
bash tools/audio/cubs/build-boot-helper.sh
```

The actual Android binary is
`work/audio-research/cubs/bin/cubs_powerphone_boot`.
The generator takes the explicit qualified mono MCPS112 manifest and v5
speaker template, checks their geometry and ENTRY96, embeds exact before/
after bytes into `profile_generated.h`, and copies the proven generic native
factory transport to `factory_transport.inc`. No hash checks or mock tests
are used. Optional `--capture`, `--speaker`, and `--output-dir` generator
arguments support explicit staging; unsupported profile geometry rejects.

Copy this complete generated directory into the product's selected vendor
source directory and select the supplied `Android.bp` module
`cubs_powerphone_boot`. No init RC or policy is installed implicitly. The
standalone build script uses the same Android compiler/sysroot/CRT settings
as `build-diag.sh`; overrides are `AOSP_DIR`, `AOSP_CLANG_ROOT`,
`AOSP_NDK_SYSROOT`, and `AOSP_CRT_ROOT`. The binary uses libc/C++ only and
stable ALSA control ioctls, not a potentially mismatched tinyALSA runtime.

## Required init ownership

The platform gate must hold `audioserver` stopped and exclude the original
`vendor.audio-hal-aidl` service. Its state may be absent or `stopped`, never
running/restarting. The distinct `vendor.audio-hal-powerphone-cubs` may
register inert, but must reject streams until the complete contract below.
The helper does not read the platform-private `init.svc.audioserver` property.
Platform init must mirror its stopped/running state to the vendor boolean
`vendor.powerphone.cubs.audioserver_stopped=1/0`; the helper requires `1`.
For a manual root trial, stop AudioServer and explicitly set that mirror to1
before invoking `--apply`. Never set the mirror while AudioServer is running.
Start the native helper asynchronously after data is available; do not block
init's module/node creation actions with `exec_start`.

There is no `sys.boot_completed` dependency or fixed warm-up sleep. The helper
waits up to60 seconds for observable AoC factory/debug/control nodes, readable
generation counters, excluded ordinary owners, and initialized controller
roots. All subsequent exact map, ABI, firmware, and idle-control guards must
pass before mutation. An unopened D5 with zero kind/geometry/ring fields is
valid at early boot; the runtime speaker shim enforces its running geometry.
The helper enumerates card0 PCM devices with `SNDRV_CTL_IOCTL_PCM_NEXT_DEVICE`
and queries every direction/subdevice with `SNDRV_CTL_IOCTL_PCM_INFO`.
`subdevices_avail` must equal `subdevices_count`, and D5 playback plus D10
capture must both exist. The kernel counts opened reservations, so an open
but inactive PCM also fails. Missing/unreadable or unexpected queries reject;
only `ENOENT` for a device's absent direction is skipped. This avoids broad
cross-process FD/ptrace permissions and does not depend on verbose PCM
procfs, which is disabled on the actual Cubs kernel.

The helper owns the native transport for the whole transaction under the
same `/data/vendor/powerphone/.aoc-patch.lock` as diagnostic tools. It reads
the actual A32 MB2/MB3 cached/noncached descriptors, resolves current D5
objects through the independently derived Cubs roots and vtables, requires
a uniform stock profile, installs bodies before hooks and Stream2 last,
and uses the retained coherent wrapper through HD command0x12a4. A fresh
F1 completion64 is mandatory; successful ioctl or memory readback alone
does not establish instruction-cache synchronization. The dispatch is
restored, every modified region read back, and boot/restart/coredump
generation checked before publication. No retry follows a mutation failure.

## Readiness and failure contract

The helper clears readiness/profile/boot properties first, then sets
`vendor.powerphone.cubs.boot.phase=applying`. After complete readback:

```text
vendor.powerphone.cubs.profile=mono192-edge0-mcps112-d5-two-slot-v5
vendor.powerphone.cubs.boot_id=<current /proc/sys/kernel/random/boot_id>
vendor.powerphone.cubs.capture.ready=1
vendor.powerphone.cubs.playback.ready=1
vendor.powerphone.cubs.boot.phase=ready
```

Profile and boot ID precede readiness; phase `ready` follows both bits.
`/data/vendor/powerphone/cubs-boot-generation.txt` is atomically replaced
with profile/UUID/restart0/coredump0 before publishing readiness. The HAL
must require both bits, exact profile, current UUID, and AoC counters0/0.
Properties alone must not survive an AoC restart as authority for streaming.

The exact direct-wrapper markers are also produced:

- `/dev/powerphone-cubs-mono192`: empty quarantine, created immediately
  before mutation and retained if firmware state becomes uncertain.
- `/dev/powerphone-cubs-direct192`: empty, only after complete readback.
- `/dev/powerphone-cubs-tdm-slots`: exactly `2\n`, only after complete readback.

A caught failure clears both ready bits/profile/UUID, sets phase `failed`,
and removes any qualified playback/slot markers it created. It does not
restart audio or reboot the device itself. If mutation began, a cold reboot
is required. An outer init timeout must also treat service exit while phase
`applying` as failure; initial phase `waiting` avoids the initial-stopped race.
Failure recovery may release the UI with an inert HAL, but must never
publish audio readiness. Native alarm120 seconds is a final bound if a syscall
hangs; an init service timeout may be shorter.

## SELinux and file interfaces for the product integrator

This directory deliberately does not broaden product policy. The integrator
must permit the dedicated domain to:

- Read/write `/dev/acd-factory_diag`; read `/dev/acd-debug`; use their ioctls
  and the shared transaction lock.
- Read/write `/dev/snd/controlC0`, including ALSA element-info/read/write
  ioctls. The only control write is the guarded HD Mic gain0 cache trigger.
- Read product/init properties, current boot UUID, and AoC restart/coredump
  sysfs counters under `/sys/devices/platform/a800000.aoc/`.
- Use card0 control ioctls `PCM_NEXT_DEVICE` and `PCM_INFO` to reject open
  reservations, including inactive streams. No process FD/ptrace access or
  verbose PCM procfs is needed.
- Create the three specifically named `/dev` marker files and access
  `/data/vendor/powerphone/` for lock and generation-stamp creation/rename.
  Failure cleanup additionally needs `remove_name` on the `/dev` directory
  and unlink permission for its own qualified marker files.
- Set the five vendor properties above. Phase values are
  `waiting applying ready failed`; readiness values are0/1.

The first real boot and subsequent Java/AAudio/ordinary-audio measurements
remain the qualification of the integrated product, not this successful build.
`CUBS_BOOT_TIMING` records elapsed and monotonic milliseconds for prerequisite
readiness, completed guards, patch installation, cache completion, and final
readiness; these are actual runtime timings, not fixed delays.

The first manual native trial installed the41 regions but failed opening
`acd-debug` a second time during cache dispatch setup. That device is
single-reader. The corrected helper arms the dispatch using the factory
transport first, then owns one debug descriptor only across drain/HD ioctl/
completion, and closes it before guarded restoration. This reproduces the
successful host-applier ordering; the original failed trial requires reboot,
not an in-place retry.
The corrected second manual root invocation completed the41 regions, fresh
cache completion64, and all readbacks in3.919 seconds with AoC counters0/0.
That validates native application ordering, not the newly integrated image or
the subsequent enforcing-domain PCM-info ownership gate.
