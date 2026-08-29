# Live2D release gate

NativeTavern treats Live2D runtime code, proprietary binaries, and model data
as pinned third-party inputs. The engineering gate verifies their provenance,
integrity, required notices, and physical-device behavior. Commercial licensing
decisions are outside this engineering gate and do not block it.

## Pinned inputs

- Mobile bridge: `flutter_live2d` 1.0.2 from an immutable upstream Git
  revision. The pub.dev 1.0.2 archive is not used because it omits the Android
  Framework shaders; the complete 36-file shader set is pinned by a tree
  SHA-256 in `config/live2d_release_manifest.json`.
- Cubism Core: runtime version 6.0.1. Every Android, iOS, simulator, and macOS
  binary is pinned separately by SHA-256.
- Cubism Framework: the source snapshot shipped by `flutter_live2d` v1.0.2.
  Android, iOS, and macOS sentinel files must remain byte-identical.
- Hiyori Momose FREE: only the runtime subset is bundled. Every file is listed
  and hashed; an unlisted file under the asset root fails the gate.

Run the provenance and integrity audit during development:

```sh
dart run tool/live2d_release_gate.dart --development
```

Run the stricter gate before producing a distributable build:

```sh
dart run tool/live2d_release_gate.dart
```

The release command fails until Android and iOS physical-device runs are marked
`verified` and link their captured test reports.

Imported user models remain application data and are never copied into a
release bundle. Any new bundled model directory must be added to the manifest
with its source, required notice, release approval, complete file inventory,
and SHA-256 values. Merely adding a directory to `pubspec.yaml` fails the gate.

## Mobile evidence protocol

Use a release-mode build on at least one supported physical Android device and
one supported physical iPhone or iPad. Record device, OS, build commit, start
and end measurements, and attach profiler exports. Each report must cover:

- transparent compositing over light and dark chat backgrounds;
- stage clipping at all edges and the supported scale range;
- one-finger chat scrolling, two-finger model transform, tap, and double-tap;
- at least 20 character transitions, followed by a second 20-transition pass;
- background rendering stopping and resuming without a blank or frozen view;
- 30 minutes of idle animation plus 10 minutes of repeated interactions;
- frame timing, resident memory, CPU, energy/battery, and thermal state;
- final memory returning within 25 MiB or 10 percent of the post-warmup value,
  whichever is larger, with no growth between the two transition passes.

Do not mark a platform `verified` from an emulator or simulator run. Those runs
are functional regression evidence only and cannot establish power, thermal,
or physical GPU baselines.
