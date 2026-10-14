# Experimental primary-HAL trial flashing

This narrow runner is for the separately assembled Cubs primary-HAL boot
trial, **not** a qualified release or full flash-all package. It does not
build images, prove their acoustic behavior, or expand the direct-profile
qualification in the other runbooks.

Place `vendor.img` and `system_ext.img` in an explicit trial directory.
Optionally include the intended matching `vendor_kernel_boot.img` and
`vbmeta.img`. Those are the only four accepted image names; all other
partitions remain untouched. Keep original backup images separately.

From WSL, at the repository root:

```bash
# Local image/plan check only: no device queries, reboot, or writes.
bash scripts/audio/cubs/flash-primary-trial.sh \
  --serial YOUR_CUBS_SERIAL --image-dir /absolute/path/to/NEW_TRIAL_IMAGES

# Explicitly authorize the limited writes and final Android reboot.
bash scripts/audio/cubs/flash-primary-trial.sh \
  --serial YOUR_CUBS_SERIAL --image-dir /absolute/path/to/NEW_TRIAL_IMAGES \
  --flash --reboot
```

The script uses this workspace's platform-tools37.0.1, `ADB_LIBUSB=1`, and
ADB port5038 only. It can start from normal ADB, bootloader fastboot, or
fastbootd. Exact serial matching, `product=cubs`, `unlocked=yes`, and a
valid unchanged current slot are required. It never switches slots.

Physical images are written in **bootloader fastboot**. When `vbmeta.img`
is present, its flash uses `--disable-verity --disable-verification`.
Only `vendor_<slot>` and `system_ext_<slot>` are written in **fastbootd**,
after confirming both are logical partitions. Each USB transition has a
60-second bounded wait with one-second polling; individual commands also
have deadlines. No implicit server on port5037 is used.
Platform-tools may print either `fastboot` or `fastbootd` in its device list;
the authoritative mode remains `getvar is-userspace`. A reboot request may
return nonzero or time out after USB has already transitioned. The runner
records that status, then accepts the transition only after the exact serial
arrives in the requested mode and product/unlock/unchanged-slot guards pass.
Image-write commands themselves remain fail-fast and are never silently retried.

Commands and their stdout/stderr are copied to a fresh
`flash-primary-trial-<UTC timestamp>-<pid>.log` beside the images and shown
on stdout. There are no hashes, user-data wipes, bootloader/radio updates,
unrelated partition flashes, or automatic rollback. An error stops the run
and preserves the log; earlier successful writes may already be present.
Without `--reboot`, success leaves the device in fastbootd. With it, even a
nonzero reboot-command status can be resolved by bounded arrival of that exact
serial on ADB with `ro.product.device=cubs`; this is not boot completion.
Boot completion,
enforcing-policy readiness, UI audio, Java/AAudio and physical waveform
qualification are subsequent real-device checks. A later release bundle
and full flash-all workflow must be prepared and qualified separately.
