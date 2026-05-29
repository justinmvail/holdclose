# Bundled neural TTS

> Cross-platform reference for the bundled Piper voice. Phase 9.3
> shipped the iOS bridge, Phase 9.4 mirrored it on Android, Phase 9.6
> pinned the device latency matrix, and Phase 9.7 (this section, plus
> the appended **Why bundled vs OS TTS**, **Voice catalog swap**,
> **Simulator vs device**, and **ONNX-load failure fallback** sections
> below) closed out the docs + the Dart-side fallback factory.

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

## Why bundled vs OS TTS

The OS TTS path (`OSTTSProvider`, wrapping `flutter_tts`) is the
zero-cost default — every iPhone ships Samantha; every supported
Android device ships at least the Google compact voices. So why pay a
~30 MB envelope cost for the Piper Amy ONNX model?

- **Warmth.** The dossier analysis flagged caregiver de-escalation as
  the audio contract: the synthesised line has to sound like a person
  who is *with* the caregiver, not a transit-system announcement.
  OS-compact voices are tuned for short imperative phrases ("Turn
  left in 200 feet"). Piper Amy is trained on multi-sentence
  narrative — the prosody arc lines up with Dr. Natali's scripted
  copy. The Phase 9.6 A/B (see above) is where we re-check that the
  warmth delta still justifies the bundle.
- **Determinism.** OS voices change underneath us. iOS 18.1 swapped
  the Samantha quality tier on several locales; Android OEMs ship
  forked TTS engines that disagree on rate semantics. The bundled
  path runs the same ONNX graph on every device, so a decoder
  recording captured today reproduces a year from now.
- **Offline.** The caregiver can be in a memory-care facility's
  Wi-Fi dead zone. The bundled voice runs entirely on-device with
  no network round-trip — same audio whether the caregiver is in a
  basement, a 35,000-foot flight, or at home.
- **No cloud routing.** The product copy explicitly avoids "AI"
  framing (CLAUDE.md). Calling a cloud TTS API would mean an outbound
  HTTPS request the caregiver's network can audit. Bundling sidesteps
  the conversation entirely.

The Settings → **Audio** screen exposes a `useBundledVoice` toggle
(`AppSettings.useBundledVoice`, default `true`). Flipping it off
routes through `OSTTSProvider` — useful for caregivers on storage-
constrained devices, or for the rare locale we don't have a bundled
voice for yet.

## Voice catalog swap process

Adding a new Piper voice — Spanish-language Carmen, a UK-English
Daniel, etc. — is a four-step swap:

1. **Drop the model files** under `assets/tts/<voice-id>/`. Two
   files per voice: `<voice-id>.onnx` (the graph) and
   `<voice-id>.onnx.json` (Piper's voice config — phoneme map, sample
   rate, speaker id). Voice ids follow the Piper convention
   `<lang>_<COUNTRY>-<name>-<quality>` — e.g.,
   `es_MX-carmen-medium`, `en_GB-daniel-low`. Quality tiers (`low`,
   `medium`, `high`) trade envelope size for prosody — start with
   `medium` unless an A/B says otherwise.
2. **List the asset directory** in `pubspec.yaml` under
   `flutter.assets:`. Match the trailing-slash form already used for
   `assets/tts/en_US-amy-medium/`. Both files in the directory are
   shipped by the trailing-slash include — no need to enumerate
   the `.onnx` and `.onnx.json` separately.
3. **Register in `VoicePicker`** (Settings → Voice picker — Phase
   9.5) so the caregiver-facing dropdown surfaces the new voice.
   The picker reads from a static catalog list (see
   `lib/widgets/voice_picker.dart` — the entry shape is
   `{id, displayName, locale, gender}`) so the dropdown can render
   without the native bridge having to enumerate.
4. **Bridge sanity-check.** The iOS `TTSBridge.swift` and Android
   `TTSBridge.kt` parse the `.onnx.json` for sample rate and
   phoneme-id map; if the new voice's config follows Piper's
   standard schema the bridge picks it up without a code change.
   Non-standard configs (custom speaker-id ranges, extra metadata
   fields) require a bridge-side parser update — those are caught
   at smoke time when the new voice fails to render audio.

Envelope budget: the v1 pitch ships a single 30 MB voice (Amy). The
catalog can grow to ~3 voices (~90 MB) before the App Store / Play
Store "thin app" download warning is worth the design conversation.
Past ~3, switch to on-demand voice downloads — out of scope for v1
but flagged here so the next maintainer doesn't blow through 200 MB
of assets without a heads-up.

## Simulator vs device latency gap

The Phase 9.6 acceptance matrix lists devices, not simulators, for a
reason. The CoreML execution provider on the iOS Simulator falls
through to CPU: the simulator host's Mac CPU runs the ONNX graph,
but the Apple Neural Engine isn't exposed to the simulator at all,
so first-token latency comes in at 1–3 s instead of the on-device
<500 ms target. Same story on Android emulators with NNAPI — the
emulator's translated NNAPI calls eventually CPU-execute, and an
emulator running on an x86 host with v8a translation pays an extra
penalty on top.

What this means in practice:

- **Sim smoke test = "the pipeline is alive"**, not "the latency is
  acceptable." A 2 s first-token in the simulator is **not** a
  regression. The bar is "audio plays, words are intelligible."
- **Device smoke test = "the pitch demo lands."** Always re-run on
  the loaner-kit iPhone / Pixel before the pitch. The matrix table
  above is where the per-device numbers get pinned.
- **CI runs sim-only.** That's fine for "did the bridge wire up?"
  but the < 500 ms SLA isn't CI-tracked — pinning that on a sim
  would just bake in the simulator's CPU penalty as the bar.

If you see > 5 s first-token on a real A14+ device, that's a real
regression; check the CoreML EP `executionProvider=` log line and
verify the EP actually engaged (CoreML EP can silently fall back to
CPU on a partitioning mismatch — ORT minor bumps have caused this
before).

## ONNX-load failure fallback

ONNX Runtime can fail to load the bundled model — rare in
production, but real:

- **iOS — missing CoreML symbol.** A long-discontinued iPhone runs
  an OS that ORT's CoreML EP was compiled against a newer Foundation
  symbol for. The session-init throws on the `addCoreML` call.
- **Android — NNAPI version mismatch.** An exotic AOSP fork (OEM
  customisations, certain Chinese-domestic distributions) ships an
  NNAPI HAL that ORT can't bind to. `addNnapi()` succeeds, but the
  first inference call throws.
- **Bridge unavailable.** The native plugin failed to register —
  e.g., a Phase 9.2 stub build is running, or the pod / AAR didn't
  link. The `careblazers/tts` MethodChannel surfaces a
  `MissingPluginException` on the first invocation.

The Dart slice handles all three the same way:
`BundledTTSProvider.createOrFallback()` (in
`lib/providers/bundled_tts_provider.dart`) probes the channel by
invoking `probe`. The native bridge returns null when the
`ORTSession` / `OrtSession` is healthy; it throws otherwise.

- **Probe succeeds** → factory returns a `BundledTTSProvider` wired
  to the same channel. Caller is none the wiser.
- **Probe throws `PlatformException`** → factory logs a single
  WARN line via `dart:developer` (`name: 'careblazers.tts'`,
  `level: 900`) carrying the platform code + message, then returns
  an `OSTTSProvider`. The decoder result screen, library card
  screen, and any other `TTSProvider` consumer keep working — they
  just route through `flutter_tts` instead of the bundled voice.
- **Probe throws `MissingPluginException`** → same fallback path,
  same WARN line, framed as "bridge unavailable" instead of "probe
  failed."

The WARN is logged exactly once, at factory time. We do NOT
keep retrying the bundled path on subsequent `speak()` calls —
ONNX-load failure is a device-class problem, not a transient one,
and re-probing every utterance would burn battery for no payoff.
The cost is that a caregiver who flips airplane mode → reboots →
turns it back off will see the fallback persist for the rest of
the session; we accept that, since the OS path still works.

Tests live in
`test/providers/bundled_tts_provider_test.dart` under the
`createOrFallback` group — they mock the channel to raise
`PlatformException('ONNX_LOAD_FAILED', …)` and assert the factory
hands back the injected `OSTTSProvider`, plus a single WARN-line
capture. The success path asserts the probe verb is exactly `probe`
and that no WARN line fires when the channel returns null.

## Phase 10.1 — espeak-ng vendor for iOS (path picked)

Phase 9.3's `EspeakNGPhonemizer` stub maps characters one-for-one
against `phoneme_id_map`, which produces *non-empty* IDs the model
will accept but the wrong phonetic interpretation — audibly gibberish
on the 2026-05-29 simulator demo. The `HttpPhonemizer` pitch-week
workaround delegates to `tools/claude_shim.py`'s `/phonemize`
endpoint, which is fine for the demo but doesn't ship to TestFlight.
Phase 10's arc replaces both with on-device espeak-ng. This section
records the **path-picking iter** (10.1); 10.2 wires the actual
`espeak_TextToPhonemes` call.

### The two evaluated paths

**CocoaPod path** — `pod 'espeak-ng-ios'`. Inspecting the public
CocoaPods registry surfaces one community pod by that name; its
latest published spec tracks espeak-ng **1.46.x** (last update 2021).
The 1.52-line phoneme tables that the bundled Piper Amy voice was
trained against are not in that drop, and there's no arm64-simulator
slice. Maintainer activity has been quiet for ≥ 18 months. **Rejected.**

**Vendor path** — pull espeak-ng C sources at a pinned commit and
build them as a Pods-vendored static library. The Home Assistant
iOS voice library (the reference cited in TASKS.md) uses this exact
shape: a local `.podspec` with `source_files` + `compiler_flags`
+ `resource_bundles` for the `espeak-ng-data` directory. **Picked.**

### Pinned version

- Tag: **1.52.0**
- Commit: `4870adfa25b1a32b4361592f1be8a40337c58d6c`
- Upstream: https://github.com/espeak-ng/espeak-ng

The Piper Amy voice config's IPA token set aligns with espeak-ng 1.52
(verified against `en_US-amy-medium.onnx.json`'s `phoneme_id_map`),
so pinning to 1.52.0 lines up directly with the bundled model's
training assumption. Bumping past 1.52 requires re-validating the
phoneme set — a Phase-10.4 acceptance concern.

### What lands in 10.1

- `ios/Vendored/espeak-ng/espeak-ng.podspec` — local pod declaration
  with vendored source globs, public umbrella headers, compiler
  flags (`USE_ASYNC=0`, `HAVE_PCAUDIOLIB_AUDIO_H=0`, version macro),
  and `resource_bundles` wiring `Resources/espeak-ng-data/` into
  `espeak-ng.bundle` inside the Runner app.
- `ios/Podfile` — adds `pod 'espeak-ng', :path => 'Vendored/espeak-ng'`
  alongside `onnxruntime-objc`.
- `ios/Runner/Runner-Bridging-Header.h` — adds a `__has_include`-
  guarded import of `<espeak-ng/espeak_ng.h>` + `<espeak-ng/speak_lib.h>`.
  The guard sets `CAREBLAZERS_HAS_ESPEAK_NG` to 1 when the headers
  resolve and 0 otherwise — fresh checkouts that haven't run the
  vendor script keep building, with the existing character-lookup
  fallback handling the phonemizer path.
- `tools/vendor_espeak_ng.sh` — operator-runnable shell script that
  shallow-clones espeak-ng at the pinned tag, verifies the commit
  hash, copies `src/libespeak-ng/` + `src/include/` into the Pod
  layout, and writes the runtime data into both
  `ios/Vendored/espeak-ng/Resources/espeak-ng-data/` (iOS Pod
  resource bundle) and `assets/tts/espeak-ng-data/` (Flutter-asset
  mirror that Android Phase 10.3 will consume).
- `pubspec.yaml` — adds `assets/tts/espeak-ng-data/` to
  `flutter.assets`.
- `ios/RunnerTests/RunnerTests.swift` — adds
  `testEspeakNgVendorLoadsAndPhonemizes`: initializes espeak-ng,
  calls `espeak_TextToPhonemes("hello world")`, asserts the IPA
  output is non-empty. Skips when `CAREBLAZERS_HAS_ESPEAK_NG == 0`
  (pre-vendor) or when `espeak-ng-data` isn't reachable from the
  test bundle.
- `.gitignore` — excludes `ios/Vendored/espeak-ng/src/`,
  `ios/Vendored/espeak-ng/Resources/`, and the
  `assets/tts/espeak-ng-data/` payload (the README placeholder is
  kept so the asset directory exists in fresh checkouts).
- `BUILD_SPEC.md §1` bundled-assets table — extended with the new
  `assets/tts/espeak-ng-data/` row.

### Setup contract

On a fresh checkout, the operator runs once:

```sh
tools/vendor_espeak_ng.sh
cd ios && pod install
```

After that, `flutter run -d <ios-device>` builds with the vendored
static library linked, the bridging-header `__has_include` flips
on, and Phase 10.2's `espeak_TextToPhonemes` call is live.

CI doesn't run the vendor script — the `flutter test` autoloop gate
only exercises Dart code, and the iOS smoke runs are operator-driven.
The XCTest covering the espeak load skips cleanly in CI; the
character-lookup fallback keeps the build green either way.

### Why a local pod, not a git submodule

A git submodule was the obvious alternative — it would commit the
upstream reference into the repo. Two reasons against it:

1. **`pod install` doesn't natively understand submodules.** It would
   either need a `prepare_command` to populate the tree, or the
   operator has to remember to `git submodule update --init` before
   `pod install`. Same number of steps as the explicit script, with
   more state to leak between operators.
2. **The vendor script can verify the commit hash** (`git rev-parse
   HEAD` against the pinned SHA), so a retagged or force-pushed
   upstream surfaces as a script-side ERROR rather than a silent
   build of unexpected sources. Submodules carry the SHA but the
   verification only fires at `git submodule update` time — easy to
   miss.

The local `.podspec` + operator script is the same pattern Home
Assistant's iOS voice library uses, and it composes cleanly with the
Phase 10.3 Android mirror (where the espeak-ng-data Flutter-asset
copy is the canonical read path — no CocoaPods analog over there).
