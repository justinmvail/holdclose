# Careblazers — Build Spec

> **SUPERSEDED — see [`CLAUDE.md`](CLAUDE.md) + [`ROADMAP_TO_PRODUCTION.md`](ROADMAP_TO_PRODUCTION.md).** Historical; kept for reference only. When it disagrees with the code, the code wins.

> ## ⚠️ SUPERSEDED IN PART — read this first (pivot DONE 2026-06-23)
>
> This spec describes the **original** product: "Careblazers," a
> dementia-behavior decoder built as a partnership pitch to Dr. Natali
> Edmonds. That pitch went unanswered, and the product **pivoted** — the
> pivot is now **implemented in code** (commit `0a27b13`). For the current
> direction, **[`CLAUDE.md`](CLAUDE.md) → Direction is authoritative**;
> this document is kept for the still-accurate detail (the caregiving
> suite, data models, backend, security, navigation), but the following
> parts are **no longer true and are LIVE in the code**:
>
> - **Renamed Careblazers → Holdclose** (brand at holdclose.care, under
>   Juno Code Studio). The code rename is **done** — Dart identifiers,
>   `pubspec name:`, bundle id `com.holdclose.holdclose`, and the
>   `holdclose://` scheme are all Holdclose. Wherever this spec says
>   "Careblazers," read "Holdclose." (The repo *directory* is still named
>   `careblazers`, and a few internal ids — `careblazers_user_id`, the
>   Android Kotlin/JNI package — are deliberately unchanged; see CLAUDE.md.)
> - **The Behavior Decoder is REMOVED.** Every "Decoder" / triage /
>   "Dr. Natali says:" / behavior-script section below is obsolete and the
>   code is deleted. The wedge is the **data-grounded chat coach** (see
>   [`docs/CHAT_FEATURE.md`](docs/CHAT_FEATURE.md)); the journal is now a
>   free-text model.
> - **All Dr. Natali / Dementia Careblazers framing is removed** — the
>   product is its own brand; no attribution or branded-framework voice.
> - **General-purpose caregiving**, not dementia-specific — copy + system
>   prompts are re-voiced for any care situation; the demo persona is
>   post-stroke + hypertension, not Alzheimer's.
> - **Business model:** paid subscription + a rev-share affiliate program
>   (per-creator referral codes → commission on paying subscribers);
>   requires a paywall + attribution backend, a later phase.
>
> Trust the suite/architecture sections here; ignore the decoder,
> Natali, dementia-only, and "pitch demo" framing.

*Self-contained implementation spec for the original build. Companion:
[`CLAUDE.md`](CLAUDE.md) for current direction + code-style conventions,
[`TASKS.md`](TASKS.md) for the historical autoloop queue.*

---

## 0. What to build

> **Superseded** — see the banner above. Original text retained for
> reference:

A Flutter iOS + Android mobile app that gives caregivers an
in-the-moment "What do I do RIGHT NOW?" coach for dementia behaviors,
grounded in Dr. Natali Edmonds' (Dementia Careblazers) coaching
framework. The wedge is the **Behavior Decoder**: caregiver taps a
behavior, answers three triage questions, gets a Dr. Natali–style
script with 2–3 things to say + an environmental tweak + a "don't say"
warning. Every other feature in the app (Journal, Library, Crisis
card) is a byproduct of repeated decoder use.

The v1 target is the **full functional app, demo-pitchable**: every
screen real, every flow live, real LLM calls in dev mode, real
persistence, real auth. The pitch demo runs as an automated
`integration_test/` walkthrough over the same code base. No
pre-staged content beyond the seed-data scaffolding.

---

## 1. Stack & constraints

- **Language**: Dart 3.5+, Flutter 3.24+.
- **Platforms**: iOS 16.0+, Android API 26+ (Android 8.0).
- **State management**: `flutter_riverpod` 3.x (`>=3.0.0 <3.2.0`) with
  `riverpod_annotation` 4.x / `riverpod_generator` 4.x (the 3.x/4.x
  pairing resolves the analyzer-7 incompatibility the pre-3 chain had —
  see pubspec.yaml). No alternatives.
- **Routing**: `go_router` 14+. Per CLAUDE.md navigation invariants.
- **Local persistence**: `drift` 2.20+ (SQLite) opened via
  `drift_flutter` 0.2+, with `path_provider`/`path` for the database
  location. `flutter_secure_storage` for auth/session tokens only;
  `shared_preferences` for non-secret flags (onboarding, sync cursor,
  seed tokens).
- **Models**: `freezed` 3.x + `json_serializable` 6.8+.
- **HTTP**: `dio` 5.7+ for the LLM shim calls and the forum API client
  (Phase 13.9).
- **Crypto**: no direct dependency (2026-06-11). The Phase 13.9
  client-minted-JWT scheme is RETIRED — the Worker mints session
  tokens in `POST /auth/google` after Google ID-token verification,
  and the app stores the opaque token (`ForumSessionManager` in
  `lib/providers/forum_jwt_provider.dart`). No signing key ships in
  the binary. (`crypto` remains transitively present via drift/http.)
- **TTS**: `flutter_tts` 4.2+ (wraps iOS AVSpeechSynthesizer +
  Android TextToSpeech) — fallback path.
