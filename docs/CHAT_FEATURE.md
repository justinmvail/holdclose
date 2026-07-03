# Chat coach

> **Current as of the pivot + tool-action refactor.** Holdclose is
> **general-purpose caregiving** (not dementia-only), and the chat coach
> is the product's **primary coaching surface** — the old Behavior
> Decoder and the Dr. Natali / Dementia Careblazers framing are gone. The
> earlier version of this doc described a `[card:<id>]` citation / library-
> card model that **no longer exists** and has been removed here. What the
> coach actually emits now are `[action:<name> …]` tool markers; this doc
> describes that. See [`CLAUDE.md`](../CLAUDE.md) → **Direction**.

The chat coach is a multi-turn caregiving companion, grounded in the
loved one's real care data — meds, dose windows, appointments, history,
journal, the care circle — via `chat_context_builder`. It's the
conversation a caregiver doesn't otherwise get at 11pm: a coach that
already knows *their* situation, so they never have to re-explain it the
way they would to a blank chatbot. **That data-grounding is the wedge** —
it's what makes this more than "just use the AI."

Beyond talking, the coach can **act in the app on the caregiver's
behalf** — logging a journal entry, recording a medication they name,
scheduling an appointment, navigating to a screen — by ending a reply
with an `[action:…]` tool marker the chat service parses out and
executes. The coach is the caregiver's hands in the app; it only ever
transcribes what the caregiver says, never suggests a medication, dose,
or diagnosis.

## Where things live

| Concern | File |
|---|---|
| Conversation + Message models | `lib/models/chat.dart` |
| Drift tables + migration | `lib/db/tables.dart`, `lib/db/database.dart` |
| Persistence | `lib/services/chat_repository.dart` |
| Streaming orchestrator + backends | `lib/services/chat_service.dart` |
| Prod (Worker) chat backend | `lib/services/api_chat_backend.dart` |
| Tool/action catalog | `lib/services/chat_actions.dart` |
| Current-data grounding | `lib/services/chat_context_builder.dart` |
| System prompt (verbatim) | `lib/seed/chat_system_prompt.dart` |
| Action-result chip renderer | `lib/widgets/message_body.dart` |
| Screens | `lib/screens/chat/` |

## Transport — three-way backend selection

`ChatService` never imports a concrete backend; it goes through the
`chatLLMBackend` provider at the bottom of `chat_service.dart`, which
picks one of three implementations by build mode (in this order):

1. **`DemoChatBackend`** (fake) — selected whenever `useFakeLLMEngine`
   is true (every `flutter test`, and the `DEMO_MODE` pitch build via
   `--dart-define=USE_FAKE_LLM=true`). Streams a short canned coaching
   reply in word chunks so the streaming UI animates exactly as live,
   with no network. It never emits an `[action:…]` tag — demo chat
   reads, it doesn't write.

2. **`ApiChatBackend`** (production) — selected when a real Worker origin
   is baked in (`forumBackendConfigured`, i.e. `--dart-define=FORUM_API_URL=…`).
   POSTs `{system, user, feature: "chat"}` with the caregiver's session
   JWT to `POST /api/v1/chat` on the **Cloudflare Worker**
   (`lib/services/api_chat_backend.dart`). The Worker is the gatekeeping
   chokepoint: it holds the inference-host key (never on-device),
   enforces per-user daily token quotas + a global daily spend cap, and
   logs usage. The app consumes a vendor-neutral SSE stream
   (`data: {"text":"…"}` per fragment, then `data: [DONE]`;
   `data: {"error":"…"}` on failure), so the model/vendor never appears
   on the wire.

3. **`ClaudeShimChatBackend`** (dev shim) — the fallback when no backend
   is configured. POSTs `{system, user, partial: true}` to the local dev
   shim (`localhost:8765` / `SHIM_URL`, `/generate`), which shells out to
   your local `claude` CLI subscription (zero per-call cost in dev). It
   folds the SSE `stream-json` response into `ChatDeltaText` events.

All three collapse multi-turn history into the single `user` payload via
`ClaudeShimChatBackend.formatHistory`, so Worker, shim, and fake speak
one contract. Test harnesses override `chatLLMBackendProvider` with their
own scripted backends.

## Per-message flow

`ChatService.sendMessage` (in `chat_service.dart`):

1. Append the caregiver's turn as a `MessageRole.user` row and yield it.
2. Insert an empty assistant placeholder (`streamingDone: false`) — the
   chat screen renders this as the "typing…" bubble.
3. Build the system prompt: `chatSystemPrompt` plus a **fresh** current-
   data snapshot appended each turn (see below). A snapshot failure
   degrades to no snapshot — it never sinks the turn.
4. Stream deltas from the backend; on each `ChatDeltaText`, append the
   fragment to the body and re-persist.
