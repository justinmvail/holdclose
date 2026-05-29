# Bundled neural TTS — iOS (Phase 9.3) + Android (Phase 9.4)

> Phase 9.3 ships the iOS side of the bundled Piper voice; Phase 9.4
> mirrors it on Android. Phase 9.7 will append the cross-platform
> overview, failure-fallback narrative, and voice-catalog swap guide —
> keep this doc lean for now.

## What lands in 9.3

- `onnxruntime-objc 1.18.x` Pod added to `ios/Podfile`.
- `ios/Runner/TTSBridge.swift` — owns the `ORTSession`, AVAudioEngine
  player node, voice-config parser, and an espeak-ng phonemizer
  protocol. The bridge registers the `careblazers/tts` MethodChannel
  and handles `speak`, `cancel`, `availableVoices`.
- `ios/Runner/AppDelegate.swift` — replaces the Phase 9.2 stub with a
  single call to `TTSBridge.register(with:)`.
- `ios/Runner.xcodeproj/project.pbxproj` — TTSBridge.swift registered
  as a Sources build-phase file.
- `ios/RunnerTests/RunnerTests.swift` — hermetic config-parser +
  phonemizer tests; the model-load + RMS test runs when the .onnx is
  reachable, otherwise skips.

## CoreML execution provider

`TTSEngine.ensureLoaded` initialises an `ORTSession` with the CoreML
execution provider enabled (`enableOnSubgraph = true`,
`onlyEnableForDevicesWithANE = false`). On A14+ devices the graph
runs on the Neural Engine; older devices and the simulator fall back
to CPU. The fallback is transparent — no code path branches on
device class — but expect 1–3 s of first-token latency on CPU.

## Phonemizer status

The espeak-ng wrapping is stubbed behind the `Phonemizer` protocol.
`EspeakNGPhonemizer` currently performs a character-by-character
lookup against `phoneme_id_map` from the voice config (BOS/EOS + pad
tokens around each grapheme). That keeps the audio pipeline alive
and the tests honest, but it isn't production-grade English
phonemization. The real espeak-ng integration lands in a follow-up:
vendor `libespeak-ng.a` + the espeak-ng-data tree into the Runner
target and route through `espeak_TextToPhonemes`.

## Manual smoke sequence

Pre-req: a real iOS device (simulator CoreML EP falls back to CPU
and adds latency, but the path still works).

```
flutter pub get
cd ios && pod install && cd ..
flutter run -d <iphone-device-id>
```

Then in the running app:

1. Land on the **Home** screen.
2. Tap **Decode a behavior**.
3. Pick any behavior tile (e.g., **Repeating questions**).
4. Step through the three triage screens, tapping any answer at each.
5. Wait for the **Result** screen to render.
6. Tap the 🔊 PLAY button on the result.
7. **Expectation**: hear Amy speak the first "say" line. First-token
   latency target is < 500 ms on A14+; CPU fallback is < ~2 s.

A passing smoke run is the audio playing through the device speaker
without distortion. If the device is silent:

- Confirm the model bundled: `flutter build ios --analyze-size`
  should show `en_US-amy-medium.onnx` in the assets envelope.
- Confirm the Pod linked: `pod install` should print
  `Installing onnxruntime-objc (1.18.x)`.
- Confirm the audio session: the bridge requests `.playback /
  .spokenAudio` — the silent switch should not mute it.
- Tail `flutter run` console output: `TTSBridge` errors surface as
  `SPEAK_FAILED` channel results, with the underlying ORT message in
  the `message` field.

## Test invocation

```
# In Xcode: ⌘U against the RunnerTests scheme.
# CLI:
xcodebuild test \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -destination "platform=iOS Simulator,name=iPhone 16"
```

The model-dependent test (`testInferenceProducesNonSilentAudio`)
skips when the .onnx isn't bundled into the test target — this is
expected until Phase 9.6's device-side acceptance run. The hermetic
tests cover the config parser, the phonemizer lookup, and the voice
catalog.

## What lands in 9.4 (Android)

- `com.microsoft.onnxruntime:onnxruntime-android:1.18.0` added to
  `android/app/build.gradle.kts`.
- `android/app/src/main/kotlin/com/careblazers/careblazers/TTSBridge.kt`
  — owns the `OrtSession`, AudioTrack player, voice-config parser,
  and an espeak-ng phonemizer interface. The bridge registers the
  `careblazers/tts` MethodChannel and handles `speak`, `cancel`,
  `availableVoices`.
- `android/app/src/main/kotlin/com/careblazers/careblazers/MainActivity.kt`
  — replaces the Phase 9.2 stub with a single call to
  `TTSBridge.register(applicationContext, flutterEngine)`.