- **Bundled neural TTS**: ONNX Runtime bundled NATIVELY per platform —
  NOT the Dart community plugin (it pins onnxruntime-objc 1.15.1,
  conflicting with the bridge's ~> 1.18 requirement). iOS pulls
  `onnxruntime-objc ~> 1.18.0` via ios/Podfile; Android pulls
  `com.microsoft.onnxruntime:onnxruntime-android` via Gradle. The
  Dart-side `BundledTTSProvider` is a MethodChannel proxy only.
  Drives the on-device Piper voice (TASKS.md Phase 9). Primary TTS
  path post-Phase 9.
- **Typography**: `google_fonts` 6.2+ for Lato + Montserrat.
- **Auth**: `google_sign_in` 6.2+ and `sign_in_with_apple` 6.1+.
- **PDF**: `pdf` 3.11+ + `printing` 5.13+ (doctor-visit packet).
- **URL launching**: `url_launcher` 6.3+ (decoder result → "Talk to
  Natali" outbound link; future share-action surfaces).
- **Share sheet**: `share_plus` 10+ (library card detail → AppBar share
  action per §5.8; future "share this script" surfaces). Wrapped
  behind the `Sharer` interface so widget tests can recording-override
  it the same way `LinkLauncher` is.
- **Local notifications**: `flutter_local_notifications` 18+ +
  `timezone` 0.10+ (Phase 12.8 — per-dose + per-appointment
  reminders). Wrapped behind the `NotificationsProvider` interface so
  the medication + appointment screens depend on a single seam rather
  than the plugin API; widget + service tests override with a
  recording `NoopNotificationsProvider`.
- **Device capture** (#8 — real photo / voice-note / speech intake):
  - `image_picker` 1.1+ — OS camera + gallery picker behind the
    `PhotoAttacher` seam (`RealPhotoAttacher`).
  - `record` 6+ (pinned `<7.0.0`; 7.x requires Dart ^3.12 and we ship
    3.11.5) + `audioplayers` 6.5+ — mic → m4a capture + playback behind
    the `VoiceNoteRecorder` seam (`RealVoiceNoteRecorder`). `record` is
    capture-only, so `audioplayers` is the companion that honors the
    seam's pre-existing `play(path)` method.
  - `speech_to_text` 7+ — on-device dictation behind the `VoiceCapture`
    seam (`RealVoiceCapture`), feeding the Home Add-sheet voice button.

  All four are wired ONLY through those three existing interfaces and
  selected by the `USE_REAL_CAPTURE` build flag, which **defaults to
  false** (mirrors `USE_FAKE_LLM`): `flutter test` and the demo tour
  keep the `NoopPhotoAttacher` / `NoopVoiceNoteRecorder` /
  `UnavailableVoiceCapture` fakes and never touch a real mic / camera.
  Platform permission strings live in `ios/Runner/Info.plist`
  (`NSCamera/Microphone/PhotoLibrary/SpeechRecognitionUsageDescription`)
  and `android/.../AndroidManifest.xml` (`RECORD_AUDIO`, `CAMERA`,
  `READ_MEDIA_IMAGES`, capped `READ_EXTERNAL_STORAGE`, + the speech
  recognizer `<queries>` entry). Flipping the flag on requires a fresh
  `pod install` before the next iOS run.
- **Localization / i18n** (#18): `flutter_localizations` (SDK) +
  `intl` (resolved `0.20.2`, pinned by the SDK's `flutter_localizations`
  constraint — declared as `intl: any`, let `flutter pub get` resolve
  it). Both are pure-Dart, so adding them needs **no** `pod install`.
  Strings live in ARB files under `lib/l10n/` (`app_en.arb` is the
  template / source of truth). Flutter's built-in **gen-l10n** generates
  `AppLocalizations` from them — enabled by `flutter: generate: true`
  in `pubspec.yaml`, configured by `l10n.yaml` (`arb-dir: lib/l10n`,
  `template-arb-file: app_en.arb`, `output-localization-file:
  app_localizations.dart`, `nullable-getter: false`). On this Flutter
  (3.41) the generator emits the sources next to the ARB
  (`lib/l10n/app_localizations*.dart`, tracked — the synthetic-package
  output mode was removed upstream); `flutter pub get` / `flutter
  gen-l10n` regenerate them. `lib/app.dart` registers
  `AppLocalizations.localizationsDelegates` + `supportedLocales` on the
  `MaterialApp.router`. `en` is the only shipped locale in v1; adding
  more is translation work (drop `app_<locale>.arb` next to the
  template + re-run gen-l10n), not an app-code change. Status: the
  framework + a one-screen reference conversion
  (`lib/screens/community/community_guidelines_screen.dart`) are in;
  extracting the rest of the app's hardcoded English is documented
  follow-up under #18.
- **Care-circle connect** (2026-06-06 — username + QR connect, §13
  endpoints below):
  - `qr_flutter` 4.1+ — renders a circle invite token as a scannable QR
    on the "Show my QR" screen (`lib/screens/team/circle_qr_screen.dart`)
    via `QrImageView`. Pure-Dart (CustomPainter) — no `pod install`.
  - `mobile_scanner` 6.0+ — reads another caregiver's QR on the "Scan to
    add" screen (`lib/screens/team/circle_scan_screen.dart`). Uses the
    camera, so it sits behind a `enableCamera` flag (defaults true,
    overridden false in widget tests) — the same seam shape as the
    feedback overlay's capture override — and the parse + join path is
    driven through `debugHandlePayload(...)` in tests so no live camera
    is instantiated. The camera permission string already lives in
    `ios/Runner/Info.plist`. QR payloads are namespaced
    `careblazers:circle:<token>` so the scanner validates the code is
    one of ours before redeeming it.
  - `app_links` 6.3+ (2026-06-08 — invite LINKS) — receives the
    custom-scheme deep link an invited caregiver taps from a shared text
    link: `careblazers://join/<token>` (plus the QR-style
    `careblazers:circle:<token>` for symmetry). Handles BOTH cold-start
    (`getInitialLink`) and warm (`uriLinkStream`) inbound URIs, wired
    fail-safe in `lib/app.dart`. The parse + join logic is shared with the
    scanner via `lib/services/circle_invite_link.dart` +
    `lib/services/circle_deep_link_handler.dart` (signed-out tokens are
    stashed + replayed after sign-in). iOS already registers the
    `careblazers` scheme in `ios/Runner/Info.plist`; Android registers it
    via a VIEW/DEFAULT/BROWSABLE intent-filter on MainActivity
    (`android/app/src/main/AndroidManifest.xml`). The "Invite by link"
    action on `care_circle_screen.dart` mints an invite and shares
    `<FORUM_ORIGIN>/join/<token>` (the `FORUM_API_URL` origin WITHOUT the
    `/api/v1` suffix) via `share_plus`; the backend serves a public
    landing page at the Worker root `GET /join/:token` (exempt from the
    forum JWT, like `/auth/google`) that bounces into the app via the
    deep link. True https App/Universal Links (direct-open, no landing
    bounce) need the Apple Developer Program + `assetlinks.json` — a
    future upgrade.
  These reuse the existing `ForumApiClient` (Dio + `ForumTokenLoader`
  JWT auth) — no new client / auth. New endpoints under
  `<FORUM_API_URL>/api/v1`: `GET /profiles/username-available?u=`,
  `PATCH /profiles/me {username}` (409 `username_taken` /
  400 `invalid_username` / `profanity_blocked`),
  `GET /profiles/by-username/:username` (404 `profile_not_found`),
  `POST /circles {name}`, `GET /circles`,
  `POST /circles/:id/invites` (returns `{token, circle_id, expires_at}`),
  `POST /circles/join {token}` (404 `invite_not_found` /
  410 `invite_expired`). New DTOs `CircleDto` / `CircleMemberDto` /
  `CircleInviteDto` live in `lib/models/forum.dart`; `ForumProfile` +
  `ForumPublicProfile` gained an optional `username`. The
  `FakeForumApiClient` mirrors every method in-memory (username registry
  + circles map) so tests + demo mode work offline. Screens hang off
  the People roster at `/team/circle/{username,qr,scan}` (root-navigator
  pushes, `PathHeader` breadcrumbs).
- **No new top-level deps** without updating this file. Don't add
  Bloc, Provider (lowercase, the package), MobX, or any other state
  library. Don't add hand-rolled HTTP. Don't add new font families.

### Bundled assets

Static binaries shipped inside the app bundle (declared under
`flutter.assets` in `pubspec.yaml`):

| Asset path | Size | Purpose |
|---|---|---|
| `assets/images/` | small | App logo + onboarding illustrations |
| `assets/seed/` | small | Demo-mode seed JSON (sample voice-note placeholder) |
| `assets/tts/en_US-amy-medium/en_US-amy-medium.onnx` | ~60 MB | Piper neural-TTS voice model (22 kHz, medium quality, en-US female "Amy"). Source: `rhasspy/piper-voices` Hugging Face mirror, tagged release `v1.0.0`. Consumed by `BundledTTSProvider` via `onnxruntime` (TASKS.md Phase 9). |
| `assets/tts/en_US-amy-medium/en_US-amy-medium.onnx.json` | ~5 KB | Companion config: espeak-ng phoneme map + inference params (`noise_scale`, `length_scale`, `noise_w`). Read by the iOS/Android bridges at session init. |
| `assets/tts/espeak-ng-data/` | ~5 MB | espeak-ng 1.52.0 runtime data (language rules, phoneme tables, voicedata). Pinned to upstream commit `4870adfa25b1a32b4361592f1be8a40337c58d6c`. Populated by `tools/vendor_espeak_ng.sh` (operator-runnable, not committed); see TASKS.md Phase 10.1 and `docs/TTS_BUNDLED.md`. iOS reads from the CocoaPods-bundled mirror at `ios/Vendored/espeak-ng/Resources/espeak-ng-data/`; Android reads from this Flutter-asset path directly (Phase 10.3). |

The medium-quality model is ~60 MB rather than the ~30 MB initially
budgeted in TASKS.md Phase 9.1; the lighter envelope corresponds to
Piper's "low" quality voice. The size delta is accepted in v1 — the
audio-quality improvement over OS TTS is the entire point of the
phase, and 60 MB sits well inside the iOS App Store thin-binary
ceiling for an app bundle.

Bundled-asset audit: `flutter build apk --analyze-size` produces a
breakdown that should report ≤ 65 MB attributed to `assets/tts/`.
The audit is a build-step concern (no Dart unit test gates it).

### Invariants

- **Every backend is an interface.** `LLMProvider`, `StorageProvider`,
  `TTSProvider`, `AuthProvider`, `AnalyticsProvider` are abstract
  classes. The app NEVER imports a concrete impl directly; it goes
  through a riverpod provider that wires the impl chosen by build
  mode (`--dart-define=DEMO_MODE=true` flips fakes on).
- **No API keys in source.** Dev uses the local `claude` CLI via the
  shim. Production (`ClaudeAPIProvider` calling api.anthropic.com)
  is deferred to a later phase — not in v1.
- **No "AI" framing in user-facing strings.** The product presents
  "Dr. Natali's coaching". The LLM is invisible. The Settings → About
  Methodology disclosure + brand-credit card were removed (2026-06-06,
  user call); AI is now mentioned nowhere in the UI. Any future
  disclosure belongs in a privacy/terms doc, not a Settings card.
- **No live LLM in `test/`.** Widget + service tests use
  `FakeLLMProvider`. Live LLM only in `integration_test/` and real
  app runs.
- **Medical-advice guardrails are non-negotiable.** Every decoder
  result carries a footer:
  *"For caregiving communication only — not a substitute for medical
  advice. Call your doctor for medication or diagnosis questions."*
- **Demo mode default = clean state on launch.** A Settings toggle
  ("Reset on launch (demo mode)") flips that for testing. Real-user
  builds never reset.
- **New user-facing strings go through ARB.** Add the key + an
  `@key` description to `lib/l10n/app_en.arb`, run `flutter gen-l10n`,
  and read it via `AppLocalizations.of(context).<key>` (non-null —
  `nullable-getter: false`). Don't hardcode new English UI copy. Any
  `MaterialApp` that renders a screen reading `.of(context)` — including
  the ones pumped in widget/golden tests — must register
  `AppLocalizations.localizationsDelegates` + `supportedLocales`, or
  `.of(context)` throws. (The bulk of pre-#18 screens still hold inline
  English; converting them is tracked follow-up under #18 — the
  framework + the `community_guidelines_screen` reference conversion
  are the v1 deliverable.)
- **`flutter analyze` must be clean** before any task can ship.
  `flutter test` must be green.
- **Test coverage gate.** The autoloop's test gate runs
  `flutter test --coverage`, strips generated files
  (`*.g.dart`, `*.freezed.dart`, `**/generated/**`), and parses
  the resulting `coverage/lcov.info` via `lcov`. Threshold is
  **ramped by phase**:
  - Tasks 1–4 (scaffold + theme + routing + tab scaffold):
    **60%** line coverage minimum
  - Tasks 5+ (all subsequent tasks): **80%** line coverage minimum
  Phase is detected by counting `^- [x]` lines in `TASKS.md` at
  gate run time. Iters that drop coverage below threshold roll
  back automatically. New code without tests is not acceptable.
- **Golden tests for every screen.** Use the `alchemist`
  package — handles font-rendering differences across host
  platforms so goldens stay portable. Every screen widget gets
  at least one default-light-theme golden. Dark-mode and
  large-font variants are added during the manual polish pass
  (Phase 8 + after), not by the autoloop. Goldens live under
  `test/golden/` and run as part of `flutter test`.

---

## 2. Repository layout

```
careblazers/
  BUILD_SPEC.md          ← this file
  TASKS.md               ← autoloop queue
  CLAUDE.md              ← agent context
  README.md
  pubspec.yaml
  lib/
    main.dart
    app.dart             ← MaterialApp.router + theme + scope
    theme.dart           ← brand tokens (§3)
    routing/
      router.dart        ← go_router config
    providers/           ← riverpod providers + abstract interfaces
      llm_provider.dart
      storage_provider.dart
      tts_provider.dart
      auth_provider.dart
      analytics_provider.dart
      settings_provider.dart
    models/              ← freezed
      behavior.dart
      triage.dart
      decoder_result.dart
      journal_entry.dart
      patient.dart
      script.dart
      settings.dart
    services/
      decoder_service.dart
      pattern_detector.dart
      pdf_exporter.dart
    screens/
      home_screen.dart
      decoder/
        behavior_picker_screen.dart
        triage_screen.dart
        decoder_result_screen.dart
      journal/
        journal_screen.dart
        journal_entry_screen.dart
      library/
        library_screen.dart
        library_card_screen.dart
      crisis/
        crisis_card_screen.dart
      settings/
        settings_screen.dart
      onboarding/
        welcome_carousel.dart
        sign_in_screen.dart
    widgets/
      brand_button.dart
      voice_button.dart
      caption_fade.dart
      tab_scaffold.dart
    db/
      database.dart
      tables.dart
    seed/
      mary_henderson.dart
      sample_journal.dart
      library_cards.dart
  test/
    providers/
    services/
    screens/
    widgets/
  integration_test/
    demo_tour.dart
  tools/
    claude_shim.py
    pdf_template.html
  ios/
  android/
  assets/
    images/              ← logo, Natali photo placeholder, icons
    seed/                ← any seed JSON if non-trivial
```

---

## 3. Brand identity (sourced from careblazers.com, 2026-05-28)

### 3.1 Color tokens (verbatim hex)

| Token | Hex | Usage |
|---|---|---|
| `primary` | `#1f2a44` | AppBar, H1 headings, primary text on light surfaces |
| `primarySoft` | `#2a3b61` | Sub-headings, navigation icons |
| `text` | `#33373d` | Body text (warmer than pure black) |
| `cta` | `#C97458` | Primary action button (decoder result CTAs, send buttons, the center mic). Salmon — a deliberate rebrand to match careblazers.com (commit 33d497f); the original spec value was `#ff6900` orange. |
| `accentDeep` | `#cc3366` | Warning highlights ("Don't say…"), rare emphasis |
| `surfaceWarm` | `#f8f6f3` | Section backgrounds, secondary surfaces |
| `background` | `#ffffff` | Page base |
| `link` | `#4054b2` | Hyperlinks, "Talk to Natali" outbound action |
| `error` | `#cf2e2e` | Form validation, hard errors |
| `success` | `#2a7c4f` | "That helped" outcome chip (derived; not on the site, but on-brand) |

Light mode only in v1. Dark mode is auto-applied after 6pm local
(brand-friendly dark: `#0f1422` background, `#e8e6e2` text, orange CTA
unchanged). The dark palette is derived to maintain WCAG AA contrast
against the brand colors.

### 3.2 Typography

- **Body**: `Lato` via `google_fonts.getFont('Lato')`.
  Weights used: 400 (regular), 700 (bold).
- **Headings**: `Montserrat` via `google_fonts.getFont('Montserrat')`.
  Weights used: 600 (semibold), 700 (bold).

Type ramp (logical names map to `TextTheme`):

| Style | Family / Weight | Size | Usage |
|---|---|---|---|
| `displayLarge` | Montserrat 700 | 32 | Home single-line big-button text |
| `headlineLarge` | Montserrat 700 | 26 | Decoder "Dr. Natali says:" header |
| `headlineMedium` | Montserrat 600 | 22 | Screen titles in AppBar |
| `titleLarge` | Montserrat 600 | 20 | Section headers |
| `bodyLarge` | Lato 400 | 20 | Default body (LARGE by default — audience is 60+) |
| `bodyMedium` | Lato 400 | 16 | Secondary copy |
| `labelLarge` | Lato 700 | 18 | Button labels |

20pt body default. Font size is also adjustable in Settings (Small / Medium / Large / X-Large multipliers: 0.875× / 1.0× / 1.15× / 1.35×).

### 3.3 Voice + tone of UI copy

- Tagline (used on welcome carousel): *"We make caregiving for someone with dementia easier."* (Note: **easier**, not easy. The brand never overpromises.)
- Headline (sign-in screen): *"Expert dementia guidance for families who care."*
- Always: "your loved one with dementia" or "your loved one" or "your person." Never "the patient", "the dementia sufferer", "the user" (in caregiving context).
- Always: "Careblazer" as the audience self-identifier (Natali's brand vocabulary).
- Never on primary CTAs: emojis. Body / secondary surfaces can use sparingly (📞 ⚠ on Crisis card sections).
- Decoder voice: warm + competent. Caregiver is exhausted; copy should respect that. Avoid exclamation marks. Use second-person ("you might try…"). Direct quotes for what to say go in quote marks.

### 3.4 App icon + branding

- App icon: white "**C**" in Montserrat 700, centered on a `#ff6900` rounded-square. iOS 16+ uses native rounding mask.
- Splash: navy `#1f2a44` background, centered orange "**C**" identical to icon at 80pt.
- App display name: `Careblazers`.
- Bundle ID: `com.careblazers.app`.

---

## 4. Information architecture

### 4.1 Navigation model

The information architecture is governed by
[`docs/MENU_LAYOUT_SPEC.md`](docs/MENU_LAYOUT_SPEC.md) — the
authoritative IA doc the Phase 14 refactor builds against. This
section is the BUILD_SPEC restatement of that contract; where the two
disagree, the layout spec wins. Only the accessibility constraints
from that doc carry over as hard visual rules (large tap targets,
large readable text, high contrast, word labels alongside icons). The
palette/fonts in the layout spec's companion HTML are placeholders —
ignore them; the brand tokens in §3 remain load-bearing.

- **Fixed 4-tab bottom bar** (IA refactor 2026-06-06), persistent on
  every screen, in this exact order: `Home` · `Care` · `Chat` ·
  `Community`. ("Medical" was renamed **Care**; the former "Team" tab
  folded into Care as a gated "Care Circle" hub. Route paths stay
  `/medical` + `/team/*` internally.)
  ("Care Team" is the full name; the tab label is `Team` so it fits
  the bar.) Built with `go_router`'s `StatefulShellRoute` — one branch
  per tab, each branch keeping its own navigation stack.
- **Five equal-width tabs, always shown, never collapsed.** Each tab
  is **icon + word label**, both always visible. The active tab is
  clearly highlighted.
- **No hamburger / no hidden menu anywhere.** Account, settings, and
  help sit behind a **profile icon on the Home screen** — NOT in the
  tab bar, NOT in a drawer.
- **Tile-hub vs. direct-landing.** Each tab has one of two landing
  behaviors, and the distinction is invariant:
  - **Direct-landing tabs** open straight to their content:
    - `Home` → a vertical scroll of dashboard cards (the "Today"
      dashboard).
    - `Chat` → a conversation list.
    - `Community` → the social Feed (with an in-tab Feed · Learn ·
      Support sub-nav).
  - **Tile-hub tabs** open to a grid of large labeled tiles, each
    tile = icon + label + short sub-label:
    - `Medical` → tile hub.
    - `Team` (Care Team) → tile hub.
- **Tapping the already-active tab** returns the user to that
  section's landing/hub (clears that branch's stack back to root).
- **Two-levels-max depth rule.** The deepest any flow goes is
  Section → (tile hub) → feature page. Anything that would be a third
  level uses **in-page tabs or a segmented control** instead of
  another grid of tiles. (The Community Feed/Learn/Support sub-nav is
  the canonical example: a sixth destination's worth of content lives
  inside one tab rather than adding a sixth tab.)
- **Path-header + word-labeled-Back invariant.** Every feature page
  below a hub shows, at the top:
  - the **path** as tappable breadcrumb segments, e.g. `Home › Medical`
    followed by the page title (e.g. "Medications"). Tapping a parent
    segment navigates up to it.
  - an explicit **word-labeled Back control** (e.g. "‹ Back to
    Medical"). Never rely on swipe gestures or the bare OS back arrow
    alone — the label always names the destination.
  - Landing screens (Home, Chat, Community, and the Medical / Care
    Team hubs themselves) show just the section title — **no
    breadcrumb and no Back**, because they are top level.
- **Routing mechanics.** Tab switching uses `context.go` to the
  branch's root. Pushing a feature page onto a hub (e.g. Medical hub →
  Medications) uses `context.push` so the back-stack survives and the
  path-header Back control resolves to the parent. Inside a pushed
  stack, `context.go` is acceptable for "back to a fixed location"
  patterns (e.g. a completed decoder flow returning to Home).

### 4.2 Screen map

```
Welcome carousel (onboarding) ─ Sign-in screen
                  │
                  ↓ (after sign-in OR demo skip)
                  │
   ┌──────────┬──────────┬──────────┬──────────┬──────────────┐
   ↓          ↓          ↓          ↓          ↓              │
┌──────┐  ┌───────┐  ┌──────┐  ┌──────┐  ┌───────────┐       │
│ Home │  │Medical│  │ Team │  │ Chat │  │ Community  │       │
│(cards)│ │ (hub) │  │(hub) │  │(list)│  │  (feed)    │       │
└──┬───┘  └───┬───┘  └──┬───┘  └──┬───┘  └─────┬─────┘       │
   │          │         │         │            │              │
   │          │         │         │       Feed·Learn·Support  │
   │          │         │         │       (in-tab sub-nav)    │
   │          │         │         │                           │
   │   ┌──────┴──────┐  │    ┌────┴─────┐                     │
   │   ↓ feature      │  │    ↓ thread   │                     │
   │  pages (2 deep): │  │  conversation │                     │
   │   Medications    │  │               │                     │
   │   Medication     │  │  ┌──Team feature pages (2 deep):    │
   │     Schedule     │  └─▶│   Calendar · Tasks · Shifts ·    │
   │   Appointments   │     │   Care Circle · Activity ·       │
   │   Health Log     │     │   Expenses                       │
   │   Care Plan      │     └──────────────────────────────────┘
   │   Cards & Docs   │          (Cards & Docs → Emergency Card)
   │     ├─ Emergency │
   │     │  Card      │
   │   Journal        │
   │                  │
   ↓                  │
 Pinned Emergency Card (also reachable in one tap from Home)
 + Decoder flow: Home → behavior picker → triage → result
   (pushed; returns to Home on "That helped")

           ↑
    👤 Profile → Settings / account / help
       (push from Home top-right — NOT in the tab bar)
```

Depth never exceeds two levels: Section → (tile hub) → feature page.
The decoder flow (behavior picker → triage → result) is a pushed
linear stack launched from Home and is exempt from the tile-hub
shape — it is a guided wizard, not a navigable hub. The Emergency
Card is pinned on Home for one-tap crisis reach and also lives under
Medical → Cards & Documents.

---

## 5. Screen specifications

Every screen below must include:
- Widget tests covering the documented behaviors
- VoiceOver / TalkBack semantic labels on all interactive elements
- Respect for the user's font-size multiplier setting
- Dark-mode-aware colors (use `theme.colorScheme.X`, not raw hex in
  build methods)

### 5.1 Home

**Purpose**: One tap solves the crisis. Nothing else.

**Layout** (top to bottom):
- AppBar: title "Careblazers" (`headlineMedium`), top-right `⚙` gear that pushes `/settings`.
- Vertical stack centered in viewport (above tab bar):
  - "What's happening" / "right now?" — two-line `displayLarge` text.
  - "[tap to start]" — `bodyLarge` secondary, 16pt below.
  - Entire area is a single GestureDetector. Min tap target: 60% of screen height. Background: `surfaceWarm`.
  - Pushes `/decoder/behavior`.
- Below (separated by `surfaceWarm` divider):
  - "Quick reassurance →" — small ListTile, pushes a static info screen with 3 calming techniques (placeholder for now: "Take a deep breath. Lower your voice. Sit at their eye level.")
  - "Doctor visit prep →" — pushes `/journal` filtered to last 30 days with the export-PDF button highlighted.
- Bottom: tab bar.

**State**:
- Watches `activeChatSession` provider to surface "Continue last…" affordance if a decoder flow was interrupted (back-button mid-flow). Optional in v1 demo.

**Empty state**: N/A — Home is always the same.

**Tests**:
- Gear icon pushes `/settings`.
- Main button pushes `/decoder/behavior`.
- "Quick reassurance" and "Doctor visit prep" links route correctly.
- BackButton NOT visible on Home (it's the root of the Home tab).

### 5.2 Behavior picker (`/decoder/behavior`)

**Purpose**: Pick which behavior is happening.

**Layout**:
- AppBar: back arrow (auto, since pushed) + 🔊 voice toggle in actions.
- Centered "What's happening?" `headlineLarge`.
- 4×2 grid of behavior cards (8 cards). Each card:
  - Top: emoji glyph (24pt, color-shifted to brand tones)
  - Bottom: 2-line label, `titleLarge`
  - Background: `surfaceWarm`, rounded 16px, soft shadow.
  - Tap → push `/decoder/triage` with the chosen behavior.
- Below grid: full-width pill-shaped button "✍ Something else — describe it" → pushes a screen with a single voice/text input that classifies via LLM. (v1 simple: text input only; voice input is a v1.1 polish item.)

**The 8 canonical behaviors** (locked):

| ID | Label | Glyph |
|---|---|---|
| `upset` | Upset / crying | 💔 |
| `refusing_care` | Refusing care | 🚪 |
| `wants_home` | "I want to go home" | 🏠 |
| `asking_for_someone` | Asking for someone | 👤 |
| `accusing` | Accusing me | 💸 |
| `sundowning` | Sundowning | 🌅 |
| `wandering` | Wandering / pacing | 🚶 |
| `hallucinating` | Seeing things | 👁 |

**State**: Stateless screen — selection routes directly.

**Tests**:
- All 8 cards render with correct labels.
- Tapping any card pushes `/decoder/triage` with the behavior ID in route state.
- "Something else" button pushes `/decoder/triage` with the free-text path.

### 5.3 Triage (`/decoder/triage`)

**Purpose**: Three short questions that constrain the LLM call.

**Layout**:
- AppBar: back arrow + behavior-label chip.
- Progress indicator: "1 of 3" / "2 of 3" / "3 of 3".
- Question text in `headlineMedium`.
- Single-column list of 4–5 full-width pill buttons (single-select).
- "Next →" CTA in `cta` orange, only enabled after selection.

**The 3 questions** (asked in this order regardless of behavior):

1. **When does it tend to happen?**
   - Morning · Afternoon · Late afternoon / evening · Night · Just started — don't know yet

2. **What changed recently?**
   - Nothing · Schedule · Medication · Health (UTI, illness) · Environment (new place, visitors) · Don't know

3. **What have you already tried?**
   - Talked to them about it · Tried to explain · Walked away · Distracted them · Nothing yet — just started

**State**:
- Tracks selected answers in a riverpod `triageProvider`.
- On "Next" from Q3, calls `decoderService.decode(behavior, triage)`.
- During the LLM call, navigates to `/decoder/result` immediately and the result screen shows streaming output.

**Tests**:
- Sequential question progression (Q1 → Q2 → Q3 → result).
- Back button on Q2/Q3 returns to prior question with prior selection preserved.
- "Next" disabled until selection made.

### 5.4 Decoder result (`/decoder/result`) — THE WEDGE

**Purpose**: Deliver Dr. Natali's script for the current moment.

**Layout** (top to bottom):
- AppBar: back arrow + 🔊 PLAY (plays all sections sequentially in OS TTS).
- "Dr. Natali says:" — `headlineLarge`, navy.
- Divider.
- "**Try saying:**" — `titleLarge` heading.
  - For each of 2–3 "say" entries: large quote-style block, `bodyLarge`. Each block has a small ▶ play button on the left that reads JUST that line in OS TTS.
  - Word-by-word fade-in (~120ms/word) as LLM streams. Respects `Reduce Motion` accessibility.
- Divider.
- "**Try this in the room:**" — `titleLarge`.
  - Bullet list of 1–2 environmental tweaks.
- Divider.
- "**Don't say:**" — `titleLarge`, color `accentDeep`.
  - 1–2 ✗ entries.
- Footer (small, always visible):
  - *"For caregiving communication only — not a substitute for medical advice. Call your doctor for medication or diagnosis questions."*
- Three full-width outcome buttons stacked:
  - ✓ **That helped — log it** (`cta` orange) → logs success in journal, pops to home.
  - → **Try a different approach** → re-runs LLM with `attempt_count + 1`, "what I tried" augmented with the just-shown script.
  - 💬 **I need to talk to Natali** — light secondary, opens external URL `https://careblazers.com/care-collective?utm_source=app&utm_medium=decoder` in in-app browser.

**State**:
- Watches `decoderResultProvider(behaviorId, triage, attempt)` which:
  - Returns `AsyncLoading` while streaming
  - Streams partial result as `AsyncData<PartialDecoderResult>`
  - On error: `AsyncError` with retry button
- Auto-logs to journal on screen mount (entry: `{behavior, triage, scripts, timestamp}`).
- "That helped" updates the entry with `outcome: positive`.

**Tests**:
- LLM streaming renders incrementally (use a FakeLLMProvider that emits chunks).
- "That helped" calls `journalRepository.markOutcome(positive)`.
- "Different approach" re-invokes LLM with `attempt + 1`.
- Error state shows retry, hides outcome buttons.
- VoiceOver reads in section order: header → say → tweak → don't-say → footer.

### 5.5 Journal (`/journal`)

**Purpose**: Auto-filled byproduct of decoder use; the doctor-visit defense.

**Layout**:
- AppBar: title "Journal" + "Export PDF" action (top-right).
- "This week" summary card:
  - "📊 N incidents logged"
  - Sub: "(last week: M — improving / about the same / increasing)"
  - "Most common:" + top 3 behavior counts.
- "⚠ Heads up" card (only when `patternDetector` flags something):
  - "3 falls this week. Worth mentioning at the next visit."
  - Other flags: "5+ sudden behavior changes", "New medication side effect signs", "UTI red flags" (drinking less + confusion + agitation).
- Today section, then Yesterday, then earlier — grouped chronologically:
  - Each entry: `🌅 7:42 PM   Sundowning`
  - Sub: "What worked: dimming lights"
  - 🔊 chip if voice note attached; 📷 chip if photo.
  - Tap → push `/journal/:id`.
- Bottom: "+ Add note (voice or text)" full-width.

**Empty state**: When journal is empty:
- 🌱 illustration (use Font Awesome equivalent via `flutter_svg`)
- "Your journal fills itself."
- "Each time you use the decoder, the moment gets logged here automatically. Try it once and come back."
- CTA: "Open the decoder" → pushes `/decoder/behavior`.

**State**:
- Watches `journalEntriesProvider` which streams from drift.
- `patternDetectorProvider` (a separate service) returns alerts based on rules in §7.

**Tests**:
- Empty state renders when zero entries.
- Entries grouped by today/yesterday/older correctly.
- Pattern detector flags 3+ falls in 7-day window.
- Export PDF button calls `pdfExporter.exportRange(last30Days)`.

### 5.6 Journal entry detail (`/journal/:id`)

**Purpose**: Read one entry, add voice/photo, edit notes.

**Layout**:
- AppBar: back, date/time of entry, kebab menu (Delete).
- Behavior chip + outcome chip.
- "What you tried" — read-only quote of the decoder scripts.
- "Result" — outcome chip (positive / "different approach used" / no outcome).
- "Notes" — editable text field (defaults empty).
- Voice note: 🎙 record button, plays back inline once attached.
- Photo: 📷 attach button, thumbnail inline once attached.
- Save button.

**State**:
- Reads + writes through `journalRepository`.

**Tests**:
- Voice note record + playback.
- Photo attach + display.
- Notes edit + save persists across rebuild.

### 5.7 Library (`/library`) — REMOVED in Phase 14

> **Removed in Phase 14 — see Phase 14.23.** The standalone Library
> tab no longer exists in the 5-tab IA (§4.1). Its educational content
> (Dr. Natali's framework primers + the 12 seed cards in §9.4) is
> re-homed under **Community → Learn** (the Careblazers content
> library; see §5.16). The card-detail reader survives as the Learn
> article reader. Phase 14.23 owns the migration. The historical spec
> is retained below for reference until that task lands.

**Purpose**: Topical primers on Dr. Natali's frameworks. Not coaching — education.

**Layout**:
- AppBar: title "Library".
- "Today's card" (rotates daily; deterministic by date so the same date always shows the same card):
  - Large card, surfaceWarm background.
  - Card title + 1-sentence hook.
  - Tap → push `/library/:id`.
- "Most-asked behaviors" section header.
- Vertical list of cards (titled):
  - "Sundowning"
  - "Why she doesn't know she has dementia (anosognosia)"
  - "When family doesn't believe the diagnosis"
  - "Anger and aggression"
  - "The 5 Causes — Dr. Natali's framework"
  - "Step into their reality"
- "For YOU, the caregiver" section header:
  - "Why you feel guilty"
  - "Boundaries with compassion"
  - "When to ask for respite"

**State**: Static list driven by `lib/seed/library_cards.dart` (each card has id, title, hook, body text — see §9).

**Tests**:
- Today's card rotates by `today() % cardCount`.
- All cards tap-through to detail screen.

### 5.8 Library card detail (`/library/:id`)

**Purpose**: Read or listen to a 60–90 second primer.

**Layout**:
- AppBar: back, share action.
- Title (`headlineLarge`).
- 🔊 PLAY button — when tapped, reads the body in OS TTS (since we don't have Natali audio yet).
- Body (`bodyLarge`, generous line height).
- "Related decoder behaviors" — at the bottom, a strip of chips that deep-link into the decoder for each linked behavior.

**State**: Loads from `library_cards.dart` seed.

**Tests**:
- Play button reads body via TTS provider.
- Related-behavior chips deep-link correctly.

### 5.9 Crisis card (`/crisis`) — REMOVED in Phase 14

> **Removed in Phase 14 — see Phase 14.41.** The standalone Crisis
> tab is gone in the 5-tab IA (§4.1). Its function is replaced by the
> **Emergency Card** (§5.17), which lives under **Medical → Cards &
> Documents** AND is pinned to the top of the Home dashboard for
> one-tap crisis reach. Phase 14.41 owns the rebuild; the inline-edit,
> print/QR, and `patientProvider` backing all carry forward. The
> historical spec is retained below for reference until that task
> lands.

**Purpose**: A single-screen reference for paramedics / ER staff.

**Layout** (one scrollable card):
- AppBar: title "Hospital handoff card" + "🖨 Print" + "📷 QR" actions.
- 👤 Patient name, age, condition, diagnosis date.
- 💊 Medications (list).
- ⚠ Allergies.
- "**What calms her:**" bullets (editable).
- "**What escalates her:**" bullets (editable).
- 📞 Primary caregiver name + phone.
- 📞 Healthcare POA name + phone.
- ⚙ Advance directive status ("on file at X / DNR Y/N").
- Footer: small "Updated [date]" timestamp.

**Editing**: Inline edit per field (tap to edit → text field appears).

**Print**: Generates a PDF via `pdfExporter.crisisCard(patient)`. The PDF includes a QR code in the corner that encodes a public-safe summary URL (TBD — for v1, the QR encodes nothing or a placeholder URL).

**State**: Backed by `patientProvider` → `patientRepository` (single patient per app, single row in `patient` table).

**Tests**:
- Inline edit + save.
- Print button generates PDF.

### 5.10 Settings (`/settings`)

**Purpose**: All preferences live here.

**Layout** (grouped sections):

**Read scripts aloud** (audio):
- Toggle: "Read scripts aloud" (default ON)
- Voice picker: dropdown of OS-installed voices
- Speed: slider (slow / normal / fast)
- "Quiet hours" sub-toggle (default ON, 10pm–7am)
- "Always allow audio" override

**Font size**:
- Segmented: Small / Medium / Large / X-Large (default Medium)

**Appearance**:
- "Dark mode at night" toggle (default ON, switches after 6pm local)

**Demo mode** (only visible when `DEMO_MODE=true`):
- Toggle: "Reset on launch" (default ON in demo, hidden in real builds)
- Button: "Reload seed data" (re-runs `seedRepository.populateAll()`)

**Account**:
- Email shown
- "Sign out" button (red)
- "Delete account" (red, requires confirmation)
- Only in real builds — hidden in demo mode

**About**:
- App version
- _(Removed 2026-06-06, user call: the "Methodology" disclosure + "Brand & framework credit" cards. The credit's "used with permission" line was inaccurate for the pitch build, and both read as out of place. About now shows only the app version. Any AI disclosure needed later belongs in a privacy/terms doc.)_

### 5.11 Welcome carousel (`/onboarding`)

**Purpose**: 3-screen intro. Sets brand, then routes to sign-in.

**Layout**: PageView with 3 pages + dot indicator + "Skip" top-right + "Next" / "Get started" bottom CTA.

**The 3 pages** (locked copy):

Page 1:
- Big "**C**" orange logo
- "Careblazers"
- "We make caregiving for someone with dementia easier."

Page 2:
- 📱 illustration
- "Your pocket coach for the hard moments."
- "When sundowning hits, when she accuses you of something, when he asks for his mom — tap once. Dr. Natali's framework, in 30 seconds."

Page 3:
- 📔 illustration
- "Your journal fills itself."
- "Every coaching moment auto-logs. Bring the real picture to your next doctor visit — not the 'showtime' one your loved one performs in the exam room."

CTA on page 3: "Get started" → pushes `/sign-in`.

**State**: `onboardingCompletedProvider` flips true on "Get started"; router redirects past welcome on next launch.

### 5.12 Sign-in (`/sign-in`)

**Purpose**: Google + Apple OAuth.

**Layout**:
- AppBar: blank (no back).
- Top: "Careblazers" wordmark + tagline.
- Two buttons:
  - "Continue with Apple" (black, Apple's signature) — only shown on iOS.
  - "Continue with Google" (white with Google logo).
- Below buttons (small): "By continuing, you agree to our [Terms] and [Privacy Policy]." (Both placeholder URLs; routes to a TBD screen.)
- DEMO_MODE only: "Skip — explore as Mary's caregiver" button below the OAuth buttons.

**State**: Calls `authProvider.signInWithApple()` or `.signInWithGoogle()`. On success, routes to `/`.

**Tests**:
- Tapping Google → mocked `authProvider.signInWithGoogle()` called.
- DEMO_MODE skip button visible only under `--dart-define=DEMO_MODE=true`.

---

The following sections (§5.13–§5.17) specify the Phase 14 IA screens
introduced by [`docs/MENU_LAYOUT_SPEC.md`](docs/MENU_LAYOUT_SPEC.md).
Phase 14 task numbers own the implementation; the specs here are the
contract those tasks build to. The §4.1 invariants apply to every one:
direct-landing tabs show only a section title (no breadcrumb/Back);
tile-hub tabs render a 2-column grid; every feature page below a hub
carries the tappable path-header breadcrumb + a word-labeled Back
control; depth never exceeds two levels.

### 5.13 Medical hub (`/medical`) — tile hub

**Purpose**: The single entry point to everything clinical — meds,
appointments, health log, care plan, documents, journal. A tile hub,
not a dashboard.

**Landing behavior**: Tapping the `Medical` tab opens this hub
directly. Tapping the already-active `Medical` tab returns here
(clears the Medical branch stack to root). This is a **landing
screen** — header shows just the section title "Medical"; **no
breadcrumb, no Back control.**

**Layout**:
- Header: "Medical" (`headlineMedium`). No breadcrumb (top level).
- Two-column grid of large tiles. Each tile = icon (top) + label +
  short sub-label, `surfaceWarm` background, rounded 16px, soft
  shadow, large hit area. Tiles (in order):

  | Tile | Sub-label | Pushes |
  |---|---|---|
  | **Medications** | doses & reminders | `/medical/medications` |
  | **Medication Schedule** | daily timeline | `/medical/schedule` |
  | **Appointments** | calendar & visits | `/medical/appointments` |
  | **Health Log** | symptoms & vitals | `/medical/health-log` |
  | **Care Plan** | routine & stages | `/medical/care-plan` |
  | **Cards & Documents** | emergency card, POA, IDs | `/medical/documents` |
  | **Journal** | care notes | `/medical/journal` |

- Target 4–6 tiles per hub; this hub is at the upper bound (7).
  Medications + Medication Schedule MAY be merged into one tile with
  an in-page toggle if a trim is wanted (the two-levels-max rule
  prefers an in-page segmented control over a deeper grid). The
  Journal tile re-homes the former `/journal` screens (§5.5–§5.6) —
  per the layout spec, Journal may alternatively move under
  Community → Support if it proves to be primarily caregiver
  reflection; defer that call to the Phase 14 implementer.

**Feature pages**: each tile pushes a single feature page (level 2).
Those pages carry the path-header (`Home › Medical` → page title) and
a word-labeled Back ("‹ Back to Medical"). Individual feature-page
specs (Medications, Appointments, Health Log, Care Plan) are owned by
their respective Phase 14 tasks; Cards & Documents contains the
Emergency Card (§5.17).

**Tests**:
- Hub renders all tiles with label + sub-label.
- Each tile pushes its route.
- Landing shows no Back control / no breadcrumb (it is top level).
- Re-tapping the active Medical tab pops to the hub.

### 5.14 Care Team hub (`/team`) — tile hub

**Purpose**: The multi-caregiver orchestration layer — shared
calendar, task assignment, shift coverage, the care-circle roster,
the activity feed, and shared expenses. A tile hub.

**Landing behavior**: Tapping the `Team` tab (labeled `Team` in the
bar; "Care Team" is the full name) opens this hub directly.
Re-tapping the active tab returns here. **Landing screen** — header
shows "Care Team"; **no breadcrumb, no Back.**

**Layout**:
- Header: "Care Team" (`headlineMedium`). No breadcrumb.
- Two-column tile grid, same tile treatment as §5.13. Tiles:

  | Tile | Sub-label | Pushes |
  |---|---|---|
  | **Calendar** | shared schedule | `/team/calendar` |
  | **Tasks** | assign & claim | `/team/tasks` |
  | **Shifts** | coverage & gaps | `/team/shifts` |
  | **Care Circle** | roster, roles & invites | `/team/circle` |
  | **Activity** | feed & handoffs | `/team/activity` |
  | **Expenses** | shared costs | `/team/expenses` |

  Six tiles — within the 4–6 target.

**Feature pages**: each tile pushes one level-2 feature page with the
path-header (`Home › Care Team` → page title) + word-labeled Back
("‹ Back to Care Team"). Feature-page detail is owned by the
per-tile Phase 14 tasks.

**Tests**:
- Hub renders all six tiles.
- Each tile pushes its route.
- Landing shows no Back / no breadcrumb.
- Re-tapping the active Team tab pops to the hub.

### 5.15 Chat (`/chat`) — direct landing (conversation list)

**Purpose**: Messaging across the care circle and provider threads.

**Landing behavior**: Tapping the `Chat` tab opens **straight to the
conversation list** — no hub. **Landing screen** — header shows
"Chat"; **no breadcrumb, no Back.**

**Layout**:
- Header: "Chat" (`headlineMedium`).
- Standard message-list layout — a vertical list of conversation
  rows, each: avatar + name + last-message preview + timestamp.
  Conversations include the care-circle group thread, individual
  member threads, and provider threads.
- Tap a row → push the conversation thread (level 2), which carries
  the path-header (`Home › Chat` → conversation name) + word-labeled
  Back ("‹ Back to Chat").

**State**: conversation list streams from the Chat data source behind
the same interface seam pattern as every other backend (§1
invariants); thread detail is owned by its Phase 14 task. See
[`docs/CHAT_FEATURE.md`](docs/CHAT_FEATURE.md) for the chat data model
and provider contract.

**Tests**:
- List renders rows with avatar + name + preview + timestamp.
- Tapping a row pushes the thread.
- Landing shows no Back / no breadcrumb.

### 5.16 Community (`/community`) — direct landing (social feed + sub-nav)

**Purpose**: The caregiver community surface — a social feed, the
Careblazers content library, and caregiver-wellbeing/support
resources. Replaces nothing in the old IA; it is a net-new tab plus
the new home for the former Library content (§5.7).

**Landing behavior**: Tapping the `Community` tab lands on the
**Feed**. **Landing screen** — header shows "Community"; **no
breadcrumb, no Back.**

**Sub-nav (in-tab segmented control)**: at the top of the Community
tab, a segmented control offers three views — **Feed · Learn ·
Support**. This in-tab sub-nav is the canonical application of the
two-levels-max rule: it lets a sixth destination's worth of content
live inside one tab rather than adding a sixth bottom-bar tab (which
would shrink tap targets below what the 65+ audience needs). Switching
segments does NOT push a route or add a Back control — it swaps the
in-page body.

- **Feed** — the social experience. A scroll of posts; each post:
  avatar + name + timestamp + body text + optional image, with
  **word-labeled actions: Like · Comment · Share** (word labels, not
  icon-only, per the accessibility constraint). Includes official
  Careblazers posts and caregiver posts; supports grouping by topic /
  disease stage. (Tapping a post → post detail, level 2, with
  path-header `Home › Community` + word-labeled Back.)
- **Learn** — the Careblazers content library: framework videos and
  "what do I do when…" playbooks. **This is the new home for the
  former Library cards** (§9.4's 12 seed cards migrate here in Phase
  14.23). Tapping a card/article opens the reader (the surviving
  library-card-detail screen, §5.8), level 2, with path-header +
  word-labeled Back.
- **Support** — caregiver wellbeing: burnout self-check, respite
  guidance, expert Q&A, and crisis resources. (Crisis resources here
  are referral/help-line content — distinct from the Emergency Card
  in §5.17, which is the printable medical handoff.)

**Scope guardrail**: Community content is wellness/peer-support, not
medical advice. Support's crisis resources refer users to
professional help; they do not diagnose or prescribe. Honor the §13.1
framing.

**Tests**:
- Lands on Feed by default.
- Segmented control switches Feed / Learn / Support without pushing a
  route (no Back control appears).
- Feed posts render avatar + name + timestamp + body + word-labeled
  Like/Comment/Share actions.
- Learn lists the migrated content cards; tapping opens the reader.

### 5.17 Emergency Card (`/medical/documents/emergency-card`) — replaces §5.9

**Purpose**: A single-screen, printable reference for paramedics /
ER staff — the medical handoff card. This is the §5.9 Crisis-card
function, re-homed and renamed for the Phase 14 IA.

**Reachability (two paths, by design)**:
- Lives under **Medical → Cards & Documents** (level 2 below the
  Medical hub), with the path-header `Home › Medical › Cards &
  Documents` → "Emergency Card" + word-labeled Back.
- **Pinned to the top of the Home dashboard** (§5.18) as a prominent,
  full-width button — one tap opens it from anywhere the user starts,
  for instant crisis reach. The pinned Home entry and the Medical
  location resolve to the same screen.

**Layout** (one scrollable card — carried forward from §5.9):
- Header/title: "Emergency Card" with "🖨 Print" + "📷 QR" actions.
- 👤 Loved-one's name, age, condition, diagnosis date.
- 💊 Medications (list).
- ⚠ Allergies.
- "**What calms her:**" bullets (editable).
- "**What escalates her:**" bullets (editable).
- 📞 Primary caregiver name + phone.
- 📞 Healthcare POA name + phone.
- ⚙ Advance directive status ("on file at X / DNR Y/N").
- Footer: small "Updated [date]" timestamp.

**Editing**: inline edit per field (tap to edit → text field appears).

**Print**: generates a PDF via `pdfExporter.emergencyCard(patient)`
(the former `crisisCard(...)` exporter, renamed). The PDF includes a
corner QR code encoding a public-safe summary URL (placeholder in v1).

**State**: backed by `patientProvider` → `patientRepository` (single
patient, single `patient` row) — unchanged from §5.9.

**Copy note**: per CLAUDE.md vocabulary, the card never says "the
patient" in UI copy — use "your loved one" / the loved one's name.

**Tests**:
- Opens from both the Home pinned button and Medical → Cards &
  Documents, resolving to the same screen.
- Inline edit + save persists.
- Print button generates a PDF.

### 5.18 Home — "Today" dashboard (`/`) — supersedes §5.1 in Phase 14

> Phase 14 reshapes Home from the single-button decoder launcher
> (§5.1) into a **vertical scroll of dashboard cards**. §5.1 remains
> the spec for the decoder-launch affordance, which becomes one card
> in this scroll. The two-levels-max + no-hidden-nav rules apply;
> account/settings/help move behind a **profile icon** (replacing the
> §5.1 gear), top-right of Home.

**Landing behavior**: the `Home` tab opens directly to the dashboard.
**Landing screen** — section title only, no breadcrumb/Back.

**Layout** (top to bottom, a scroll of cards — not a tile grid):
1. Greeting / header, with the **profile icon** top-right →
   pushes Settings / account / help (§5.10). NOT a hamburger.
2. **Pinned Emergency Card** — prominent full-width button at the top.
   One tap opens the Emergency Card (§5.17).
3. **Medications Today** card — today's doses with status (taken /
   due).
4. **Next Appointment** card.
5. **Recent Activity** card — latest care-circle events.
6. A floating **"+ Add"** action for quick logging (voice input
   supported).
- The "What's happening right now?" decoder launcher (§5.1) lives as a
  card in this scroll; tapping it pushes the decoder flow
  (`/decoder/behavior` → triage → result), which returns to Home on
  "That helped". A "catch me up" recent-activity summary may also live
  here.

**Tests**:
- Profile icon pushes Settings (not a drawer).
- Pinned Emergency Card button opens §5.17.
- Decoder launcher card pushes `/decoder/behavior`.
- No Back control on Home (it is the Home-tab root).

---

## 6. Provider interfaces (the swappable seams)

Every backend is an abstract class. The riverpod provider wires the
impl chosen at compile time via `DEMO_MODE` / `USE_FAKES` / etc.
defines.

### 6.1 LLMProvider

```dart
abstract class LLMProvider {
  /// Stream the decoder script for [behavior] + [triage].
  /// Yields incremental `DecoderChunk`s as text arrives.
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  });
}

@freezed
class DecoderChunk with _$DecoderChunk {
  const factory DecoderChunk.partial({required String accumulatedJson}) = _Partial;
  const factory DecoderChunk.done({required DecoderResult result}) = _Done;
  const factory DecoderChunk.error({required String message}) = _Error;
}
```

**v1 implementations**:

- `ClaudeCLIProvider` (real, dev-mode + simulator-on-Mac):
  POSTs to `http://localhost:8765/generate` with `{system, user}`. The
  shim (§8) shells to `claude --print --output-format stream-json`
  and forwards SSE chunks.
- `FakeLLMProvider` (for `test/` + demo tour):
  Returns deterministic, hand-authored responses keyed by
  `behavior.id`. Streams them in 8-token chunks with a 60ms delay
  between chunks so streaming UX is visible in the demo. Defined in
  `lib/seed/fake_llm_seeds.dart`.

**Deferred** (NOT v1): `ClaudeAPIProvider` that calls
`api.anthropic.com` directly — needed for App Store. Not built yet.

### 6.2 StorageProvider (drift wrapper)

```dart
abstract class StorageProvider {
  Stream<List<JournalEntry>> watchJournalEntries({Duration window});
  Future<JournalEntry> insertJournalEntry(JournalEntry entry);
  Future<void> updateJournalEntry(JournalEntry entry);
  Future<void> deleteJournalEntry(String id);

  Future<Patient?> getPatient();
  Future<void> upsertPatient(Patient patient);

  Future<AppSettings> getSettings();
  Future<void> updateSettings(AppSettings settings);

  /// Clear ALL local state. Used by demo-mode reset-on-launch.
  Future<void> reset();
}
```

**v1 implementations**:
- `DriftStorageProvider`: real, backed by `db/database.dart`.
- `InMemoryStorageProvider`: for `test/` widget tests.

### 6.3 TTSProvider

```dart
abstract class TTSProvider {
  /// Speak [text] aloud. Returns when done. Cancellable via [cancel].
  Future<void> speak(String text, {required String voiceId, required double speed});
  Future<void> cancel();
  Future<List<TTSVoice>> availableVoices();
}

@freezed
class TTSVoice with _$TTSVoice {
  const factory TTSVoice({
    required String id,
    required String displayName,
    required String locale,
    required String gender,  // 'female' | 'male' | 'unknown'
  }) = _TTSVoice;
}
```

**v1 implementations**:
- `OSTTSProvider`: wraps `flutter_tts`. Default voice = system default.
  When user changes voice in Settings, persists the choice.
- `NoopTTSProvider`: silent. Used in tests + when settings has "Read aloud" off.

### 6.4 AuthProvider

```dart
abstract class AuthProvider {
  Stream<AuthState> watchAuthState();
  Future<void> signInWithApple();
  Future<void> signInWithGoogle();
  Future<void> signOut();
  Future<void> deleteAccount();
}

@freezed
class AuthState with _$AuthState {
  const factory AuthState.signedOut() = _SignedOut;
  const factory AuthState.signedIn({required User user}) = _SignedIn;
  const factory AuthState.loading() = _Loading;
}
```

**v1 implementations**:
- `RealAuthProvider`: real Google + Apple sign-in. Stores token in
  `flutter_secure_storage`. Backend (token validation) is a future
  concern — for v1, just hold the token locally and treat sign-in as
  authenticated.
- `FakeAuthProvider`: skips OAuth, returns a canned User
  `{email: 'demo@careblazers.app', name: 'Sarah Henderson'}` on
  `signInWithApple()` / `signInWithGoogle()`. Used by demo mode.

### 6.5 AnalyticsProvider

```dart
abstract class AnalyticsProvider {
  void trackEvent(String name, Map<String, Object?> properties);
  void trackScreen(String routeName);
  void setUser({required String userId});
}
```

**v1 implementations**:
- `NoopAnalyticsProvider`: discards everything. Default for v1.
- Real analytics (Mixpanel / Amplitude / RevenueCat) deferred.

### 6.6 SettingsProvider (a riverpod notifier, not a backend interface)

Wraps the AppSettings model and persists every change via
`StorageProvider.updateSettings(...)`.

---

## 7. The decoder flow (the wedge)

### 7.1 System prompt

The `ClaudeCLIProvider` (and future `ClaudeAPIProvider`) constructs
its prompt from this system text + a user message built from the
behavior + triage answers.

```
You are an assistant that produces dementia-caregiving communication
scripts in the voice and framework of Dr. Natali Edmonds (Dementia
Careblazers). Your output is a script the caregiver can use IN THE
MOMENT, in the next 30 seconds.

You are NOT Dr. Natali — you are a tool trained on her teaching
framework. You speak in her style and apply her principles. Never
claim to be her.

CORE PRINCIPLES (apply to every output):

1. Respond to the emotion, not the words. Don't argue with the
   loved one's reality. Don't try to win their story. Comfort
   first; reframe second.

2. The 5 Causes of difficult behaviors are: loss of control,
   relationship strain, actual brain changes, unmet needs, and
   anosognosia (their brain literally cannot perceive that anything
   is wrong). Always consider which is most likely driving this
   moment.

3. Connection, not correction. Don't say "you already asked me
   that" or "that didn't happen" or "she's been gone for years."
   Step into their reality. Redirect, validate, comfort.

4. Use the family's vocabulary: "loved one with dementia", "your
   person", "Careblazer" (for the caregiver). Never "the patient",
   "the dementia sufferer", "the user".

5. Be specific. Concrete scripts the caregiver can say verbatim.
   Concrete environmental changes they can make right now.

FORBIDDEN:

- Do not recommend medications, dosages, or medication changes.
- Do not diagnose conditions or make prognosis claims.
- Do not say "your loved one has X" — you don't know.
- Do not contradict the caregiver's reading of the situation.
- Do not suggest calling 911 unless the caregiver describes a
  life-safety emergency (which they wouldn't via this app).
- Do not use the word "AI", "model", "Claude", "ChatGPT", or
  similar in the output.
- Do not use exclamation marks. The audience is exhausted.

OUTPUT FORMAT:

Respond with ONLY valid JSON matching this schema, no preamble:

{
  "say": [
    "First concrete script the caregiver should try saying.",
    "Second concrete script.",
    "Third concrete script."  // 2-3 entries
  ],
  "tweak": [
    "Concrete environmental change they can make now."
  ],
  "dont_say": [
    "Specific phrase to avoid saying."
  ]
}

Each "say" entry is a direct quote — what the caregiver should say to
their loved one. Use plain conversational English, no quotation marks
inside the string. The caregiver will read it aloud.

Each "tweak" is an action the caregiver can take in the room (lights,
position, distraction, etc.).

Each "dont_say" is a specific phrase or category of phrase to avoid,
including a brief reason if helpful.

EXAMPLE INPUT:
behavior: accusing
when: late afternoon / evening
what_changed: nothing
what_tried: tried to explain

EXAMPLE OUTPUT:
{
  "say": [
    "That sounds really upsetting. I'm here with you.",
    "Tell me more about what you're feeling.",
    "Let's look in your favorite places together — sometimes the
    things we treasure most are also the easiest to misplace."
  ],
  "tweak": [
    "Sit next to her at eye level, not across from her — being
    'aligned' physically makes the conversation feel less like
    interrogation."
  ],
  "dont_say": [
    "Don't say 'no one took anything' or try to prove the item
    wasn't stolen. You're not going to win the story; you'll only
    confirm her sense that something is wrong and no one believes
    her."
  ]
}
```

The system prompt is canonicalized in
`lib/seed/system_prompt.dart` as a const string. Do not paraphrase
it — exact text matters for output consistency.

### 7.2 User message construction

`DecoderService.buildUserMessage(behavior, triage, attempt)` returns:

```
behavior: <behavior.label>
when: <triage.when>
what_changed: <triage.whatChanged>
what_tried: <triage.whatTried>
attempt: <attempt>
patient_context: <patient.stage>, age <patient.age>
```

For free-text "Something else" behaviors, replaces the `behavior:`
line with `behavior_freetext: <caregiver's description>`.

### 7.3 Response parsing

`DecoderService.parseStream(stream)` consumes the LLM's
stream-json output, accumulates the JSON, and yields:

- `DecoderChunk.partial(accumulatedJson)` as bytes arrive — UI uses
  this for streaming display
- `DecoderChunk.done(result)` when the JSON parses fully
- `DecoderChunk.error(message)` if parse fails or stream errors

`DecoderResult` is:

```dart
@freezed
class DecoderResult with _$DecoderResult {
  const factory DecoderResult({
    required List<String> say,
    required List<String> tweak,
    required List<String> dontSay,
    required DateTime generatedAt,
  }) = _DecoderResult;

  factory DecoderResult.fromJson(Map<String, dynamic> json) =>
      _$DecoderResultFromJson(json);
}
```

### 7.4 Voice output

When the user taps PLAY on a section, the TTSProvider reads that
section's text. The TTS voice speaks each `say` entry as a separate
utterance with a 400ms pause between (so it sounds intentional,
not chattering).

### 7.5 Auto-log to journal

On `DecoderChunk.done(...)`, `DecoderService` writes:

```
JournalEntry(
  id: uuid(),
  behavior: behavior,
  triage: triage,
  result: result,
  outcome: pending,  // updated when user taps "That helped" etc.
  attempt: attempt,
  createdAt: now,
)
```

The user never has to take a separate "log this" action. This is the
"journal fills itself" promise from the welcome carousel.

### 7.6 Pattern detector

`PatternDetector` runs every time the journal screen loads. Rules
(v1):

| Rule | Window | Threshold | Alert text |
|---|---|---|---|
| Fall mentions | 7 days | ≥ 3 | "3+ falls this week. Worth mentioning at the next visit." |
| Sundowning entries | 7 days | ≥ 5 | "Sundowning is hitting hard this week. Talk to your doctor about evening routines." |
| UTI red flags | 14 days | confusion + reduced fluid + sudden behavior change | "Sudden changes can be a UTI sign. A quick test rules it out." |
| Sudden decline | 14 days | ≥ 3 distinct new behaviors | "Multiple new behaviors this week. Worth a check-in with the doctor." |

"Falls" detection is naive in v1: matches `result.tweak` or
`entry.notes` containing "fall" or "fell". Future: structured tag.

---

## 8. tools/claude_shim.py

A minimal local HTTP server that wraps the `claude` CLI for dev-mode
LLM calls. The Flutter app's `ClaudeCLIProvider` POSTs to it; it
shells out to `claude --print --output-format stream-json` and
forwards SSE chunks back.

**No external Python deps** — uses stdlib only (`http.server`,
`subprocess`, `json`).

```python
#!/usr/bin/env python3
"""Local HTTP shim that wraps `claude --print` for the Careblazers
dev-mode LLM provider.

Listens on http://localhost:8765/generate. Accepts POST JSON of shape:
  {"system": "...", "user": "..."}
Returns Server-Sent Events (SSE) streaming the model's response.

Usage:
  python3 tools/claude_shim.py
"""

import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8765
CLAUDE_CMD = "claude"


class Handler(BaseHTTPRequestHandler):
    def _bad(self, code, msg):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode())

    def do_POST(self):
        if self.path != "/generate":
            return self._bad(404, "Not Found")
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
            system = payload["system"]
            user = payload["user"]
        except Exception as exc:
            return self._bad(400, f"bad request: {exc}")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        cmd = [
            CLAUDE_CMD, "--print", "--output-format", "stream-json",
            "--model", "claude-sonnet-4-6",
            "--append-system-prompt", system,
            user,
        ]
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, bufsize=1,
            )
            for line in proc.stdout:
                line = line.rstrip("\n")
                if not line:
                    continue
                self.wfile.write(f"data: {line}\n\n".encode())
                self.wfile.flush()
            proc.wait()
            if proc.returncode != 0:
                err = proc.stderr.read()
                self.wfile.write(
                    f"data: {json.dumps({'error': err})}\n\n".encode()
                )
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except FileNotFoundError:
            self.wfile.write(
                f"data: {json.dumps({'error': 'claude binary not found on PATH'})}\n\n".encode()
            )
        except Exception as exc:
            self.wfile.write(
                f"data: {json.dumps({'error': str(exc)})}\n\n".encode()
            )

    def log_message(self, fmt, *args):
        # quieter default logging
        sys.stderr.write("[shim] " + fmt % args + "\n")


def main():
    print(f"[shim] Careblazers LLM shim listening on http://localhost:{PORT}")
    print(f"[shim] Uses local `{CLAUDE_CMD}` binary (your Claude Max subscription).")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
```

This file is written as the deliverable of Task 32 — the agent should
reproduce it verbatim. It is the contract for the
`ClaudeCLIProvider`.

---

## 9. Demo seed data

### 9.1 Patient profile: Mary Henderson

Lives in `lib/seed/mary_henderson.dart`:

```dart
final maryHenderson = Patient(
  id: 'demo-patient-mary',
  name: 'Mary Henderson',
  age: 78,
  diagnosis: 'Alzheimer\'s disease, stage 5 (moderately severe)',
  diagnosedAt: DateTime(2022, 4, 15),
  medications: [
    Medication(name: 'Donepezil', dose: '10 mg', schedule: 'every morning'),
    Medication(name: 'Memantine', dose: '10 mg', schedule: 'every evening'),
    Medication(name: 'Sertraline', dose: '50 mg', schedule: 'every morning'),
  ],
  allergies: ['Penicillin'],
  calms: [
    'Sitting on her left side (she hears better there).',
    'The phrase "Mom, it\'s okay."',
    'Showing her a photo of Dad (passed 2019).',
  ],
  escalates: [
    'Strangers leaning over her.',
    'Loud beeping (monitors, alarms).',
    'Being asked many questions in a row.',
  ],
  primaryCaregiver: Contact(name: 'Sarah Henderson', phone: '(415) 555-0142'),
  healthcarePOA: Contact(name: 'Sarah Henderson', phone: '(415) 555-0142'),
  advanceDirective: AdvanceDirectiveStatus(
    onFileAt: 'Marin General Hospital',
    dnr: false,
  ),
);
```

Loaded into the demo via `seedRepository.populateAll()` on first
launch when `DEMO_MODE=true`.

### 9.2 Sample journal entries

Lives in `lib/seed/sample_journal.dart`. Six entries spanning the last
10 days, each demonstrating a different behavior:

- Sundowning ×3 (last 7 days; triggers pattern alert)
- Refused care ×2
- Accusing ×1
- One "Mom, where's Dad?" entry (asking_for_someone)

Each entry has `result` (full DecoderResult), `outcome: positive` for
most, `outcome: triedDifferent` for one. Two have voice-note
placeholders (a `voiceNotePath` that points at
`assets/seed/sample-voice-1.m4a` — file is silence; the player UI
still works for the demo).

### 9.3 Demo settings defaults

When `DEMO_MODE=true`, the app launches with:

- Audio: ON, voice = system default, speed = normal
- Quiet hours: ON (10pm–7am)
- Font size: Large (per the audience's actual preference)
- Dark mode at night: ON
- Reset on launch: ON (the demo toggle itself)

When the user toggles "Reset on launch" OFF in the demo, state
persists across simulator restarts — useful for testing the live-app
flow without rebuilding.

### 9.4 Library card seeds

Lives in `lib/seed/library_cards.dart`. Twelve cards, each with id,
title, hook, body (300–500 words written in Dr. Natali's voice based
on her actual transcripts). The body text is the source of truth —
no Natali audio in v1; OS TTS reads the body when the user taps
PLAY. The 12 cards:

1. **anosognosia** — "Why she doesn't know she has dementia"
2. **sundowning_basics** — "What's happening between 4pm and bedtime"
3. **respond_to_emotion** — "The single most useful sentence in dementia care"
4. **five_causes** — "The 5 things that drive every difficult behavior"
5. **step_into_reality** — "When she asks for someone who died"
6. **accusations_basics** — "When they accuse you of stealing"
7. **wanting_to_go_home** — "What 'home' actually means"
8. **family_doesnt_believe** — "When your siblings don't believe you"
9. **caregiver_guilt** — "Guilty for being angry. Guilty for being tired. Guilty for being human."
10. **boundaries_compassion** — "Saying no when yes is dangerous"
11. **when_to_ask_respite** — "Permission to step away"
12. **showtime** — "Why she 'presented so well' at the doctor"

Card body content is drafted from the dossier transcripts, paraphrased
to avoid verbatim YouTube content reuse (which would be IP-fragile).
Each card is written in Natali's voice register — warm, direct,
specific. The build expects these to be hand-finalized before the
pitch; the autoloop will scaffold them with placeholder bodies and
note that Phase 8 polish needs to refine each one.

---

## 10. Demo automation

### 10.1 integration_test/demo_tour.dart

(Rewritten 2026-06-11 against the four-tab IA — Home / Care / Chat /
Community on the custom `TabScaffoldBar`; the original 2026-05 script
below it predates the IA refactor and is superseded.)

A scripted walkthrough over the live app. Runs against
`FakeLLMProvider` (decoder) + `DemoChatBackend` (chat) — fully
offline, no shim required.

**Pre-conditions**:
- `DEMO_MODE=true` build define set.
- App launches into welcome carousel → CTA taps → sign-in →
  DEMO_MODE "skip" CTA (FakeAuthProvider) → Home.
- Seed data populated (Mary Henderson + meds/windows + chat threads).

**The tour** (each step taps + settles + asserts something visual,
capturing a screenshot per tab):

1. **Home** — greeting + Schedule card (`01_home`); profile icon →
   Settings (read-aloud toggle asserted) → back via PathHeader.
2. **Dose-log detour** — tap the Donepezil row in the Schedule card's
   Morning group → dose-log list asserted → Home via the breadcrumb.
3. **Care tab** — hub tiles asserted (`02_care`); Health Log tile →
   add a vitals entry (HR 72) → save → back; Routines tile → back;
   Emergency Card tile → Mary Henderson asserted → back.
4. **Care Circle** — entered via the Care hub's `/team` tile
   (`03_care-circle`); People tile → roster + connect actions → back.
5. **Chat tab** — two seeded threads (`04_chat`); open the sundowning
   thread, send a message, assert the deterministic DemoChatBackend
   reply bubble → back.
6. **Community tab** — feed + sub-nav (`05_community`); cycle
   Feed → Learn → Support → Feed segments.

Each step asserts something visual (text, key, or widget type) so
the tour fails loudly on regression rather than silently passing
through a broken screen.

### 10.2 FakeLLMProvider canned responses

In `lib/seed/fake_llm_seeds.dart`. One canonical response per behavior
id. Each is hand-authored to match the system prompt's expected
output schema. These are also useful as few-shot examples for
prompt iteration. Excerpt:

```dart
const fakeSundowningResponse = DecoderResult(
  say: [
    "That sounds really hard. I'm right here with you.",
    "Let's sit together for a moment. You don't have to do anything.",
    "I'm going to dim the lights and put on the song you like — the one we played on Sunday.",
  ],
  tweak: [
    "Dim overhead lights and switch on a single warm lamp. Turn off the TV.",
  ],
  dontSay: [
    "Don't say 'you already asked me that' or 'it's not bedtime yet.' Sundowning isn't logic-resolvable — it's the brain in transition. Comfort first.",
  ],
);

const fakeAccusingResponse = DecoderResult(
  say: [
    "That sounds really upsetting. I'm here with you.",
    "Tell me more about what you're feeling.",
    "Let's look in your favorite places together — sometimes the things we treasure most are also the easiest to misplace.",
  ],
  tweak: [
    "Sit next to her at eye level, not across from her — being 'aligned' physically makes the conversation feel less like interrogation.",
  ],
  dontSay: [
    "Don't say 'no one took anything' or try to prove the item wasn't stolen. You won't win the story; you'll only confirm her sense that something is wrong and no one believes her.",
  ],
);

// ... 6 more, one per behavior id
```

### 10.3 Running the tour

```bash
flutter test integration_test/demo_tour.dart --dart-define=DEMO_MODE=true
```

For the pitch itself, the operator runs the tour live on the iOS
simulator while Natali watches. The tour also screen-records via the
simulator's built-in recording (or QuickTime) so there's a fallback
MP4 in case live demo flakes.

---

## 11. Settings + accessibility

### 11.1 Voice readout

- Per-screen 🔊 button in the AppBar actions of decoder result +
  library card. Single tap toggles audio for that screen only.
- Global setting: "Read scripts aloud" (default ON).
- Voice picker: shows OS-available voices via `flutter_tts`.
- Speed slider: 0.7× / 1.0× / 1.3×.

### 11.2 Quiet hours

- Default ON, 10pm–7am local time.
- When active, audio output is muted regardless of per-screen
  toggle (captions still visible).
- Settings → Quiet hours → "Allow audio anyway" override toggle.

### 11.3 Font size

- Multiplier slider: 0.875× / 1.0× / 1.15× / 1.35×.
- Applied to `MediaQuery.textScaler` at the app root.
- Default 1.0× in real builds, 1.15× in demo mode (the audience
  prefers larger).

### 11.4 Dark mode

- Auto-applied after 6pm local time. Override toggle in Settings.
- Dark palette derived to maintain brand consistency (orange CTA
  unchanged, navy becomes the surface tone).

### 11.5 VoiceOver / TalkBack

- Every tappable widget has a `Semantics(label: ...)` ancestor.
- Decoder result is read in order: header → "say" entries → "tweak" → "don't say" → footer.
- Behavior cards announce "Behavior: sundowning. Double-tap to select."
- The per-line ▶ play buttons announce "Play this script line aloud."

### 11.6 Reduce Motion

- iOS Reduce Motion setting → app skips the caption fade-in
  (text appears instantly).
- All other animations (page transitions, drawer slides) are
  unaffected — they're already gentle.

---

## 12. Anti-features

Per the dossier analysis §7 and confirmed by the user:

- **No memory exercises for the patient.** The audience is the
  caregiver, not the patient. Apps in this category compete with
  Zinnia TV (which Natali endorses).
- **No general longevity / brain-prevention content.** Not the
  audience's pain.
- **No symptom checker / diagnostic flow.** Medical risk + the
  audience has already crossed that bridge.
- **No generic medication reminder.** Apple Health and dedicated
  med-tracking apps do this; we don't compete on table-stakes utility.
- **No "find a facility" placement service.** Mixed audience
  reception to "A Place for Mom"; we don't get into that space in v1.
- **No social feed / community.** Care Collective is Natali's
  community; the app shouldn't compete with her flagship paid product.
- **No gamification.** Streaks, badges, points — all wrong tone for
  caregiving.

---

## 13. Risk + compliance

### 13.1 Medical-advice framing

Every decoder result carries the footer:
*"For caregiving communication only — not a substitute for medical
advice. Call your doctor for medication or diagnosis questions."*

Onboarding includes a parallel disclaimer at the bottom of welcome
page 3: *"Careblazers is not a medical product. It's a coaching tool
for caregiving communication. Always work with your loved one's
doctor for medical care."*

System prompt forbids medication dosing, diagnosis claims, and
prognosis statements (see §7.1).

### 13.2 Privacy + data handling

- Journal entries persist locally in SQLite via Drift. Local-only
  in v1 — no cloud sync.
- Auth tokens persist in `flutter_secure_storage` (Keychain on iOS,
  Keystore on Android).
- No analytics in v1 (NoopAnalyticsProvider).
- No telemetry of decoder content.
- LLM calls in dev mode go through the user's own `claude`
  subscription — no third-party API on their data path.
- Privacy policy + terms of service: TBD pages (placeholder
  routes) — required before App Store submission.

### 13.3 App Store compliance

Deferred until partnership decision lands. Notes for the future
submission:

- iOS "Medical" category likely correct (despite no diagnostic
  intent). Confirm with Apple's guidelines current at submission
  time.
- HIPAA does NOT attach (no covered entity partnership). But
  data-handling expectations exceed HIPAA — local-only by design.
- Disclose "uses generative AI" per Apple's 2024+ guidelines.
  ⚠️ The in-app Methodology page that carried this was **removed
  (2026-06-06)** — so this disclosure now needs another home before a
  real App Store submission: App Store Connect metadata and/or a
  privacy/terms page, NOT a Settings card.

### 13.4 Brand + framework credit

- App uses the name "Careblazers" — Natali's audience-identifier.
  V1 demo is a pitch artifact; partnership conversation IS the
  authorization vehicle.
- The Settings → About "Brand & framework credit" card was **removed
  (2026-06-06, user call)**: its "used with permission" line was
  inaccurate for the pitch build (permission is still pending), and
  showing it in the very build being pitched to Natali read as odd. If
  attribution is wanted post-partnership, reintroduce it with accurate
  wording.
- No verbatim YouTube transcripts, course content, or PDF copy from
  Natali's products is embedded in the v1 build. The system prompt
  is style-and-framework derived (paraphrased + structured), not
  copy-pasted.

---

## 14. Acceptance criteria (v1 demo gates)

The build is done when all hold:

1. `flutter pub get && flutter analyze` is clean (no errors,
   warnings tolerated).
2. `flutter test` is green — every screen, service, provider has
   at least one test, and every screen has at least one
   `alchemist` golden test under `test/golden/`. Line coverage
   (per the ramped threshold in §1) holds.
3. `flutter test integration_test/demo_tour.dart
   --dart-define=DEMO_MODE=true` walks through the full tour
   without exceptions.
4. Real LLM round-trip works end-to-end:
   - `python3 tools/claude_shim.py` running
   - `flutter run -d <ios-sim> --no-define DEMO_MODE` (real mode)
   - Tap Home → behavior → triage → result
   - Decoder result streams in from the real `claude` CLI within
     ~10 seconds
   - Parses to valid `DecoderResult`, renders without errors
5. Google + Apple sign-in flows complete on a simulator.
6. Journal auto-logs every decoder use.
7. PDF export from journal produces a valid PDF file (writes to
   simulator share sheet).
8. Crisis card editable fields persist across launches in real mode.
9. Quiet hours suppresses audio between 10pm and 7am simulator
   time.
10. All brand colors come from `lib/theme.dart` — no raw hex in
    screen build methods.
11. Font sizes scale correctly with the Settings multiplier.
12. VoiceOver reads every screen in a sensible order.

---

## 15. Build order

See [`TASKS.md`](TASKS.md). Eight phases, ~35 atomic tasks. Each task
is sized for a ~5–15 min autoloop iter and leaves the suite green.

Phases:

1. **Scaffold + theme** — Flutter project, brand tokens, routing,
   state setup.
2. **Provider interfaces + fakes** — every backend interface + its
   fake impl.
3. **Decoder flow** — Home, behavior picker, triage, result. The
   wedge.
4. **Journal** — auto-log, pattern detector, PDF export.
5. **Library + Crisis card** — secondary surfaces.
6. **Settings + accessibility** — voice, font size, quiet hours,
   save-state toggle, VoiceOver.
7. **Auth + onboarding** — welcome carousel, sign-in.
8. **Demo automation + shim** — `tools/claude_shim.py`,
   `FakeLLMProvider` seeds, `integration_test/demo_tour.dart`.

After phase 8, a manual polish pass (operator + Claude Code directly,
not autoloop) hand-tunes animations, copy, and any visual rough
edges before the pitch.