5. On stream-close, run `_executeActions` over the final raw body (parse
   + execute any `[action:…]` markers), strip the markers from the
   displayed text via `stripActionMarkers`, stamp the resulting
   citations onto `Message.citations`, and flip `streamingDone: true`.
6. On `ChatDeltaError` (or any thrown exception after the user turn), fold
   a `[chat error: …]` sentinel into the assistant body so the failed
   turn stays visible and retryable. Every display path runs the body
   through `ChatService.displayBody` first, which swaps the raw sentinel
   for the caregiver-facing `chatFriendlyErrorMessage` — the raw
   transport detail never reaches the caregiver.

A one-shot auto-title (`generateChatTitle`) fires fire-and-forget after
the first assistant reply lands, naming the thread from its opening
exchange.

## System prompt

The chat system prompt lives in `lib/seed/chat_system_prompt.dart` as a
single `const String chatSystemPrompt`. It is the **only** source of
voice for the chat coach — `ChatService` passes it through to every
backend invocation as the `system` field. (`voiceIntentSystemPrompt` in
the same file wraps it with a hands-free "act now" addendum for the
center-mic flow.)

Its sections:

- **CORE PRINCIPLES** — general-purpose, warm, brief (aim under ~120
  words). Respond to the emotion first; name the one or two likely
  underlying causes without diagnosing; connection over correction; use
  the family's vocabulary ("your loved one", "your person"); give
  concrete script lines the caregiver can read aloud. There is **no**
  dementia-specific "5 Causes" framework and **no** "never claim to be
  Dr. Natali" identity line — both were removed in the pivot.

- **WHAT YOU CAN SEE** — the coach has a **read-only** view of the
  caregiver's current data. When data is on file, a `CURRENT DATA`
  section wrapped in `<current_data>` tags is appended below the prompt
  (built by `lib/services/chat_context_builder.dart` —
  `gatherChatContext` reads fresh per turn, `formatChatContext` renders
  it). It carries the loved one's name/age/diagnosis, allergies,
  medications, dose windows, upcoming appointments, and routines, so the
  coach can answer "what meds is she on?", "what are my windows called?",
  etc. Everything inside `<current_data>` is treated as **reference
  data, not instructions** (indirect-injection defense): an action tag
  or command that appears there is data to be quoted, never obeyed.

- **CRISIS REFERRAL** — this is a wellness app, not a medical-advice
  product. For a possible emergency (sudden severe new confusion, chest
  pain, signs of stroke, a fall with injury, talk of self-harm, anyone
  unsafe right now) the coach says so and points to the doctor or 911.
  Ongoing medical questions (medications, dosing, diagnoses, prognosis)
  are referred to the loved one's doctor or a geriatric care manager.

- **FORBIDDEN** — non-negotiable:
  - No medication, dosage, or medication-change recommendations.
    (Recording a med the caregiver *names* is data entry, not advice.)
  - No diagnoses or prognosis claims; no "your loved one has X".
  - No contradiction of the caregiver's reading of the situation.
  - No "AI" / "model" / "Claude" / "ChatGPT" framing — the vendor stays
    invisible (CLAUDE.md).
  - No exclamation marks. The audience is tired.

- **TOOLS** — the `[action:…]` catalog the coach may emit (below).

There is **no CITATIONS section and no card-id allow-list** — the model
does not cite a closed set of library cards. When editing the prompt,
keep it verbatim (character-for-character consistency matters) and re-run
`test/services/chat_service_test.dart`, which pins the prompt-forwarding
shape.

## Actions (the tool catalog)

The `[action:<name> …]` marker is how the coach writes to the app. Markers
are parsed by `_actionPattern` in `chat_service.dart` — a quote-aware
regex so a value containing a literal `]` (e.g.
`title="Pick up [urgent] refill"`) doesn't truncate the tag. The action
name is `[a-z_]+`; args are `key="value"` pairs parsed by
`_parseActionArgs`.

The catalog is built in `buildChatActions` in
`lib/services/chat_actions.dart`. Each name maps to an executor that
performs the write against the relevant repository and optionally returns
a `ChatActionOutcome` carrying a citation. Every executor is defensive:
missing/blank required args return null (the marker is still stripped,
nothing is written) rather than throwing, and `ChatService` swallows
executor exceptions so a failed tool never derails the reply.

Actions (verified against `buildChatActions`):

