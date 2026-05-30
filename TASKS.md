# Careblazers — Build Tasks

Argus autoloop reads this file top-to-bottom, one `- [ ]` item per
iter. Each task is a self-contained PR. Read
[BUILD_SPEC.md](BUILD_SPEC.md) for the contract — sections referenced
inline.

The build order follows BUILD_SPEC.md §15: scaffold first, then
provider interfaces (with fakes wired in), then the decoder wedge,
then the secondary surfaces, then auth/onboarding, then demo
automation. Each phase leaves the suite green.

---

## Phase 1 — Scaffold + theme

- [x] **Task 1: Flutter project init + folder structure.** Run `flutter
  create careblazers --org com.careblazers --platforms ios,android` and
  reconcile against the layout in BUILD_SPEC.md §2 — create the
  `lib/{providers,models,services,screens/{decoder,journal,library,crisis,onboarding,settings},widgets,db,seed,routing}/`,
  `test/{providers,services,screens,widgets}/`, `integration_test/`,
  and `tools/` directories with `.gitkeep` files where empty. Verify
  `pubspec.yaml` matches the deps listed in BUILD_SPEC.md §1 verbatim
  (DO NOT add extras). Run `flutter pub get`. Smoke-test the gate by
  ensuring `flutter analyze` is clean against the default-generated
  `lib/main.dart`. No new code — just the scaffold.

- [x] **Task 2: Brand theme (`lib/theme.dart`).** Implement the brand
  tokens from BUILD_SPEC.md §3 as a Material 3 `ThemeData` factory.
  Exported names: `careblazersLightTheme`, `careblazersDarkTheme`,
  `careblazersColors` (a `CareblazersColors` data class holding the
  10 brand color tokens verbatim). Use `google_fonts.getTextTheme()`
  with Lato body + Montserrat headings per the type ramp in §3.2.
  Dark palette: navy surface (`#0f1422`), warm-white text (`#e8e6e2`),
  orange CTA unchanged. Tests in `test/theme_test.dart`: every token
  in `CareblazersColors` is the exact hex from BUILD_SPEC.md;
  `careblazersLightTheme.colorScheme.primary` returns the navy;
  textTheme styles map to the expected sizes.

- [x] **Task 3: App scaffold + routing (`lib/app.dart`, `lib/main.dart`,
  `lib/routing/router.dart`).** Wire `MaterialApp.router` with
  `careblazersLightTheme` + dark theme + system-mode fallback. Build
  `go_router` config covering ALL routes from BUILD_SPEC.md §5 with
  placeholder screens (each screen widget returns a `Scaffold` with
  AppBar carrying the screen name + empty body). Tab routes use a
  `StatefulShellRoute` for `Home/Journal/Library/Crisis`; everything
  else pushes. Tests in `test/routing/router_test.dart`: every route
  in §5 has a registered path; tab-bar tap switches via `context.go`;
  Home → `/decoder/behavior` via `context.push` leaves a back arrow.

- [x] **Task 4: TabScaffold widget (`lib/widgets/tab_scaffold.dart`).**
  Wraps the StatefulShellRoute children with the bottom `NavigationBar`
  carrying the four tabs in exact order `Home · Journal · Library ·
  Crisis`, using Cupertino-style icons (home, book, library_books,
  warning_amber_outlined for Crisis — verify a calm-looking icon set).
  Active tab uses `primary` color; inactive uses `primarySoft`.
  **Also: set up `alchemist` golden infrastructure for the project.**
  Create `test/golden/flutter_test_config.dart` per the alchemist
  README so goldens run with consistent font + platform settings.
  Tests: widget tests assert bar renders 4 items in the right order
  and tapping each switches the shell branch; ALSO add a golden test
  `test/golden/tab_scaffold_golden_test.dart` capturing the bar's
  default state (one CI golden per the alchemist convention). Last
  scaffold-phase task — coverage threshold becomes 80% from Task 5 on.

## Phase 2 — Provider interfaces + fakes

- [x] **Task 5: Models (`lib/models/*.dart`).** Implement freezed
  models per BUILD_SPEC.md §7.3 + §9.1: `Behavior` (enum-style with id,
  label, glyph, list of canonical instances), `TriageAnswers`
  (when/whatChanged/whatTried with enum-like fields), `DecoderResult`
  (`say`, `tweak`, `dontSay`, `generatedAt`), `JournalEntry`
  (id, behavior, triage, result, outcome, attempt, createdAt, notes?,
  voiceNotePath?, photoPath?), `Patient` (per §9.1 shape), `Script`
  (the `say` line shape with optional audio attachment), `AppSettings`
  (audio toggle, voice id, speed, font multiplier, quiet hours, dark
  mode auto, reset on launch demo flag). Run `dart run build_runner
  build --delete-conflicting-outputs`. Tests in `test/models/`:
  every model round-trips through fromJson/toJson; the 8 canonical
  `Behavior` instances exist with the BUILD_SPEC.md §5.2 ids.

- [x] **Task 6: LLMProvider interface + FakeLLMProvider
  (`lib/providers/llm_provider.dart`, `lib/seed/fake_llm_seeds.dart`).**
  Abstract class per BUILD_SPEC.md §6.1 with `DecoderChunk` freezed
  union (`partial` / `done` / `error`). Implement `FakeLLMProvider`
  that yields canned responses per behavior id, streamed in 8-token
  chunks with 60ms delay between, ending with a `done`. Author the 8
  canonical fake responses (one per behavior) in
  `lib/seed/fake_llm_seeds.dart` based on BUILD_SPEC.md §10.2's
  examples — extend the pattern to all 8 behaviors using the system
  prompt's voice guidance. Wire as a riverpod provider returning the
  fake under `--dart-define=USE_FAKE_LLM=true` (default) and a stub
  `ClaudeCLIProvider` (Task 10 fills in the real impl) otherwise.
  Tests: `FakeLLMProvider.generateDecoderScript(...)` for each
  behavior emits at least 3 partial chunks then a done; the done
  carries a valid DecoderResult.

- [x] **Task 7: StorageProvider + drift database
  (`lib/providers/storage_provider.dart`, `lib/db/database.dart`,
  `lib/db/tables.dart`).** Abstract per BUILD_SPEC.md §6.2.
  `DriftStorageProvider`: Drift tables for `journal_entries`,
  `patients`, `app_settings`. Standard CRUD per the interface. `reset()`
  clears every table. `InMemoryStorageProvider`: keeps state in a Dart
  Map for widget tests. Riverpod provider chooses based on the
  `USE_FAKE_STORAGE` define (defaults to real Drift). Run
  `build_runner` for drift codegen. Tests: round-trip a journal entry
  through `DriftStorageProvider`; `reset()` empties everything;
  in-memory impl matches the interface.

- [x] **Task 8: TTSProvider + OSTTSProvider
  (`lib/providers/tts_provider.dart`).** Interface per §6.3.
  `OSTTSProvider` wraps `flutter_tts`: `availableVoices()` queries the
  OS voice list; `speak(text, voiceId, speed)` sets the voice + speed
  then awaits completion; `cancel()` stops mid-utterance. `NoopTTSProvider`
  returns an empty voice list and `speak()` resolves immediately.
  Riverpod provider chooses based on Settings → "Read scripts aloud"
  toggle + quiet-hours check. Tests: NoopTTS speaks nothing
  (assertion via a flag flipped in a subclass); the riverpod provider
  returns Noop when toggle is off OR quiet hours are active.

- [x] **Task 9: AuthProvider + AnalyticsProvider
  (`lib/providers/auth_provider.dart`,
  `lib/providers/analytics_provider.dart`).** AuthProvider per §6.4
  with `AuthState` freezed union. `RealAuthProvider` wraps
  `google_sign_in` and `sign_in_with_apple`; persists token to
  `flutter_secure_storage`. `FakeAuthProvider` returns the canned
  Sarah Henderson user on either sign-in method (per §6.4). Riverpod
  picks Fake under `--dart-define=DEMO_MODE=true` OR
  `--dart-define=USE_FAKE_AUTH=true`. AnalyticsProvider per §6.5 —
  ship only `NoopAnalyticsProvider` for v1, no real impl. Tests:
  Fake returns the canned user; auth state stream emits on sign-in;
  Noop analytics swallows calls without errors.

