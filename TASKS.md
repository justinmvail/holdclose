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

- [ ] **Task 31: Router redirects for auth + onboarding.** Update
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
