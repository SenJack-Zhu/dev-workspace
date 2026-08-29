# Voice Integration Device Gate

This gate covers the device-only behavior that cannot be proven by Dart tests.
Run it when the iOS or Android runner is assembled for a release. The current
repository does not contain committed `ios/`, `android/`, or `macos/` runner
directories, so platform manifests are intentionally not added by the voice
feature change.

## Required platform declarations

- Android: declare `android.permission.RECORD_AUDIO` in the release runner.
- iOS: add non-empty `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription` values to the release runner.
- macOS, when supported: add microphone and speech-recognition usage strings
  and the matching sandbox audio-input entitlement.
- Confirm that the release build includes the `permission_handler`, `record`,
  and `speech_to_text` platform implementations for its targets.

## Automated gate

Run before device testing:

```sh
flutter analyze
flutter test
```

The automated suite simulates granted, denied, permanently denied, and
unavailable permissions; partial and final system transcripts; remote
recording, cancellation, and timeout; app background interruption; audio-route
events; consecutive messages; editable drafts; optional auto-send; TTS queue
and cancellation; mouth closure; and typed-chat fallback.

## Device matrix

Test one supported iOS device and one supported Android device. Repeat the
system STT checks with at least one installed language and one language whose
offline pack is not installed.

| Scenario | Expected result |
| --- | --- |
| First microphone request | The OS prompt appears only after starting voice input. Granting starts recognition. |
| Denied permission | Voice input stops with a recoverable message. Typed text remains editable and sendable. |
| Permanently denied permission | The recovery action opens the app's system settings. Returning to the app allows a retry. |
| System recognizer unavailable | The failure is shown without clearing or disabling the text draft. |
| Hold and release | Pressing starts recognition, partial text updates the draft, and releasing produces editable final text. |
| Explicit cancel | Recording/recognition stops and the exact pre-recording draft is restored. |
| Auto-send | A non-empty final transcript sends exactly once. Empty or failed recognition never sends. |
| Headset to speaker and speaker to headset | The OS may change the audio route; the active STT/TTS session does not terminate solely because the route changed. |
| Lock screen or app background | Active recording, recognition, remote request, playback, queue, and Live2D mouth motion stop. Mouth value returns to zero. |
| Consecutive messages | A late result from the previous session never changes the next draft or sends a duplicate message. |
| External provider missing configuration | No permission prompt, recording, or HTTP request occurs. Text chat remains available. |
| External timeout or cancel | The request ends within the configured timeout or immediately on cancel, and the next request can start cleanly. |
| Pure text regression | Voice disabled, permission denied, offline, and provider failure states do not change normal typing or sending. |

## Platform limitations

- System STT offline behavior is controlled by the operating system, selected
  locale, and installed language packs. Enabling system STT does not guarantee
  offline recognition.
- Headset, Bluetooth, receiver, and speaker routing are managed by the OS. The
  app treats route changes as non-terminal but cannot force every route on every
  device.
- Mobile operating systems can interrupt microphone and audio sessions for
  calls, alarms, lock screen, or background policies. NativeTavern cancels the
  active voice session rather than attempting background capture.
- Remote STT and TTS remain optional BYOK features. System voice and typed chat
  must remain usable without remote credentials.