- [x] **Task 10: ClaudeCLIProvider via HTTP shim
  (`lib/providers/llm_provider.dart` — extend Task 6).** Implement
  `ClaudeCLIProvider` that POSTs `{system, user}` to
  `http://localhost:8765/generate` using `dio`, consumes the SSE
  stream, accumulates JSON across chunks, and yields `DecoderChunk`s.
  Parses the JSON when it's complete (use a streaming JSON parser
  that tolerates partial-but-valid object growth — see BUILD_SPEC.md
  §7.3 for the accumulation pattern). Riverpod provider routes to
  this impl when `USE_FAKE_LLM` is false. Add a `lib/seed/system_prompt.dart`
  containing the system prompt from BUILD_SPEC.md §7.1 as a const
  string (no paraphrasing — verbatim). Tests: with a fake dio that
  emits canned SSE chunks, the provider yields partials and a final
  done; parse errors yield a `DecoderChunk.error`; the user message
  is built per §7.2 verbatim.

## Phase 3 — Decoder flow (the wedge)

> **From here on**, every screen task includes a golden test at
> `test/golden/<screen>_golden_test.dart` capturing the default
> light-theme state. The coverage gate is at 80%. Tasks that ship
> screens without their goldens — or that drop coverage — will be
> rolled back by the autoloop.

- [x] **Task 11: Home screen
  (`lib/screens/home_screen.dart`).** Implement Home per BUILD_SPEC.md
  §5.1. AppBar with title + gear button (pushes `/settings`). The
  giant tap target uses the `displayLarge` text style with the
  two-line "What's happening / right now?" treatment; tap pushes
  `/decoder/behavior`. Below: "Quick reassurance" and "Doctor visit
  prep" rows. NO emojis on the primary action. Background:
  `surfaceWarm`. Tests in `test/screens/home_screen_test.dart`:
  gear taps push `/settings`; main button taps push
  `/decoder/behavior`; tapping the secondary rows pushes the expected
  routes; no BackButton visible (Home is a tab root).

- [x] **Task 12: Behavior picker screen
  (`lib/screens/decoder/behavior_picker_screen.dart`).** 4×2 grid of
  the 8 canonical behaviors per §5.2. Each card: glyph + 2-line
  label, `surfaceWarm` bg, rounded 16, soft shadow. Tap → push
  `/decoder/triage` carrying the Behavior. Below grid: "Something
  else — describe it" full-width pill → pushes the same triage
  screen but with the free-text path active. Tests: all 8 cards
  render with the labels and ids from §5.2; tapping each pushes the
  triage route with the correct behavior in extra; "Something else"
  pushes with the free-text flag set; BackButton visible (pushed
  screen).

- [x] **Task 13: Triage screen
  (`lib/screens/decoder/triage_screen.dart`).** Three-question
  sequential flow per §5.3. Stores answers in
  `triageProvider`. AppBar: back arrow + behavior label chip + "N of
  3" progress. Single-column pill buttons (single-select). "Next →"
  CTA in `cta` orange, disabled until selection. Back from Q2 / Q3
  returns to prior question preserving its answer. From Q3 → Next:
  navigates to `/decoder/result` (don't await the LLM call here —
  the result screen orchestrates that). Tests: sequential progression
  asserts; Back preserves prior answer; Next disabled when nothing
  selected.

- [x] **Task 14: Decoder result screen
  (`lib/screens/decoder/decoder_result_screen.dart`).** Per §5.4.
  Watches `decoderResultProvider(behavior, triage, attempt)` which
  invokes the LLMProvider and yields chunks. While loading: shows
  "Dr. Natali says:" header, a subtle pulsing skeleton, and the
  word-by-word fade-in of partial content. On done: full layout
  with PLAY button in AppBar (reads full script via TTSProvider),
  per-line ▶ on each say entry, divider sections, footer disclaimer,
  three outcome buttons. On "That helped" → mark journal entry
  outcome positive + `context.go('/')`. "Different approach" →
  re-invokes provider with `attempt + 1`. "Talk to Natali" → opens
  the careblazers.com URL via `url_launcher` (add as dep if not
  present — IT IS in BUILD_SPEC.md §1, double-check). Auto-logs to
  journal on first done. Tests: streaming displays partial JSON;
  done renders full result; "That helped" updates the journal entry;
  "Different approach" calls provider with attempt + 1; error state
  shows retry; VoiceOver section order matches §5.4.

- [x] **Task 15: Decoder service (`lib/services/decoder_service.dart`).**
  The orchestrator. `DecoderService` exposes `decode(behavior,
  triage, attempt)` returning `Stream<DecoderChunk>`. Internally:
  (1) builds the user message per §7.2; (2) calls
  `llmProvider.generateDecoderScript(...)`; (3) writes a
  `JournalEntry` to storage on the first emission with status
  pending, updates on done. Riverpod provider exposes the singleton.
  Tests: with a FakeLLMProvider and InMemoryStorageProvider, calling
  decode yields chunks AND writes a JournalEntry; on done the entry
  has the result attached; on error, the entry's outcome is set to
  `error`.

- [x] **Task 16: Caption fade-in widget
  (`lib/widgets/caption_fade.dart`).** A widget that takes a String
  + a stream of partial strings, and renders the text with a
  word-by-word fade-in at ~120ms/word as new words arrive. Respects
  iOS Reduce Motion (MediaQuery `accessibleNavigation` or
  `disableAnimations`) by rendering instantly. Reusable by both the
  decoder result screen and the library card detail screen. Tests:
  fades in over time when Reduce Motion is off; renders instantly
  when on; final state matches the input string.

## Phase 4 — Journal

- [x] **Task 17: Journal screen
  (`lib/screens/journal/journal_screen.dart`).** Per §5.5. Watches
  `journalEntriesProvider` (last 30 days). Layout: week summary card
  (count + behavior breakdown), pattern flag card (only when
  patternDetectorProvider returns non-empty), grouped chronological
  list (Today / Yesterday / Earlier). Each entry tile: glyph + time
  + behavior + "What worked" sub. Tap → `/journal/:id`. Empty state
  per §5.5 with CTA to `/decoder/behavior`. Tests: empty state shown
  with zero entries; entries grouped correctly by date; pattern
  alert displays when service returns one.

- [x] **Task 18: Pattern detector service
  (`lib/services/pattern_detector.dart`).** Implements the rules from
  §7.6 against the journal store. Returns `List<PatternAlert>` with
  `kind`, `text`, `severity`. Three rules in v1: 3+ falls in 7 days
  (matches text "fall" or "fell" in result.tweak or entry.notes); 5+
  sundowning entries in 7 days; 3+ distinct new behaviors in 14 days
  ("new" = behavior id appearing for the first time in the patient's
  history). Tests: fixture data triggers each rule; mixed-fixture
  returns multiple alerts; below-threshold returns empty.

- [x] **Task 19: Journal entry detail screen
  (`lib/screens/journal/journal_entry_screen.dart`).** Per §5.6.
  Reads/writes via `journalRepository`. Layout: behavior chip,
  outcome chip, the decoder scripts (read-only quote of what was
  shown), notes editor (free text), voice-note record/playback,
  photo attach/display. Save button persists changes. Delete from
  AppBar kebab → confirm dialog. Tests: editing notes persists;
  voice note record + playback wire (mock the audio plugin);
  delete flow with confirm.