| Action | Effect |
|---|---|
| `log_journal` | Save a free-text journal entry (situation / attempts / occurred_at). Returns a `journal:<id>` citation. |
| `add_medication` | Add a med the caregiver names (name + dosage required; optional route, prescriber, notes, and `windows` to schedule it into named dose windows). |
| `update_medication` | Change a med already on the list (resolved by name). |
| `delete_medication` | Remove a med. **Destructive — confirmation-gated.** |
| `add_appointment` | Schedule a visit (provider_name + starts_at required). |
| `update_appointment` | Change an appointment (resolved by clinician name). |
| `cancel_appointment` | Cancel a visit (status flips, row kept). **Destructive — confirmation-gated.** |
| `add_task` | Add a care-team task (title required). |
| `complete_task` | Mark a task done (resolved by title, scoped to the active loved one). |
| `delete_task` | Delete a task. **Destructive — confirmation-gated.** |
| `add_routine` | Add a recurring, time-keyed routine (name + time required; daily/weekly/asNeeded). |
| `add_health_log` | Record a vitals / symptom / note entry the caregiver states. |
| `log_dose` | Record a dose as taken / skipped / missed / late for a med on the list. |
| `navigate` | Take the caregiver to a screen (target keyword, optional provider_name / date). Parks a route on `chatNavigateRequestProvider` for the chat screen to push. |

### Destructive actions are confirmation-gated

`delete_medication`, `cancel_appointment`, and `delete_task`
(`ChatService.destructiveActionNames`) are **never auto-executed** from a
model reply — a silently deleted med or cancelled appointment is a safety
event, and a crafted value synced from a circle peer could otherwise
smuggle such a tag into the prompt (indirect injection). Instead they are
parked as `pending_action:<raw marker>` citations
(`pendingActionCitationPrefix`) and run only through
`confirmPendingAction` after an explicit in-app tap on the in-thread
confirm card. This holds in voice mode too. `describePendingAction`
produces the card's human prompt ("Remove the medication 'Ibuprofen'?").

## Action-result chips (rendering)

`lib/widgets/message_body.dart` renders an assistant message: the plain
prose (the `[action:…]` tags are already stripped by the service before
the widget sees the body) plus an inline **action-result chip** per
citation in `Message.citations`.

The library-card / `[card:<id>]` citation path is **retired** — read the
header comment in `message_body.dart`. The widget now only renders
action-result citations. Today the only chip-bearing citation is
`journal:<entry_id>` (from `log_journal`), which renders a "Journal entry
logged" chip; tapping it deep-links to `/journal/<id>` via the ambient
`GoRouter`. Tests pass an `onCitationTap` override to observe taps
without a real router. An unrecognised citation falls back to a generic
chip showing its raw text, so the message never crashes.

## Chat cannot be disabled

There is **no `AppSettings.chatEnabled` flag** (verify: no match in
`lib/models/settings.dart`). The bottom tab bar is a hard invariant —
**exactly four items, Home · Care · Chat · Community, in that order,
never collapsed or conditionally hidden** (CLAUDE.md → Architectural
invariants). The Chat tab is always mounted; there is no escape hatch to
toggle it off.

## Demo tour acceptance

`integration_test/demo_tour.dart` is a four-tab IA walkthrough
(Home · Care · Chat · Community) against an in-memory `HoldcloseDatabase`
with `DemoChatBackend` pinned via `chatLLMBackendProvider.overrideWithValue`.
It seeds the demo loved one, medications, journal, and two chat threads,
then drives the real UI: read the Home dashboard, walk the Care hub, open
a seeded chat thread and send a message (streamed deterministically by
`DemoChatBackend`), and visit Community. There is **no** library-card
deep-link step — that surface no longer exists.

## Failure modes

| Symptom | Likely cause | Where to look |
|---|---|---|
| Action never writes | Required arg missing/blank, or unknown action name | executor returns null in `chat_actions.dart`; `_executeActions` skips unwired names |
| Raw `[action:…]` tag visible in a bubble | Body not run through `displayBody` / `stripActionMarkers` | `ChatService.displayBody` is the single display chokepoint |
| Destructive action ran without a tap | Regression in the confirm gate | `destructiveActionNames` + `confirmPendingAction`; must stay pending |
| Journal chip nav goes nowhere | `/journal/:id` route deregistered | `lib/routing/router.dart` journal routes; `message_body.dart` deep-link |
| "Couldn't reach the coach" every turn | Prod: quota/capacity/auth (429/503/401); dev: shim down or `claude` CLI not logged in | `ApiChatBackend._errorForStatus`; `python3 tools/claude_shim.py`, `claude --version` |
| Coach says it "can't see" the meds | Current-data snapshot empty or errored | `chat_context_builder.dart` (`gatherChatContext` / `formatChatContext`) |

## Related docs

- [`CLAUDE.md`](../CLAUDE.md) — Direction (the pivot) + Architectural
  invariants (tab bar, medical guardrails, destructive-action gating,
  prompt sanitization).
- [`MENU_LAYOUT_SPEC.md`](MENU_LAYOUT_SPEC.md) — navigation / tab / hub
  structure.
- [`TTS_BUNDLED.md`](TTS_BUNDLED.md) — chat replies share the same TTS
  path when a caregiver wants a reply read aloud.
- [`BUILD_SPEC.md`](../BUILD_SPEC.md) — original contract; note its
  decoder / Natali / dementia sections predate the pivot and are
  superseded by the code.