- `android/app/src/androidTest/kotlin/com/careblazers/careblazers/TTSBridgeInstrumentedTest.kt`
  — hermetic config-parser + phonemizer tests plus a model-load + RMS
  test that skips when the `.onnx` asset isn't reachable from the
  instrumented APK.

## NNAPI execution provider

`TTSEngine.ensureLoaded` builds an `OrtSession.SessionOptions` with
`addNnapi()`. On Android 8.1+ (API 27+) NNAPI routes inference to
the device NPU / DSP; older devices and emulators fall back to CPU
transparently. Failures in `addNnapi()` (missing native binding,
NNAPI version mismatch) are logged and swallowed — ONNX Runtime
keeps the session on CPU. Expect 1–3 s of first-token latency on
the CPU fallback path; the Phase 9.6 device matrix confirms NNAPI
clears <500 ms on a Pixel 6+.

## Phonemizer status

The espeak-ng wrapping is stubbed behind the `Phonemizer` interface,
parallel to iOS. `EspeakNGPhonemizer` performs a character-by-
character lookup against `phoneme_id_map` from the voice config
(BOS/EOS + pad tokens around each grapheme) — same shape as the
Swift counterpart, same tradeoffs. The real espeak-ng integration
lands in a follow-up: vendor `libespeak-ng.so` + the
espeak-ng-data tree via JNI (or the `espeakng-java` Maven artifact)
and route through `espeak_TextToPhonemes`. The two bridges share
the follow-up — when iOS gets the production phonemizer, Android
gets the matching binding in the same iter.

## Audio output

Piper Amy emits float32 PCM at 22 050 Hz mono. The Android bridge
converts to int16 (clamped to [-1.0, 1.0] then scaled to
`Short.MAX_VALUE`) and streams to an `AudioTrack` configured for
`USAGE_MEDIA` / `CONTENT_TYPE_SPEECH`, `MODE_STREAM`, and the
host's `getMinBufferSize`. `cancel()` pauses + flushes + releases
the track so a rapid-tap on the per-line ▶ button doesn't queue
overlapping audio.

## Manual smoke sequence (Android)

Pre-req: a real Android device on API 27+ (emulators work but fall
back to CPU and add latency).

```
flutter pub get
flutter run -d <android-device-id>
```

Then in the running app:

1. Land on the **Home** screen.
2. Tap **Decode a behavior**.
3. Pick any behavior tile (e.g., **Repeating questions**).
4. Step through the three triage screens, tapping any answer at each.
5. Wait for the **Result** screen to render.
6. Tap the 🔊 PLAY button on the result.
7. **Expectation**: hear Amy speak the first "say" line. First-token
   latency target is < 500 ms on a Pixel 6+ via NNAPI; CPU fallback
   is < ~2 s.

If the device is silent:

- Confirm the model bundled: `flutter build apk --analyze-size`
  should show `en_US-amy-medium.onnx` in the assets envelope.
- Confirm the AAR pulled: `./gradlew :app:dependencies` should list
  `com.microsoft.onnxruntime:onnxruntime-android:1.18.0`.
- Tail `flutter run` / `adb logcat -s TTSBridge`: bridge errors
  surface as `SPEAK_FAILED` channel results with the underlying
  OrtException string in the `message` field.

## Test invocation (Android)

```
# Instrumented suite (model load + RMS):
cd android && ./gradlew connectedDebugAndroidTest

# Or via Android Studio: right-click TTSBridgeInstrumentedTest → Run.
```

The model-dependent test (`inferenceProducesNonSilentAudio`) skips
when the `.onnx` isn't reachable from the instrumented APK — same
contract as the iOS XCTest. The hermetic tests cover the config
parser, the phonemizer lookup, and the voice catalog.

## Phase 9.6 — device acceptance matrix

The bundled-voice path was sized for two latency regimes: A14+ / NNAPI
hardware inference (< 500 ms first-token, "snappy") and CPU fallback
on older silicon (~1–2 s first-token, "usable" not "snappy"). This
section is where the engineer pins the device matrix and the per-device
numbers each acceptance pass produces.

### Measurement methodology

Both bridges emit a `firstTokenMs` log line per `speak()` call —
wall-clock from MethodChannel invocation to the first
AVAudioEngine / AudioTrack write of non-silent PCM. Inspect via:

- iOS: `Console.app` filtered by `TTSBridge` → `firstTokenMs=<n>` per
  speak.
- Android: `adb logcat -s TTSBridge` → same field.

Protocol per device:

1. Cold-launch the app (no ORTSession cached).
2. Run through Home → Decoder → Triage → Result.
3. Tap the per-line ▶ button once to warm the session. Discard.
4. Tap ▶ five more times back-to-back. Record each `firstTokenMs`.
5. Report **median of the five** in the results table below.

