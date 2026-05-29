# Bundled neural TTS — iOS (Phase 9.3)

> Phase 9.3 ships the iOS side of the bundled Piper voice. Phase 9.4
> covers Android. Phase 9.7 will append the cross-platform overview,
> failure-fallback narrative, and voice-catalog swap guide — keep this
> doc lean for now.

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