- [x] **Task 20: PDF exporter (`lib/services/pdf_exporter.dart`).**
  Uses the `pdf` package to generate the doctor-visit packet. Inputs:
  `(List<JournalEntry> entries, Patient patient, DateRange range)`.
  Output: a PDF byte buffer. Layout: cover page with patient name +
  date range + caregiver name; behavior summary table (counts per
  behavior); chronological entries with date + behavior + what
  worked + notes. Footer: "Generated by Careblazers. Not a substitute
  for medical advice." Uses `printing.Printing.sharePdf(bytes:
  pdfBytes)` for the share sheet. Also implement `crisisCard(patient)`
  → a one-page PDF for the Crisis screen's print action. Tests:
  exporting fixture entries produces a PDF (assert non-empty bytes);
  the crisis card contains all the patient fields from §9.1.

## Phase 5 — Library + Crisis card

- [x] **Task 21: Library card seeds
  (`lib/seed/library_cards.dart`).** Twelve cards per BUILD_SPEC.md
  §9.4 — each with id, title, hook (1 sentence), body (placeholder
  paragraph of 50–80 words, marked `// TODO(natali): refine`).
  Phase 8 polish will hand-write the real 300–500 word bodies in
  Natali's voice; for v1 the autoloop ships structured placeholders
  so the screen renders end-to-end. Also a `relatedBehaviorIds` list
  per card so the detail screen can render chips. Tests: all 12
  cards have non-empty title/hook/body; ids are unique; every related
  behavior id is a real one from §5.2.

- [x] **Task 22: Library screen
  (`lib/screens/library/library_screen.dart`).** Per §5.7. AppBar:
  "Library". "Today's card" computed by `(date.dayOfYear % 12)` mod
  the seed list. Section "Most-asked behaviors" + "For YOU, the
  caregiver" — fixed groupings per §5.7. Tap any card → `/library/:id`.
  Tests: today's card is deterministic by date; all cards in the
  fixed sections are linked; tap routes to detail with id.

- [x] **Task 23: Library card detail
  (`lib/screens/library/library_card_screen.dart`).** Per §5.8. Reads
  card by id from seeds. AppBar: title + share action (uses
  `Share.share()` from `share_plus` — add to pubspec if missing; check
  BUILD_SPEC.md §1, may need to add). PLAY button reads body via
  TTSProvider. Body in `bodyLarge`. Related-behavior chips deep-link
  to `/decoder/behavior` with the behavior pre-selected — actually
  no, that route is the picker; chips push `/decoder/triage` with
  the behavior set, skipping the picker. Tests: play reads body via
  TTS; chip taps push triage with correct behavior; share action
  fires.

- [x] **Task 24: Crisis card screen
  (`lib/screens/crisis/crisis_card_screen.dart`).** Per §5.9.
  Scrollable single card. Reads/writes Patient through
  `storageProvider.getPatient()` / `upsertPatient()`. Editable fields
  inline (tap to edit → TextField appears, blur to save). Print button
  invokes `pdfExporter.crisisCard(patient)`. QR action generates a QR
  encoding `https://careblazers.app/patient/{patient.id}` (placeholder
  URL — will need a real public endpoint someday). Demo seed mode
  loads Mary Henderson on first launch when patient is null. Tests:
  Mary Henderson loads in demo mode; field editing persists; print
  button invokes exporter.

## Phase 6 — Settings + accessibility

- [x] **Task 25: Settings screen + SettingsProvider
  (`lib/screens/settings/settings_screen.dart`,
  `lib/providers/settings_provider.dart`).** Per §5.10. Riverpod
  `SettingsNotifier` wraps `AppSettings`, persists every change via
  storageProvider. Screen sections: Read aloud, Font size, Appearance,
  Demo mode (visibility-gated by `DEMO_MODE`), Account (visibility-
  gated by NOT `DEMO_MODE`), About. Each control mutates the notifier;
  changes propagate to the consuming providers (TTS provider checks
  the toggle + voice + speed; theme uses font multiplier). Tests:
  toggling audio off causes the TTS provider to return Noop; font
  multiplier flows into MediaQuery scaler; demo-mode toggle visible
  only with the define.

- [x] **Task 26: Demo mode reset-on-launch wiring.** When
  `DEMO_MODE=true` AND settings.resetOnLaunch is true, the app
  invokes `storageProvider.reset()` then `seedRepository.populateAll()`
  on app start (in `lib/main.dart` or `app.dart`). `seedRepository`
  loads Mary Henderson + the 6 sample journal entries from
  `lib/seed/`. Without DEMO_MODE, this code path is dead. Tests:
  with the define, reset happens on launch and seed populates; with
  the toggle off (or DEMO_MODE off), state survives.

- [x] **Task 27: Quiet hours + dark mode auto-switch
  (`lib/providers/quiet_hours_provider.dart`).** A riverpod provider
  that returns whether quiet hours are active based on
  `DateTime.now()` + settings. Updates on a Timer that fires every
  minute (so transitions happen without app interaction). Dark mode
  switch follows the same pattern — after 6pm, the
  `MaterialApp.themeMode` flips to dark unless the user overrode.
  Tests: at 11pm local, quiet hours active; at noon, inactive; dark
  mode after 6pm flips theme.

- [x] **Task 28: Font size scaler + VoiceOver labels.** Wire the
  `settings.fontMultiplier` to a `MediaQuery` `textScaler` override
  at the app root. Add `Semantics` ancestors with explicit labels to
  every interactive widget in: HomeScreen, BehaviorPickerScreen,
  TriageScreen, DecoderResultScreen, JournalScreen, LibraryScreen,
  CrisisCardScreen. Decoder result reads sections in order: header
  → say → tweak → don't-say → footer. Tests: text scaler applies via
  MediaQuery; widget tests use `tester.semantics()` to assert labels.

## Phase 7 — Auth + onboarding

- [x] **Task 29: Welcome carousel
  (`lib/screens/onboarding/welcome_carousel.dart`).** Per §5.11. Three
  PageView pages with the exact copy locked in §5.11. Skip top-right
  → routes to `/sign-in`. Bottom CTA: "Next →" on pages 1–2, "Get
  started" on page 3 → also routes to `/sign-in`. Dot indicator.
  Page 3 CTA also flips `onboardingCompletedProvider` true. Tests:
  three pages render with locked copy; Skip routes; Get started
  flips the provider AND routes.

- [x] **Task 30: Sign-in screen + auth wiring
  (`lib/screens/onboarding/sign_in_screen.dart`).** Per §5.12. Two
  buttons (Apple iOS-only, Google both platforms). Calls
  `authProvider.signInWithApple()` / `.signInWithGoogle()`. On
  success, routes to `/`. DEMO_MODE additional button "Skip — explore
  as Mary's caregiver" → calls FakeAuth's sign-in. Tests: tap Google
  triggers signInWithGoogle on the (mocked) provider; tap Apple
  triggers signInWithApple; the demo-skip button is invisible
  without the define.

