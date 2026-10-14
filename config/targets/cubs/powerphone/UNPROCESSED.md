# Framework UNPROCESSED capability: existing Cubs overlay

No additional research RRO is necessary. The generated donor overlay already
sets `config_supportAudioSourceUnprocessed` to `true`:

- `work/aosp/vendor/google_devices/cubs/overlays/framework-res__cubs__auto_generated_rro_vendor/res/values/values.xml`
- Module `framework-res__cubs__auto_generated_rro_vendor`, already included by
  `work/aosp/vendor/google_devices/cubs/cubs.mk`.
- Static vendor overlay targeting package `android`; generated manifest package
  is `android.auto_generated_rro_vendor__`.

The existing built
`out_pixel/cubs/target/product/cubs/vendor/overlay/framework-res__cubs__auto_generated_rro_vendor.apk`
also contains this boolean as `true`, read directly with the tree's `aapt2 dump
resources`. The framework's unoverlaid default is `false`.

`AudioManager.getProperty(PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED)` reads this
framework resource, not an AIDL IConfig method. The replacement raw capture
implementation and empty effects factory are separate requirements: this flag
alone does not demonstrate unprocessed hardware, 192 kHz transport, or API
qualification.

The saved `baseline-20260922/framework-audio.txt` contains no direct resource or
public-property readback, so do not claim that snapshot proves the resolved
runtime value. The device-owning operator must verify it after boot:

```sh
adb shell cmd overlay lookup --user 0 --verbose android \
  android:bool/config_supportAudioSourceUnprocessed
```

Also retain the app's `UNPROCESSED source property: true` line from
`MainActivity` and the active AudioRecord source/device format/effects report.
Research reference capture now fails rather than falling back to `MIC` when
the public property is false. No device command was executed during this
offline inspection, and no redundant overlay/package change was made.
