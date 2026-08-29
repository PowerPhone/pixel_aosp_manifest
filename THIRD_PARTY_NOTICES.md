# Third-party notices

This repository's Apache-2.0 license applies only to project-authored files.
It carries the source patch deltas and exact license notices identified below,
but it does not redistribute downloaded binary inputs, extracted proprietary
files, generated vendor modules, or assembled images.

## Android Open Source Project

AOSP source is fetched from Android's repositories at the revisions recorded in
the resolved Repo manifest. Individual projects carry their own license files,
predominantly Apache-2.0. The imported patches listed in `patches/README.md`
target the GrapheneOS forks of AOSP `build`, `build/soong`, `frameworks/base`,
`system/sepolicy`, and `tools/apksig`; their commit links and authorship are
preserved. Project-authored adapters to AOSP files remain under the applicable
Apache-2.0 terms unless an embedded patch header states otherwise.

## GrapheneOS projects

The local manifest fetches these pinned GrapheneOS projects, each carrying its
upstream MIT license:

- `GrapheneOS/adevtool` ([notice](LICENSES/adevtool-MIT.txt))
- `GrapheneOS/vendor_state` ([notice](LICENSES/vendor-state-MIT.txt))
- `GrapheneOS/platform_tools_arsclib` ([notice](LICENSES/arsclib-MIT.txt))
- `GrapheneOS/platform_packages_apps_CarrierConfig2`
  ([notice](LICENSES/carrierconfig2-MIT.txt))

The source checkout retains their license texts and the pinned shallow history
needed for the selected commits. Exact copies of their notices are kept under
`LICENSES/` so the published compatibility patches retain the upstream
permissions and attributions. The patches do not copy their binary outputs.

## Google downloads

Google Pixel factory/OTA images and Android SDK Platform-Tools are downloaded
directly from Google and are not covered by this repository's license. They are
excluded from Git. Review Google's Pixel image terms and Android SDK terms
before running the download/setup scripts or distributing any derived work.

## usbipd-win

The tested Windows USB-forwarding prerequisite is upstream
[`usbipd-win v5.3.0`](https://github.com/dorssel/usbipd-win/tree/v5.3.0),
licensed `GPL-3.0-only`; see its pinned upstream
[`COPYING.md`](https://github.com/dorssel/usbipd-win/blob/v5.3.0/COPYING.md).
This repository records installer and installed-payload identities but does
not redistribute the MSI, executable, drivers, or installed tree.

## Other host tools and packages

The workspace-local Node.js runtime, Yarn package manager, pinned Repo
implementation, and Ubuntu host packages retain their upstream licenses. Their
archives and installed trees are excluded from Git.
