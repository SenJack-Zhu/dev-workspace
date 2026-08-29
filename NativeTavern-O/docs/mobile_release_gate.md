# Mobile release gate

This gate is the final iOS and Android release decision for NativeTavern. A
simulator or emulator run is useful regression evidence, but it never qualifies
as a device pass.

## Commands

Run the repeatable automated checks during development:

```sh
tool/run_mobile_release_checks.sh
```

This runs the full Flutter test suite, changed-file formatting check, Live2D
artifact and license inventory audit, and mobile evidence manifest audit.

Run the strict gate after recording physical-device evidence for the current
commit:

```sh
tool/run_mobile_release_checks.sh --release
```

The strict command also runs the Live2D release audit. It requires available
iOS and Android runners, a release-mode run on each physical platform, all
matrix scenarios, the declared performance metrics, and evidence paths or
HTTPS links. It rejects device identities that contain `simulator` or
`emulator` even if `isPhysical` is set incorrectly.

## Commit and evidence order

Physical testing must use a committed, reproducible release build. Commit the
release candidate before installing it, then record and commit the resulting
evidence. The strict gate accepts a tested commit when every later change is
limited to `release_evidence/` or to the `releaseEvidence` object in the Live2D
manifest. It rejects any source, dependency, asset, or other configuration
change after the tested commit and requires a clean worktree.

This permits evidence to reference the exact binary commit without creating a
self-referential SHA requirement. Any runtime change requires rebuilding and
rerunning both physical-device matrices.

## Device protocol

Use `flutter devices --machine` before each run. Select one supported physical
Android device and one supported physical iPhone or iPad. Record the full Git
SHA from `git rev-parse HEAD`; debug/profile results do not qualify.

Build and install the same release commit with the repository release scripts:

```sh
./build_android.sh
./build_ios.sh
```

Do not replace these with direct Flutter, Gradle, or Xcode packaging commands.
The scripts configure the expected platform projects and produce the named
release artifacts used by the distribution workflow. See
`docs/release-runbook.md` for the complete packaging and publishing sequence.

Run every scenario in `config/mobile_release_gate.json`. Each platform covers:

| Scenario | Device setup | Release decision |
| --- | --- | --- |
| Offline | Airplane mode, Wi-Fi and mobile data off | Local data and typed chat remain responsive; external failures are clear. |
| Weak network | High latency, packet loss, and constrained bandwidth | Timeout/cancel recovers without duplicate sends, frozen controls, or lost drafts. |
| Permission denied | Deny microphone, speech, photos, and files at the OS prompt | Denial is recoverable and typed chat remains available. |
| Low memory | Apply OS memory pressure while backgrounded | Resume coherently or restore persisted state without corruption. |
| Foreground/background | Transition during generation, voice, Live2D, and idle text chat | Media work stops safely and state resumes coherently. |
| Performance | Profile at least 30 minutes in release mode | Every metric stays within the manifest thresholds without sustained growth. |
| Features disabled | Disable memory, RPG, Data Bank context, voice, Live2D, tools, and MCP | Create/send/swipe/edit/reopen text chat with no new permission prompt or external call. |

Use OS-supported controls for network conditioning and memory pressure. Do not
substitute a mocked service for the physical low-memory, lifecycle, permission,
power, thermal, or GPU portions.

## Evidence

Store run metadata in `release_evidence/mobile_release_runs.json`. A qualifying
run has this shape:

```json
{
  "id": "ios-2026-08-08",
  "platform": "ios",
  "device": {
    "id": "physical-device-id",
    "model": "iPhone model",
    "osVersion": "iOS version",
    "isPhysical": true
  },
  "buildMode": "release",
  "buildCommit": "40-character-lowercase-git-sha",
  "startedAt": "2026-08-08T08:00:00Z",
  "completedAt": "2026-08-08T08:45:00Z",
  "automatedChecks": {
    "fullTestSuite": "passed",
    "formatCheck": "passed",
    "live2dDevelopmentAudit": "passed",
    "manifestAudit": "passed"
  },
  "scenarios": {
    "offline": {
      "status": "passed",
      "evidence": [
        {"type": "screenRecording", "location": "release_evidence/ios/offline.mov"},
        {"type": "deviceLog", "location": "release_evidence/ios/offline.log"}
      ]
    }
  },
  "metrics": {
    "sampleMinutes": 30,
    "startupMilliseconds": 1200,
    "typedChatP95Milliseconds": 90,
    "frameBuildP95Milliseconds": 12,
    "frameRasterP95Milliseconds": 11,
    "droppedFramePercent": 0.4,
    "memoryGrowthMiB": 18
  }
}
```

Include all seven scenario objects, not only the abbreviated example above.
Evidence may be a repository-relative file or an HTTPS artifact link.

## Failure records

Set a failed or blocked scenario's `status`, attach its `failureId`, and add a
record to the top-level `failures` list:

```json
{
  "id": "MOBILE-2026-001",
  "platform": "android",
  "scenario": "foregroundBackgroundRecovery",
  "summary": "Draft cleared after process recreation",
  "observedAt": "2026-08-08T09:10:00Z",
  "reproductionSteps": [
    "Open a populated chat",
    "Type without sending",
    "Background and apply memory pressure",
    "Return to NativeTavern"
  ],
  "evidence": [
    "release_evidence/android/MOBILE-2026-001.log",
    "release_evidence/android/MOBILE-2026-001.mp4"
  ]
}
```

The release gate remains failed until a current-commit physical run passes the
scenario. Preserve failed records as regression history rather than deleting
them.
