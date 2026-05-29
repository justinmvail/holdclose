# Phase 10.4 — audio-quality samples (`en_US-amy-medium`)

Side-by-side WAVs of the three Phase 10.4 acceptance scripts rendered
through the bundled Piper Amy voice (the real espeak-ng phonemizer,
not the 9.3 character-lookup fallback). The operator regenerates these
on demand with `tools/regen_tts_samples.sh` and ear-validates them
against the rubric in `docs/TTS_BUNDLED.md` Phase 10.4.

## What lands here

```
docs/tts_samples/en_US-amy-medium/
  README.md                            # this file (committed)
  ios/decoder_worried.wav              # operator artifact (gitignored)
  ios/crisis_card_welcome.wav
  ios/settings_reset_confirmation.wav
  android/decoder_worried.wav
  android/crisis_card_welcome.wav
  android/settings_reset_confirmation.wav
```

The WAVs themselves are **not** committed (see `.gitignore`). They're
regenerated against a real iOS simulator + a connected Android device
whenever the bundled voice, the phonemizer vendor commit, or the
Piper inference scales change.

## The three scripts (source of truth)

Keep this list in sync with
`ios/RunnerTests/RunnerTests.swift#testRegenerateAudioQualitySamples`
and
`android/app/src/androidTest/.../TTSBridgeInstrumentedTest.kt#regenerateAudioQualitySamples`.
The slug is the WAV filename; the text is the exact UTF-8 the bridge
hands to `espeak_TextToPhonemes`.

| Slug                          | Text                                                              | Source in app                                                                          |
| ----------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `decoder_worried`             | `I can see this is really hard. I'm right here with you.`         | `lib/seed/fake_llm_seeds.dart` — `upset` decoder result, first say-line                |
| `crisis_card_welcome`         | `Hospital handoff card.`                                          | `lib/screens/crisis/crisis_card_screen.dart` — AppBar title (line 180)                 |
| `settings_reset_confirmation` | `Seed reloaded.`                                                  | `lib/screens/settings/settings_screen.dart` — Reload-seed SnackBar content (line 453)  |

The mix is intentional: one multi-sentence de-escalating coaching
line (the cadence the TTS engine actually has to nail for the
pitch demo), one short noun-phrase title (plosive + vowel clarity),
one short status confirmation (two-word utterance, vowel-heavy).
Together they exercise the engine's range without spending pitch
attention on a 30-line script set.

## How to regenerate

```sh
tools/regen_tts_samples.sh                       # iOS + Android
tools/regen_tts_samples.sh ios                   # iOS only
IOS_SIM="iPhone 16" tools/regen_tts_samples.sh   # override sim name
```

Pre-reqs (per `docs/TTS_BUNDLED.md` Phase 10.1 + 10.3):

```sh
tools/vendor_espeak_ng.sh
cd ios && pod install && cd ..
# Android: a connected device with adb on PATH (emulators work too,
# but the CPU-fallback latency makes the recording slower).
```

The script runs `xcodebuild test -only-testing:.../testRegenerateAudioQualitySamples`
and `./gradlew :app:connectedDebugAndroidTest -P...class=...#regenerateAudioQualitySamples`,
greps the test logs for `PHASE_10_4_REGEN <slug> <path>` lines, and
copies the WAVs into this directory.

## Manual ear validation

Open each WAV pair in QuickTime / VLC / a browser and rate against
the rubric in `docs/TTS_BUNDLED.md` Phase 10.4. The acceptance bar is
subjective: **the recorded WAVs sound like natural English** and
**the operator approves them** — there's no automated phonetic
distance metric for v1. Record the verdict in the TTS_BUNDLED.md
rubric table and check the Phase 10.4 box in TASKS.md.