- [x] **Task 31: Router redirects for auth + onboarding.** Update
  `lib/routing/router.dart` to redirect:
  - If `onboardingCompletedProvider` is false → `/onboarding`
    (welcome carousel)
  - If onboarding complete BUT auth state is signed-out → `/sign-in`
  - Otherwise allow normal navigation
  Both gates are stable (won't redirect-loop during the auth flow).
  Tests: an unauthenticated, un-onboarded app lands on
  `/onboarding`; after Skip, lands on `/sign-in`; after fake sign-in,
  lands on `/`.

## Phase 8 — Demo automation + shim

- [x] **Task 32: `tools/claude_shim.py`.** Implement the local HTTP
  shim per BUILD_SPEC.md §8 VERBATIM. Stdlib-only Python. Reproduce
  the §8 code without paraphrasing — that file is the contract. Make
  it executable (`chmod +x`). Smoke test: `python3 tools/claude_shim.py
  &` starts; `curl -X POST -d '{"system":"echo back","user":"test"}'
  http://localhost:8765/generate` returns SSE data (if `claude` is on
  PATH; if not, the error path emits "claude binary not found" which
  is fine for the smoke test). No Dart test for this — it's a host
  script.

- [x] **Task 33: Demo seed data loader
  (`lib/seed/mary_henderson.dart`, `lib/seed/sample_journal.dart`,
  `lib/services/seed_repository.dart`).** Implement Mary Henderson
  per BUILD_SPEC.md §9.1 exactly. Six sample journal entries per §9.2.
  `SeedRepository.populateAll()` upserts patient + inserts entries.
  Invoked from the demo-mode reset path (Task 26). Tests: Mary
  Henderson has the right meds + allergies + 3 calms + 3 escalates;
  populating an empty store results in 6 entries + 1 patient.

- [x] **Task 34: `integration_test/demo_tour.dart`.** Implement the
  scripted walkthrough per BUILD_SPEC.md §10.1. Eighteen steps, each
  with at least one `tester.tap()` + assertion. Use the
  `integration_test` package's binding. Pre-condition: app launched
  with `DEMO_MODE=true`, FakeLLMProvider, FakeAuthProvider,
  reset-on-launch ON, seed populated. Each step:
  `await tester.tap(find.X)` + `await tester.pumpAndSettle()` + an
  `expect(...)`. Tests run as part of the demo tour itself — the
  tour IS the test.

- [x] **Task 35: README dev section + final smoke.** Update README.md
  with the exact dev commands: how to run the shim, how to run the
  Flutter app against it, how to run the demo tour. Add a "Pitch day
  checklist" section: (1) `git pull` latest, (2) `flutter pub get`,
  (3) `flutter test` green, (4) `python3 tools/claude_shim.py` in one
  terminal, (5) `flutter run -d <ios-sim>` in another, (6) confirm
  the home screen renders, (7) Settings → Reset on launch is ON,
  (8) record a backup video with QuickTime. No code changes —
  documentation hardening. Tests N/A.

---

After Task 35 the app is functionally complete per BUILD_SPEC.md §14
acceptance criteria. The autoloop stops; the operator + Claude Code
take over for the manual polish pass (animations, the 12 library card
bodies, copy refinement). The polish pass is NOT in this task list —
it's deliberately hand-driven.

---

## Phase 9 — Bundled neural TTS (Piper via ONNX Runtime)

iOS/Android default TTS voices sound robotic; Apple gates the
high-quality voices behind a Settings download (~150 MB) and never
exposes the Siri voice to third-party apps. Solution: bundle a
small Piper voice model (`.onnx`, ~30 MB) into the app and run it
via ONNX Runtime on both platforms. Same model, same inference
layer; only the audio output path differs per platform.

Why Piper + ONNX (not CoreML + TFLite separately):
  - ONE voice model file works on both iOS and Android — no parallel
    conversion pipelines, no version drift.
  - iOS: ONNX Runtime's CoreML execution provider routes inference
    to the Neural Engine (A14+); first-token latency ~100–300 ms.
  - Android: ONNX Runtime's NNAPI execution provider hits the device's
    NPU/DSP — similar latency on modern Pixels / Snapdragon devices.
  - Simulators don't expose the Neural Engine; CPU fallback adds
    1–3 s of latency per sentence. Real devices fix this.

Voice pick: `en_US-amy-medium` (~30 MB, 22 kHz, warm female) as the
v1 default. Documented at https://github.com/rhasspy/piper/blob/master/VOICES.md.
Custom-trained voices (Dr. Natali, future personalities) are produced
by the **voicecloner** project (separate repo) and dropped into
`assets/tts/<voice-id>/` — careblazers consumes the `.onnx` artifact
without caring how it was produced.

Sized as 7 atomic iters; iOS slice ships first since the pitch demo
runs on iPhone.

- [x] **Phase 9.1: Add `onnxruntime` dependency + bundle the `amy`
  voice model.** Add `onnxruntime: ^1.18.0` (Flutter community
  plugin) to pubspec.yaml. Download `en_US-amy-medium.onnx` (~30 MB)
  + `en_US-amy-medium.onnx.json` from the Piper repo VOICES.md
  links; place under `assets/tts/en_US-amy-medium/`. Add to
  pubspec.yaml `flutter.assets`. Audit: `flutter build apk
  --analyze-size` reports the bundled model size; verify 30–35 MB
  envelope. Update BUILD_SPEC.md §1 to list onnxruntime + the voice
  model under bundled assets. No tests this iter (asset bundling
  is a build-step affair).

- [x] **Phase 9.2: Dart-side `BundledTTSProvider` skeleton +
  platform channel contract.** Implement `BundledTTSProvider` in
  `lib/providers/bundled_tts_provider.dart` conforming to
  `TTSProvider`. Bridge to a new `careblazers/tts` MethodChannel
  with three methods: `speak({text, voiceId, speed}) → void`,
  `cancel() → void`, `availableVoices() → List<TTSVoice>`. Add
  stubs in `ios/Runner/AppDelegate.swift` and Android's
  `MainActivity.kt` returning immediately — actual ONNX inference
  lands in 9.3/9.4. Tests in `test/providers/bundled_tts_provider_test.dart`
  use Flutter's MethodChannel mock to assert forwarding shape.

- [x] **Phase 9.3: iOS Swift bridge — ONNX Runtime + CoreML EP +
  AVAudioEngine.** Add `onnxruntime-objc` via SPM (or CocoaPods if
  Flutter's Pods setup forces it). In `ios/Runner/TTSBridge.swift`:
  load `en_US-amy-medium.onnx` from the bundle, init an ORTSession
  with the CoreML execution provider enabled (Neural Engine on
  A14+), implement `speak(text:speed:completion:)` — text →
  phonemes via the bundled `.onnx.json` espeak-ng config →
  inference → 16-bit PCM @ 22 050 Hz → AVAudioEngine playback.
  Wire the MethodChannel handler in AppDelegate. Smoke test:
  manual `flutter run` → home → decoder → result → hear Amy
  speaking. Document the smoke sequence in TTS_BUNDLED.md.

  espeak-ng phoneme conversion: ship the matching dataset under
  `assets/tts/en_US-amy-medium/` (covered by 9.1) and wrap espeak-ng
  via a small Swift helper around its C library.

  Test: XCTest unit asserts the bridge loads the model and inference
  produces non-silent audio (RMS > 0).

- [x] **Phase 9.4: Android Kotlin bridge — ONNX Runtime + NNAPI EP +
  AudioTrack.** Mirror of 9.3. Add
  `com.microsoft.onnxruntime:onnxruntime-android:1.18.0` to
  `android/app/build.gradle`. In
  `android/app/src/main/kotlin/com/careblazers/careblazers/TTSBridge.kt`:
  load model from AssetManager, build OrtSession with NNAPI EP (CPU
  fallback on older devices), phoneme conversion via `espeakng-java`
  (Maven Central) or a thin JNI wrapper, PCM → AudioTrack streaming
  write (22 050 Hz mono 16-bit). Wire MethodChannel from
  MainActivity. Smoke test parallel to 9.3 on an emulator/device.

  Test: instrumented Android test asserts model load + non-silent
  audio. Document in TTS_BUNDLED.md.

- [x] **Phase 9.5: Wire `BundledTTSProvider` into the TTS factory +
  Settings toggle + retire Siri/banner UX.** Update
  `lib/providers/tts_provider.dart`'s `tts(Ref ref)` factory: when
  `AppSettings.useBundledVoice` is true (new field, default true),
  return `BundledTTSProvider`; otherwise `OSTTSProvider`. Add the
  field via freezed regen; add `Settings.setUseBundledVoice(bool)`
  notifier. New SwitchListTile in the Audio section:
  *"High-quality bundled voice — uses ~30 MB of storage for a
  natural-sounding offline voice (recommended)."* Voice picker
  dropdown shows `Amy (bundled)` until the v1.1 catalog expansion.

  Remove obsolete UX:
  - `preferSiriVoice` field + `Settings.setPreferSiriVoice` +
    the "Use Siri voice" toggle. Apple won't expose Siri voices
    and the bundled path is strictly better.
  - `VoiceQualityBanner` widget + its imports in
    `lib/screens/home_screen.dart` and
    `lib/screens/settings/settings_screen.dart`. The download-
    nudge banner becomes irrelevant once bundled is the default.

  Tests: three table-driven cases in
  `test/providers/tts_provider_test.dart` pinning the factory
  choice per (useBundledVoice, OS-mute) combo.

- [x] **Phase 9.6: Real-device performance smoke + acceptance.**
  Per-platform smoke runs documented in TTS_BUNDLED.md:
    - iPhone 12 / 14 / 17: first-token latency target <500 ms on A14+
    - Pixel 6 / 7 / 9: same target on NNAPI path
    - Older devices (iPhone 11, Pixel 4): document fallback latency;
      acceptance is "usable" (~1–2 s first-token), not "snappy"

  Audio quality A/B: record a 3-line decoder script via Amy bundled
  vs. OS-compact Samantha. Subjective rating in the doc.

  No automated tests — ear validation only.

- [x] **Phase 9.7: Docs + ONNX-load failure fallback.** Write
  `docs/TTS_BUNDLED.md` covering: why bundled vs. OS TTS, voice
  catalog swap process (drop new `.onnx` + `.onnx.json` under
  `assets/tts/<voice-id>/`, list in pubspec.yaml, register in
  VoicePicker), simulator-vs-device latency gap, and the failure-
  mode fallback: if ONNX Runtime fails to load the model (rare —
  missing CoreML symbol, NNAPI version mismatch), the
  `BundledTTSProvider` transparently falls back to `OSTTSProvider`
  with a single WARN log. Implement the fallback in the Dart slice
  this iter. README "Audio" section: brief mention of bundled voice
  + Settings toggle. Tests: unit covering the fallback path
  (mock-fail the channel, assert factory returns OSTTSProvider).

---

## Phase 10 — espeak-ng text-to-phoneme integration (the production fix)

Phase 9.3's `EspeakNGPhonemizer` ships with a TODO calling out that it
**does NOT actually wire espeak-ng** — it falls through to a character-
by-character lookup against `phoneme_id_map`, which produces non-empty
output (so the audio pipeline + tests stay alive) but feeds the Piper
model the wrong IDs. The audible result is gibberish: the letter `c`
maps to whatever ID `c` happens to have in the Piper IPA table, not to
the sound `k`. Surfaced on the 2026-05-29 simulator demo as
"it speaks, but it's jibberish."

The pitch-week interim (HTTP phonemize endpoint on
`tools/claude_shim.py` consumed by `HttpPhonemizer` in
TTSBridge.swift) keeps the demo working without espeak-ng on-device,
but it requires the shim to be running — not a path that ships to
TestFlight users. Phase 10 lands the proper on-device integration
that lets the bundled voice work standalone.

Why this is the right long-term answer (vs. switching engines):
  - Piper + espeak-ng total bundle is ~35 MB (smallest in class)
  - Both MIT-licensed; no commercial-use restrictions
  - The voicecloner project (`~/IdeaProjects/voicecloner`) targets
    Piper — a custom-trained Dr. Natali voice ships as a Piper
    `.onnx` swap, no engine change needed
  - Production-validated: Home Assistant ships Piper to hundreds of
    thousands of users via their voice add-on

Sized as ~5 atomic iters; iOS slice ships first since the pitch demo
runs on iPhone.

- [x] **Phase 10.1: Vendor espeak-ng for iOS.** Two paths to evaluate
  in this iter — pick the one with a maintained pod:
    - **CocoaPod path**: `pod 'espeak-ng-ios'` (community, verify
      it tracks espeak-ng 1.52.x) added to ios/Podfile alongside
      `onnxruntime-objc`.
    - **Vendor path**: pull espeak-ng C sources at a pinned commit,
      compile with the iOS arm64 + arm64-simulator toolchain via a
      Pods-vendored static library. Reference Home Assistant's
      published iOS voice library for the build flags.

  Either way, after this iter:
    - `espeak_Initialize`, `espeak_TextToPhonemes`, `espeak_Terminate`
      are linkable from Swift via a bridging header
    - `assets/tts/espeak-ng-data/` directory is bundled with the iOS
      target (~5 MB of language rules / dictionaries espeak-ng
      consults at runtime)

  Tests: a tiny XCTest that initializes espeak-ng, calls
  `espeak_TextToPhonemes("hello world")`, asserts the output is
  non-empty IPA. No audio comparison — just "the library loads and
  produces something."

- [x] **Phase 10.2: Replace `EspeakNGPhonemizer`'s fallback with the
  real call.** In `ios/Runner/TTSBridge.swift`, replace the character-
  by-character loop (lines 386–403 as of commit 7500ff7) with:
    1. Initialize espeak-ng once per `TTSEngine` instance, pointed at
       the bundled `espeak-ng-data/` directory.
    2. Per `phonemeIds(for:config:)` call: invoke
       `espeak_TextToPhonemes` with the input English text, capture
       the IPA-phoneme output string.
    3. Tokenize the IPA string and map each phoneme to the int64 IDs
       from `config.phonemeIdMap`. Wrap with BOS (`^`), pad (`_`),
       EOS (`$`) tokens as Piper's tokenizer expects.

  Drop the `HttpPhonemizer` interim path from the pitch-week shim
  work — Phase 10's on-device implementation supersedes it. Keep
  the `tools/claude_shim.py` phonemize endpoint as a test helper
  (golden phoneme outputs in unit tests).

  Tests: XCTest fixture comparing
  `EspeakNGPhonemizer.phonemeIds(for: "hello world", config: amyCfg)`
  against the same call made via Piper's Python `piper-phonemize`
  reference impl. Tolerance: exact match — the model is sensitive to
  phoneme ID drift.

- [x] **Phase 10.3: Mirror on Android — `espeak-ng-android` JNI +
  Kotlin bridge.** Same shape as 10.1 + 10.2 on Android.
  `android/app/build.gradle` pulls a maintained `espeak-ng-android`
  AAR (verify community publication) OR vendors the C library
  cross-compiled for arm64/x86_64. Kotlin bridge in `TTSBridge.kt`
  routes the existing phoneme-conversion call to the JNI layer
  instead of the placeholder.

  Tests: instrumented Android test mirroring the iOS XCTest from 10.2.

- [x] **Phase 10.4: Audio-quality acceptance + sample regen.** Record
  3 known scripts (the decoder's "I see you're worried…" + the crisis
  card welcome line + Settings reset confirmation) through the
  bundled voice with the real phonemizer. Side-by-side WAV files in
  `docs/tts_samples/<voice>/` for manual ear validation. Acceptance:
  the recorded WAVs sound like natural English; the operator approves
  them subjectively. Document in TTS_BUNDLED.md.

- [x] **Phase 10.5: Decommission the shim phonemizer + docs.** Delete
  `HttpPhonemizer` from TTSBridge.swift and the Kotlin equivalent;
  remove the `/phonemize` HTTP call from `BundledTTSProvider`. Keep
  the `tools/claude_shim.py` endpoint as a test helper but stop
  calling it from app code. Update `docs/TTS_BUNDLED.md`:
    - Mark Phase 9.3's TODO as resolved
    - Document the espeak-ng integration (data path, init/teardown
      contract, phoneme set used)
    - Add a "swapping voices" section explaining how to drop a
      voicecloner-trained `.onnx` into `assets/tts/<voice-id>/`
      (the espeak-ng setup is voice-agnostic; same data dir works
      for any en-* Piper voice)

---

## Phase 11 — Dementia-care chatbot (ChatGPT-style, persisted)

Multi-turn conversational coach for the moments the decoder's single-
shot pattern doesn't cover. The decoder handles "what do I do RIGHT
NOW?" — the chatbot handles "tell me more about sundowning," "she
asked for her mother again yesterday, what's happening," and the
exploratory back-and-forth a caregiver needs at 11pm with no one to
talk to.

Builds on existing infrastructure:
  - `ClaudeCLIProvider` (Phase 2) already streams responses via the
    `tools/claude_shim.py` HTTP bridge
  - Drift storage (Phase 2) is the natural persistence layer
  - Library cards (Phases 22-23) are the canonical Dr. Natali content
    — the chatbot CITES them rather than reinventing

The bot is grounded: every substantive response cites a library card
when one applies ("Dr. Natali on sundowning: tap to read more →"),
which keeps the LLM's voice aligned with the brand's vetted content
and gives the caregiver a path deeper into the app.

Sized as 6 atomic iters.

- [x] **Phase 11.1: Chat models (`lib/models/chat.dart`).** Freezed
  classes for `Conversation` (id, title, createdAt, updatedAt) and
  `Message` (id, conversationId, role: user/assistant, body, citations:
  list of library card IDs, createdAt, streamingDone bool). Run
  `build_runner build --delete-conflicting-outputs`. Tests in
  `test/models/chat_test.dart`: round-trip through fromJson/toJson;
  Message with citations preserves the list; role enum values match
  spec.

- [x] **Phase 11.2: Drift schema + ChatRepository
  (`lib/db/tables.dart` + `lib/services/chat_repository.dart`).** Two
  new tables: `chat_conversations` and `chat_messages` (FK on
  conversation_id with ON DELETE CASCADE). Migration bumps the drift
  schema version. `ChatRepository` exposes `createConversation()`,
  `appendMessage()`, `listConversations()`, `loadMessages(conversationId)`,
  `deleteConversation()`. Tests round-trip a 5-message conversation;
  cascade-delete leaves zero orphan messages.

- [x] **Phase 11.3: ChatService — LLM streaming with dementia-care
  system prompt (`lib/services/chat_service.dart`).** Wraps the
  existing `LLMProvider` (defaults to `ClaudeCLIProvider`). System
  prompt locked verbatim in `lib/seed/chat_system_prompt.dart` —
  reproduces Dr. Natali's voice from the decoder system prompt but
  reframed for multi-turn dialogue: warm, de-escalating, evidence-
  based, refers to professional help for crisis content (BUILD_SPEC.md
  §6 scope guardrails). Per-message flow: append user message to
  repository → stream assistant response via LLMProvider → on each
  delta, update the in-flight Message's body → on final chunk, parse
  citation hints (`[card:<id>]` syntax in the model's response) into
  the Message's `citations` field → mark `streamingDone: true`.

  Tests: feed a canned LLM stream (mock provider yielding partial →
  done), assert the Message is built incrementally; citation parsing
  handles 0, 1, and multiple `[card:<id>]` markers.

- [x] **Phase 11.4: Chat screen UI (`lib/screens/chat/chat_screen.dart`
  + `lib/screens/chat/conversation_list_screen.dart`).** Two screens:
    - `ConversationListScreen` at `/chat`: list of past conversations
      (title = first user message's first 60 chars, or a +Quick Chat
      button to start new). Tap → push the ChatScreen.
    - `ChatScreen` at `/chat/:id`: message list (assistant messages
      use the warm-coach styling from the decoder; user messages
      right-aligned in a subtle navy bubble), input field at bottom,
      send button (salmon CTA). Streaming responses fade in word-by-
      word using the existing `CaptionFade` widget from Phase 16 —
      consistent visual language with the decoder.

  Add a "Chat" tab to the bottom tab bar — but only when the new
  `chatEnabled` AppSettings flag is true (defaults to true; can be
  hidden in demo mode if it interferes with the tour). Update the
  4-tab `TabScaffoldBar` to a 5-tab variant; preserve the existing
  golden tests by updating them for the new tab.

  Tests + golden: ConversationListScreen with 0/1/many conversations;
  ChatScreen with streaming-in-flight + final state.

- [x] **Phase 11.5: Library card citations + deeplink.** When the
  assistant cites a card via `[card:<id>]`, render an inline chip in
  the message body: "Dr. Natali on <card title>" with the brand
  salmon background, white text, 14pt. Tap → push
  `/library/<card-id>` (the existing library detail route from
  Phase 23). Update `lib/seed/chat_system_prompt.dart` to enumerate
  the 12 library card IDs the model can cite, with brief titles —
  the model picks from that closed set so we never get hallucinated
  IDs.

  Tests: a Message with citations renders one chip per cited card;
  tapping a chip calls `context.push('/library/<id>')` (use a mock
  router).

- [x] **Phase 11.6: Acceptance + demo tour update.** Add a chat
  walkthrough to `integration_test/demo_tour.dart`: open chat tab,
  type "what's sundowning?", verify a response streams in with at
  least one library card citation, tap the citation, verify
  navigation lands on the library screen. Document the chat flow in
  `docs/CHAT_FEATURE.md` covering the system prompt customization,
  citation syntax, and the chat-disabled-via-settings escape hatch.
  Update README §Features to mention the chatbot.

---

## Phase 12 — Medication + appointment tracker

The two highest-frequency caregiver utility needs: what meds, when,
did they take them; what doctor visits are coming up, who's the
provider, what to ask. Both fit cleanly into the existing local-first
drift architecture — no backend, no auth, just local persistence +
local notifications.

The "Bring to your next visit" PDF export (Phase 20's existing
exporter) should ideally pick up medications + recent dose history +
upcoming appointments — a follow-up iter extends the PDF schema.

Sized as 8 atomic iters across two related sub-areas: medications
(12.1–12.4) and appointments (12.5–12.7), plus 12.8 wiring.

### Medications

- [x] **Phase 12.1: Medication models + drift schema
  (`lib/models/medication.dart` + `lib/db/tables.dart`).** Three
  freezed models + tables:
    - `Medication`: id, name, dosage (free text e.g. "10 mg"),
      route (oral/topical/injection/other enum), prescriber, notes
    - `DoseSchedule`: id, medicationId (FK), frequencyKind
      (daily / twiceDaily / weekly / asNeeded), timesOfDay
      (list of TimeOfDay), daysOfWeek (Set<int> for weekly), startsOn,
      endsOn (nullable)
    - `DoseLog`: id, medicationId (FK), scheduledFor (DateTime),
      takenAt (nullable DateTime), status (taken/missed/skipped/late),
      notes

  Migration bumps drift schema version. CASCADE on medication delete
  removes its schedule + logs. Tests: round-trip each model; cascade-
  delete invariants; FrequencyKind serialization.

- [x] **Phase 12.2: MedicationRepository
  (`lib/services/medication_repository.dart`).** CRUD over the three
  tables + computed helpers: `upcomingDoses(within: Duration)`,
  `dosesByDay(date)`, `adherenceRate(forMedication, window)`. The
  upcoming-doses helper expands a Medication's DoseSchedule into
  concrete scheduled times for the next 7 days, intersecting with
  existing DoseLog entries (so already-logged doses don't show as
  upcoming). Tests cover the schedule-expansion logic for each
  FrequencyKind variant.

- [x] **Phase 12.3: Medication list screen + add-med form
  (`lib/screens/medication/medication_list_screen.dart` +
  `lib/screens/medication/medication_form_screen.dart`).** List
  screen at `/medications`: each medication card shows name, dosage,
  next dose time, adherence chip (last 7 days). Floating action
  button (salmon CTA) → add-med form. Form fields: name, dosage,
  route dropdown, prescriber (optional), notes. Submit creates the
  Medication + a default DoseSchedule (daily, 8am) the operator
  edits next. Tests: list with 0 / 1 / 10 medications; form
  validation (name required); add-med flow round-trips through the
  repository.

- [x] **Phase 12.4: Dose logging UI
  (`lib/screens/medication/dose_log_screen.dart`).** "Today's doses"
  screen at `/medications/today`: chronological list of every dose
  scheduled today, with a checkbox + "Mark taken" CTA per row. Tap
  a logged dose to change status (taken → late, skipped → taken,
  etc.). Late entries show a small badge. Bulk-action: "Mark all
  before noon taken" for the common batch case. Tests: dose log
  state transitions; rendering with mixed taken/missed/upcoming.

### Appointments

- [x] **Phase 12.5: Appointment models + drift schema.** Two new
  models:
    - `Provider`: id, name, role (doctor/neurologist/social worker/
      other enum), phone, address, notes
    - `Appointment`: id, providerId (FK), startsAt, durationMinutes,
      location (free text — may differ from provider address e.g.
      home visits), agenda (list of bullet strings), notes
      (post-appointment), status (upcoming/completed/canceled)

  Migration + CASCADE behavior + tests mirror 12.1.

- [x] **Phase 12.6: Appointment list + detail screens
  (`lib/screens/appointment/appointment_list_screen.dart` +
  `lib/screens/appointment/appointment_detail_screen.dart`).** List
  at `/appointments`: grouped by "Upcoming" + "Past." Each card:
  date+time, provider name, location, agenda item count. Detail
  screen: full agenda (editable as checkboxes — caregivers cross
  items off in the waiting room), post-visit notes field, call
  provider button (tel: URL), get directions button (maps: URL).
  Tests cover both screens with each appointment status.

- [x] **Phase 12.7: Add/edit appointment form +
  ProviderRepository.** Form covers all Appointment fields +
  inline "add new provider" (so the caregiver doesn't have to set
  up providers separately). ProviderRepository CRUD. Tests for
  form round-trip + the inline provider creation.

### Wiring

- [x] **Phase 12.8: Notifications, Settings, tab bar, tour, PDF
  pickup.**
    - Wire `flutter_local_notifications` (new pubspec dep) to
      schedule per-dose + per-appointment reminders. Dose reminders
      fire at the scheduled time; appointment reminders fire 24h
      before + 1h before. Permission ask flow on first med/appointment
      add. Notification tap deep-links to the relevant screen.
    - Add "Medications" + "Appointments" tabs to the bottom tab bar
      (now 7 tabs total OR consolidate "Decoder/Journal" into one
      "Coach" tab — pick whichever scrolls less awkwardly on small
      iPhone widths).
    - Settings additions: per-feature enable toggles + a master
      "Use trackers" switch for caregivers who want to keep the app
      lean.
    - Demo tour additions: add a med + log a dose + add an
      appointment + verify list rendering.
    - Phase 20 PDF exporter extension: include "Active medications"
      and "Upcoming appointments" sections in the exported doctor-
      visit PDF.

---

## Phase 13 — Caregiver forum (Cloudflare Workers + D1 + R2)

Single-board Reddit-style forum for caregivers — own backend, no
embed/wrapper. Threaded comments (Reddit-style nesting, capped at 6
levels). Native UI inside careblazers. Cloudflare hosting chosen for
cost-of-scale and zero-egress: estimated ~$5-15/month at 5-20K MAU,
the cheapest managed option available. Replaces the previous
Care-Collective-WebView Phase 13 — we own the data, the moderation,
and the UX.

Stack:
  - **Cloudflare Workers** (compute, TypeScript)
  - **Cloudflare D1** (SQLite-at-edge, the database — hands-off for
    years; sharding path documented for future)
  - **Cloudflare R2** (object storage for avatars + post images;
    zero egress fees)
  - **Hono** (web framework — adapter-portable to AWS Lambda /
    Vercel Edge / Bun / Deno later if we ever leave Cloudflare)
  - **Drizzle ORM** (schema-portable between D1 / Postgres / MySQL;
    same code runs against future Neon migration with one
    connection-string change)
  - **`backend/`** directory in the repo holds the Worker code;
    Flutter side talks to it via Dio + JWTs minted off the existing
    careblazers Apple/Google sign-in. No separate auth system.

Safety + moderation baked in from v1 (not optional for App Store
review with UGC):
  - **Report** affordance on every post + comment → admin queue
  - **Crisis-keyword auto-flag**: posts mentioning self-harm,
    suicidality, or specific abuse terms surface a banner linking
    to the existing Crisis card (BUILD_SPEC.md §5.9 — already
    shipped Phase 11.5+)
  - **Solo-admin v1** — operator is the only mod role; community
    guidelines acceptance on first post.

Sized as 13 atomic iters: backend (8) → Flutter integration (4) →
ops/watchdog (1). Backend ships first since the Flutter side needs
the API contract.

### Backend (Cloudflare Workers + D1 + R2)

- [x] **Phase 13.1: Cloudflare project scaffold + wrangler config
  (`backend/`).** Create `backend/` with `package.json`, `tsconfig.json`,
  `wrangler.toml`, `vitest.config.ts`. Initialize:
    - Workers project with TypeScript
    - `wrangler.toml` declaring one D1 database binding
      (`FORUM_DB`), one R2 bucket binding (`FORUM_MEDIA`)
    - Vitest with `@cloudflare/vitest-pool-workers` for Worker-side
      tests using miniflare's D1/R2 emulators
    - Hono installed; minimal `src/index.ts` that returns
      `{"status":"ok"}` on `GET /health`
    - A README in `backend/` covering local dev (`wrangler dev`),
      test run (`npm test`), and deploy (`wrangler deploy`)

  No real endpoints yet — just the bones. Tests: a smoke test
  asserting `GET /health` returns 200. This iter establishes the
  whole Worker testing pipeline so subsequent iters slot in cleanly.

- [x] **Phase 13.2: Drizzle schema + migrations
  (`backend/src/db/schema.ts` + `backend/drizzle/`).** Five tables
  per the spec:
    - `profiles` (id UUID, display_name TEXT, avatar_url TEXT,
      joined_at, role TEXT default 'user', careblazers_user_id TEXT
      UNIQUE — the foreign key to the existing auth identity)
    - `posts` (id UUID, author_id FK → profiles, title TEXT, body
      TEXT, created_at, updated_at, vote_count INTEGER default 0,
      hidden BOOLEAN default false)
    - `comments` (id UUID, post_id FK → posts, author_id FK →
      profiles, parent_comment_id FK → comments NULL, body TEXT,
      created_at, vote_count INTEGER, depth INTEGER, hidden BOOL)
    - `votes` (id UUID, voter_id FK → profiles, target_kind TEXT
      'post' or 'comment', target_id UUID, value INTEGER ±1,
      created_at, UNIQUE (voter_id, target_kind, target_id))
    - `reports` (id UUID, target_kind TEXT, target_id UUID,
      reporter_id FK → profiles, reason TEXT, status TEXT
      'pending'/'reviewed'/'actioned', created_at, resolved_at NULL)

  Generate the first migration via `drizzle-kit generate`. The
  `depth` column is a denormalization — populated on insert from
  `parent.depth + 1`, capped at 6 (return 400 on attempt to nest
  deeper). Tests: schema round-trip in miniflare D1; insert at
  depth 6 → reject at depth 7.

- [x] **Phase 13.3: Hono API skeleton + JWT auth middleware
  (`backend/src/middleware/auth.ts`).** Hono routes mounted under
  `/api/v1`. Auth middleware verifies a JWT signed with a shared
  secret (stored in Cloudflare Worker secrets via `wrangler secret
  put FORUM_JWT_SECRET`). Token claims: `{sub: careblazers_user_id,
  iat, exp}`. Flutter side mints the JWT after sign-in using the
  same secret — Phase 13.9 wires that.

  Middleware behavior:
    - No token → 401
    - Invalid signature → 401
    - Expired → 401 with `Token-Expired: true` response header
    - Valid → set `c.get('userId')` for downstream handlers

  Public routes (no auth): `/health`, `/api/v1/posts` (GET list
  is read-anonymous). Everything else requires auth.

  Tests: middleware accepts/rejects per case; unauthenticated
  reads of `/posts` work; unauthenticated writes return 401.

- [x] **Phase 13.4: Profile bootstrap + endpoints
  (`backend/src/routes/profiles.ts`).** Four endpoints:
    - `POST /api/v1/profiles/bootstrap` — called once per careblazers
      user after first sign-in. Creates a profile row keyed on
      careblazers_user_id. Default display_name is
      `Caregiver_<6-char hash>` so users start anonymous.
    - `GET /api/v1/profiles/me` — return current user's profile.
    - `PATCH /api/v1/profiles/me` — update display_name (3-30 chars,
      letters/digits/underscores, profanity-screened against a
      basic wordlist) and/or avatar_url. avatar_url must be an R2
      URL (validated via prefix match on the project's R2 origin).
    - `GET /api/v1/profiles/:id` — public profile (display_name,
      avatar_url, joined_at, post/comment counts).

  Tests cover each endpoint's happy path + the auth/validation
  rejections.

- [x] **Phase 13.5: Posts endpoints + feed sorting
  (`backend/src/routes/posts.ts`).** Five endpoints:
    - `GET /api/v1/posts?sort=hot|new|top&before=<post-id>&limit=25`
      — paginated feed. `hot` uses Reddit's classic ranking
      formula (vote_count + time-decay), `new` is created_at DESC,
      `top` is vote_count DESC. Cap limit at 50.
    - `GET /api/v1/posts/:id` — single post with metadata.
    - `POST /api/v1/posts` — create post (title 1-200 chars, body
      1-10000 chars). Auto-flag check from 13.8 runs here.
    - `PATCH /api/v1/posts/:id` — author-only edit (body only,
      not title; updated_at bumped).
    - `DELETE /api/v1/posts/:id` — author or admin soft-delete
      (sets hidden=true).

  Tests for each endpoint + sort-order assertions + pagination
  correctness.

- [x] **Phase 13.6: Comments endpoints + nested rendering
  (`backend/src/routes/comments.ts`).** Three endpoints:
    - `GET /api/v1/posts/:post_id/comments?sort=top|new` — returns
      a flat list with `depth` field populated; client builds the
      tree by following `parent_comment_id`. Includes hidden
      comments as `{hidden: true, body: null}` so the tree
      structure remains intact (Reddit pattern).
    - `POST /api/v1/posts/:post_id/comments` — body 1-5000 chars +
      optional `parent_comment_id`. Server computes `depth` from
      the parent (or 0 if root) and rejects depth > 6 with a
      clear error message.
    - `DELETE /api/v1/comments/:id` — author or admin soft-delete.

  Tests cover nested tree integrity, depth enforcement, hidden
  comment rendering.

- [x] **Phase 13.7: Voting endpoints + atomic counter updates
  (`backend/src/routes/votes.ts`).** One endpoint:
    - `POST /api/v1/votes` `{target_kind, target_id, value: +1|-1|0}`
      — value=0 removes an existing vote. Upserts the votes row,
      updates the target's vote_count atomically via a D1
      transaction. Returns the new vote_count.

  D1 doesn't have row-level locking like Postgres, but its
  transaction model + the UNIQUE constraint on
  (voter_id, target_kind, target_id) gives us atomicity: a
  conflict resolves to UPDATE OR DELETE without race window.

  Tests: vote ±1, switch ±1 (single net change), zero (vote
  withdrawal), vote count stays accurate under interleaved
  concurrent test calls.

- [x] **Phase 13.8: Reports + crisis-keyword auto-flag
  (`backend/src/routes/reports.ts` +
  `backend/src/middleware/crisisFlag.ts`).** Two surfaces:
    - **Reports**: `POST /api/v1/reports` `{target_kind, target_id,
      reason}`, `GET /api/v1/reports?status=pending` (admin only),
      `PATCH /api/v1/reports/:id` (admin only — mark reviewed
      with action: 'no_action' / 'hide_target' / 'ban_user').
    - **Crisis-keyword middleware** runs on every `POST /posts` and
      `POST /comments` BEFORE persistence. Keyword list lives in
      `backend/src/data/crisis-keywords.ts` — a vetted set covering
      suicidality ("kill myself", "end it all"), self-harm
      ("cutting", "overdose"), and severe abuse ("hitting them",
      "they hit me"). Matched content gets persisted normally BUT
      the response includes
      `{crisis_resources: {crisis_card_url: '/crisis', hotlines:
      [...]}}` which the Flutter client renders as a banner above
      the post/comment confirmation. A `crisis_flagged` boolean is
      stored on the row for later analysis.

  Tests: report CRUD; admin gate; crisis match returns banner data;
  non-match passes through normally.

### Flutter integration

- [ ] **Phase 13.9: Forum API client + auth wiring
  (`lib/services/forum_api_client.dart` +
  `lib/providers/forum_jwt_provider.dart`).** Dio-based client
  pointed at the Cloudflare Worker URL (configurable via
  `--dart-define=FORUM_API_URL=https://forum-api.workers.dev`).
  JWT generation happens client-side using the shared secret
  (stored in flutter_secure_storage so it doesn't ship in the
  bundle text; loaded from a build-time define). Token refreshes
  before expiry.

  Freezed DTOs match the Worker's response shapes 1:1
  (Profile, Post, Comment, Vote, Report). Tests use mocktail to
  pin the request shapes + assert auth header presence on
  protected endpoints.

- [ ] **Phase 13.10: Community tab + feed screen
  (`lib/screens/community/community_feed_screen.dart` + tab bar
  update).** New tab in the bottom bar — "Community" with
  `Icons.forum_outlined`. Feed screen shows a sort selector
  (Hot / New / Top), infinite-scroll list of post cards (title,
  author display name + avatar, time, body preview to 3 lines,
  vote count, comment count). Pull-to-refresh. Empty state: "Be
  the first to post."

  Reuses the existing CaptionFade for new-post animations.
  Tests + golden for empty + populated states.

- [ ] **Phase 13.11: Post detail + comment thread UI
  (`lib/screens/community/post_detail_screen.dart` +
  `lib/widgets/community/comment_thread.dart`).** Detail screen
  shows the post body + scrollable nested-comments tree. Comments
  use a recursive widget that renders 24px left-indent per depth
  level (matches Reddit visual). Each comment has vote arrows
  (salmon up / navy down), reply button, report button (long-press
  menu). Replying inlines the input below the parent — no modal.

  Tests + goldens for: 0 comments, single root-level comment,
  3-level deep thread, 6-level deep (max depth — reply button
  hidden), hidden comments render as placeholder.

- [ ] **Phase 13.12: Create post + community guidelines + admin
  moderation
  (`lib/screens/community/post_compose_screen.dart` +
  `lib/screens/community/community_guidelines_screen.dart` +
  `lib/screens/community/admin_reports_screen.dart`).** Three
  screens:
    - **Post compose**: title + body fields, character counters,
      "Read community guidelines" link (gated: first post must
      acknowledge guidelines, stored via SharedPreferences).
    - **Community guidelines**: locked content in
      `lib/seed/community_guidelines.dart` covering tone, scope
      (caregiving topics), no medical advice, crisis resources
      pointer. Operator can update via spec change.
    - **Admin reports** (gated to operator role): list of pending
      reports with quick-actions (no action / hide / ban). Hidden
      tab when current user isn't admin.

  Tests for the gating logic + tour additions covering: create a
  post, view feed, vote, report a comment, admin reviews report.

### Ops

- [ ] **Phase 13.13: Weekly metrics watchdog Worker
  (`backend/src/watchdog/index.ts` + scheduled cron trigger).**
  Cloudflare scheduled Worker (`crons = ["0 13 * * 1"]` — Mondays
  at 1pm UTC) that:
    1. Queries D1 for current size, total rows, posts/comments
       last 30d, monthly active authors
    2. Reads Workers Analytics for request count + p95 latency
    3. Reads R2 for storage size + GET/PUT volume
    4. Compares against thresholds (yellow flags at 50%+ of
       limits, red flags at 75%+):
       - D1 size > 4 GB (yellow) / 7 GB (red)
       - D1 writes/day > 50K / 500K
       - DB p95 query > 50ms / 200ms
       - Monthly active authors > 50K / 500K
       - R2 storage > 100 GB / 500 GB
    5. If any yellow/red flag: sends a Resend email
       (`RESEND_API_KEY` Worker secret) to the operator. If all
       green: silent.

  Tests use mocked D1/R2/Analytics clients + assert the email
  sends with the right severity. Document the threshold schema
  in `backend/README.md` so future tuning is obvious.
