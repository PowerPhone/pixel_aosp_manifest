# USF flicker/direct-PDM capture harness

`usf_flicker_capture` is a header-free research harness for the private Pixel
`UsfSpectralApi`. It was reconstructed from the Frankel
`CP2A.260805.005` `vendor/lib64/libusf.so` ABI. It is deliberately inert unless
`--enable`, `--sensor`, and `--output` are all supplied.

The stock flow does **not** expose raw PDM words to the AP:

```
AoC PDM FIFO -> Direct1 software converter -> USF Flicker FlatBuffer
             -> libusf SampleConverter -> int32 callback buffer
```

The output is headerless, little-endian signed `int32` PCM. The reported sample
rate and callback/drop counters are printed on exit. A separate analysis step
must establish that the selected source, clock, and decimator are genuinely
running at the desired physical rate.

## Build

Place or copy this directory into the AOSP tree, for example:

```sh
mkdir -p vendor/csr460/usf_flicker_capture
cp /path/to/pixel_aosp_manifest/tools/audio/{Android.bp,usf_flicker_capture.cpp} \
  vendor/csr460/usf_flicker_capture/
source build/envsetup.sh
lunch aosp_frankel-trunk_staging-userdebug
m usf_flicker_capture
```

The resulting vendor binary is normally under
`out/target/product/frankel/vendor/bin/usf_flicker_capture`. Installing it in
`/vendor/bin` gives it the correct vendor linker namespace for
`/vendor/lib64/libusf.so` and its private dependencies.

## Safe probe and capture

The probe only loads the library and resolves `Create`/`Destroy`; it does not
create a client or start a sensor:

```sh
usf_flicker_capture --probe
```

An actual capture is explicit:

```sh
usf_flicker_capture \
  --enable \
  --sensor /dev/vd6282/0/flicker \
  --duration-ms 2000 \
  --output /data/local/tmp/flicker-s32le.raw
```

Frankel `CP2A.260805.005` has also been observed to finish its USF registry
connection without invoking the client `ConnectCallback`. The default remains
fail-closed. After retaining the log that proves the exact vendor service
connected and populated its sensor list, a deliberate retry may add
`--allow-missing-connect-callback`. The harness still waits the complete
connection timeout first and then uses the ordinary vendor enable API; an
enable error remains fatal and no sampling is claimed.

The sensor name above is the Frankel registry path; use the name reported by
the target build if it differs. `--output-bits 24` is the default because the
stock camera HAL uses the same value with a 2048-sample buffer.

If the registry was separately changed from optical PDM4 to a built-in PDM0-3,
make that dangerous assumption visible at invocation time:

```sh
usf_flicker_capture \
  --enable --ack-pdm-reroute 0 \
  --sensor /dev/vd6282/0/flicker \
  --duration-ms 2000 \
  --output /data/local/tmp/pdm0-s32le.raw
```

`--ack-pdm-reroute` does not change or validate the registry. This utility never
edits firmware, registry, PDM routing, mixer state, or SELinux policy.

## Access and ABI constraints

Frankel grants `/dev/aoc` and `acd-com.google.usf*` as `0660 system:system`, and
SELinux permits the camera/sensors/audio HAL domains rather than ordinary shell
or app domains. Run the harness from a suitable research domain, or explicitly
use the userdebug image's root/permissive workflow. The program does not change
SELinux state itself.

The private ABI assumptions are guarded in the source:

- callback vtable `+0x10`: sensor event (ignored);
- callback vtable `+0x18`: flicker data;
- callback vtable `+0x20`: connection complete;
- API vtable `+0x28`: `EnableFlickerSensor`;
- API vtable `+0x38`: `DisableFlickerSensor`;
- API vtable `+0x98`: `SetFlickerChannel`;
- callback data offsets `+0x0c` count, `+0x10` sequence, `+0x14` reported
  sample rate, and `+0x28` `int32_t*` samples.

Re-audit those offsets before using the harness with another Pixel generation
or `libusf` release.