Five samples filter out one-off jitter (background app churn, GC
pauses on Android, audio-route renegotiation on iOS) without
inflating the protocol. Cold ORT load is excluded — it's a one-time
session-init cost, not per-utterance latency.

### Acceptance matrix (targets)

| Device              | Path                | Target           | Verdict label    |
| ------------------- | ------------------- | ---------------- | ---------------- |
| iPhone 12 (A14)     | CoreML EP → ANE     | < 500 ms         | snappy           |
| iPhone 14 (A15)     | CoreML EP → ANE     | < 500 ms         | snappy           |
| iPhone 17 (A19)     | CoreML EP → ANE     | < 500 ms         | snappy           |
| iPhone 11 (A13)     | CoreML EP → CPU     | < 2 000 ms       | usable           |
| Pixel 6 (Tensor G1) | NNAPI               | < 500 ms         | snappy           |
| Pixel 7 (Tensor G2) | NNAPI               | < 500 ms         | snappy           |
| Pixel 9 (Tensor G4) | NNAPI               | < 500 ms         | snappy           |
| Pixel 4 (Snap 855)  | NNAPI → CPU         | < 2 000 ms       | usable           |

A14+ and Pixel 6+ must clear the snappy bar — that's the latency story
the pitch demo trades on. The two fallback devices (iPhone 11, Pixel 4)
only need to clear the "usable" bar; they're documented so caregivers
on older hardware aren't surprised. The product copy makes no latency
SLA promise — this matrix is the internal yardstick.

### Observed first-token (median of 5, ms)

> Filled in during the acceptance pass on the loaner-kit devices.
> Numbers are **not** CI-tracked — re-measure whenever ONNX Runtime
> moves a minor version, the CoreML / NNAPI EP options change, or the
> bundled voice swaps to a heavier model. Record the OS build and ORT
> version alongside each pass so a regression has somewhere to start.

| Device     | OS build       | ORT version | First-token (ms) | Verdict | Operator / date |
| ---------- | -------------- | ----------- | ---------------- | ------- | --------------- |
| iPhone 12  | _TBD_          | _TBD_       | _TBD_            | _TBD_   | _TBD_           |
| iPhone 14  | _TBD_          | _TBD_       | _TBD_            | _TBD_   | _TBD_           |
| iPhone 17  | _TBD_          | _TBD_       | _TBD_            | _TBD_   | _TBD_           |
| iPhone 11  | _TBD_          | _TBD_       | _TBD_            | _TBD_   | _TBD_           |
| Pixel 6    | _TBD_          | _TBD_       | _TBD_            | _TBD_   | _TBD_           |
| Pixel 7    | _TBD_          | _TBD_       | _TBD_            | _TBD_   | _TBD_           |
| Pixel 9    | _TBD_          | _TBD_       | _TBD_            | _TBD_   | _TBD_           |
| Pixel 4    | _TBD_          | _TBD_       | _TBD_            | _TBD_   | _TBD_           |

If any A14+ / Pixel 6+ row misses the < 500 ms bar, treat it as a
regression — not a doc update. Likely suspects, in order: CoreML EP
not actually selected (check the `executionProvider=` log line), an
ORT minor bump that changed the default partitioning, or a phonemizer
regression bloating the input token count.

### Audio quality A/B — Amy bundled vs. OS-compact Samantha

A side-by-side recording exercise to confirm the bundled voice is
worth the ~30 MB envelope cost.

Script (three lines, one decoder result's worth of "say" copy):

> "It's okay. You're safe right now. Let's sit down together for a
> moment."

Recording method: on an iPhone 14, record device audio with QuickTime
+ a Lightning-to-USB capture; speak the script first via Amy (bundled
provider), then immediately via `OSTTSProvider` with the system
Samantha voice. Same volume, same room. Save both clips under
`docs/audio_ab/` (not committed — pitch-day artifact only).

Rating rubric, 1 (poor) → 5 (excellent). The operator records below
after the A/B; do not pre-fill.

| Trait                            | Amy bundled | OS-compact Samantha |
| -------------------------------- | ----------- | ------------------- |
| Warmth / naturalness             | _TBD_       | _TBD_               |
| Prosody (cadence, sentence flow) | _TBD_       | _TBD_               |
| Intelligibility                  | _TBD_       | _TBD_               |
| De-escalating feel               | _TBD_       | _TBD_               |

Decision rule: if Amy beats Samantha on **warmth** or **de-escalating
feel** by ≥ 1.5 points, the bundled default stays. Intelligibility is
table-stakes — Samantha will tie or win there and that's fine. If Amy
loses on warmth, escalate before the pitch: the caregiver-coach voice
is the whole point of bundling.
