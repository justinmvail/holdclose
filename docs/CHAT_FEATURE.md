# Chat coach

> **Updated for the pivot (2026-06-22).** The chat coach is now the
> product's **primary (and only) coaching surface** — the Behavior
> Decoder it was originally built alongside is being **removed**, and the
> Dr. Natali / Dementia Careblazers framing is being **stripped**.
> Throughout this doc: ignore "decoder" cross-references (obsolete), read
> "Careblazer" as "caregiver," and read the "Dr. Natali" voice/citation
> labels as **brand-neutral** (e.g. "a coaching note on \<topic\>", not
> "Dr. Natali on \<topic\>"). The app is **general-purpose caregiving**,
> not dementia-only. The file locations and parsing mechanics below are
> still accurate. See [`CLAUDE.md`](../CLAUDE.md) → **Direction**.

The chat coach is a multi-turn caregiving companion, grounded in the
loved one's real care data — meds, dose windows, appointments, history,
journal, the care circle — via `chat_context_builder`. It's the
conversation a caregiver doesn't otherwise get at 11pm: a coach that
already knows *their* situation, so they never have to re-explain it the
way they would to a blank chatbot. **That data-grounding is the wedge** —
it's what makes this more than "just use the AI."

## Where things live

| Concern | File |
|---|---|
| Conversation + Message models | `lib/models/chat.dart` |
| Drift tables + migration | `lib/db/tables.dart`, `lib/db/database.dart` |
| Persistence | `lib/services/chat_repository.dart` |
| Streaming orchestrator | `lib/services/chat_service.dart` |
| System prompt (verbatim) | `lib/seed/chat_system_prompt.dart` |
| Citation chip renderer | `lib/widgets/message_body.dart` |
| Screens (Phase 11.4) | `lib/screens/chat/` |

The chat backend is wired through the **same `tools/claude_shim.py`
bridge** the decoder uses (BUILD_SPEC.md §8). No new transport, no
new keys — `ClaudeShimChatBackend` POSTs `{system, user}` to
`http://localhost:8765/generate` and folds the SSE response into
`ChatDeltaText` events. The shim shells out to your local `claude`
CLI subscription, so chat is zero-per-call cost in dev mode.

## System-prompt customization

The chat system prompt lives in `lib/seed/chat_system_prompt.dart` as
a single `const String chatSystemPrompt`. It is the **only** source of
voice for the chat coach — `ChatService` passes it through to every
backend invocation as the `system` field.

It is structurally similar to the decoder's `claudeSystemPrompt` (six
core principles, the 5 Causes framework, the family vocabulary, the
"never claim to be Dr. Natali" identity line), but two things differ:

1. **Multi-turn framing.** "You are talking with a Careblazer in an
   ongoing chat thread — multi-turn dialogue, not a one-shot script."
   The decoder prompt asks for a JSON object; the chat prompt asks for
   prose paragraphs.

2. **Crisis referral.** Because the chat surface is open-ended — the
   caregiver can ask anything — the prompt names the situations where
   the chat coach should explicitly defer to professional help: sudden
   severe confusion, chest pain, signs of stroke, a fall with injury,
   talk of self-harm. "Warmth includes naming when something is beyond
   the scope of chat." For ongoing medical questions (medications,
   dosing, diagnoses, prognosis), the prompt directs the model to refer
   the caregiver to their loved one's doctor or a geriatric care
   manager. This pairs with the existing footer reminder on every
   decoder result (BUILD_SPEC.md §13.1).

### How to edit the prompt

The const is **verbatim**: every character matters for output
consistency, the same as the decoder prompt (BUILD_SPEC.md §7.1).
When changing it:

- Update the const in `lib/seed/chat_system_prompt.dart`.
- Run the chat service tests — `test/services/chat_service_test.dart`
  pins the system-prompt forwarding shape; voice changes that drift
  the structure may need golden refreshes downstream.
- Keep the **CITATIONS** section honest: it enumerates the 12 library
  card IDs the model is allowed to cite, one per line as
  `<id> — <topic>`. The renderer falls back gracefully on a stale id,
  but a hallucinated id means a missing chip the caregiver wanted.

### Forbidden ground

The prompt's `FORBIDDEN:` block is non-negotiable and mirrors the
decoder:

- No medication, dosage, or medication-change recommendations.
- No diagnoses or prognosis claims ("your loved one has X").
- No contradiction of the caregiver's reading of the situation.
- No "AI" / "model" / "Claude" / "ChatGPT" framing — per
  CLAUDE.md and BUILD_SPEC.md §1, the LLM is invisible.
- No exclamation marks. The audience is tired.

These overlap deliberately with the decoder's forbidden list so
caregivers get the same posture across surfaces.

## Citation syntax

When the assistant's reply ties into one of Dr. Natali's library
cards, the model ends the relevant sentence with a marker:

```
Sundowning is the late-afternoon shift many Careblazers notice in
their loved ones. [card:sundowning_basics]
```

The marker is `[card:<id>]`. The id charset is `[a-zA-Z0-9_-]+` so
future slugs (kebab-case, mixed case) parse without a regex update.

### Parsing

`ChatService.parseCitations(body)` runs the regex over the finished
assistant body once `streamingDone` flips true. Output is a
deduplicated, first-seen-order `List<String>` that lands on the
`Message.citations` field and persists with the row. The same regex
lives in `MessageBody._citationMarker` (the chip renderer) — two
copies on purpose: the service owns the persisted citations list (for
queries / future analytics), the widget owns the inline render.

### Rendering

`lib/widgets/message_body.dart` walks the body once and emits an
`InlineSpan` per chunk:

- Plain prose between markers becomes a `TextSpan`.
- Each `[card:<id>]` marker becomes a `WidgetSpan` holding a salmon
  `_CitationChip` reading "**Dr. Natali on \<card title\>**" at 14pt
  white-on-CTA. The chip's height stays close to the surrounding cap
  height so the sentence flows continuously.
- Tap → `GoRouter.of(context).push('/library/<id>')` — the existing
  library-detail route from BUILD_SPEC.md §5.8. Widget tests pass an
  `onCitationTap` override so taps can be observed without spinning up
  a full router.
- An unknown id (model went off-script despite the closed-set prompt)
  falls back to the raw marker text — the message stays intact and the
  dev sees the failure rather than a crashed bubble.

### Where titles come from

The chip resolves `<id>` → `LibraryCard.title` via `libraryCardById`
in `lib/seed/library_cards.dart`. Card title edits propagate to the
chip label automatically; no chip-side string lives in the model
output.

## Disable from settings

The chat coach can be hidden entirely via an **`AppSettings.chatEnabled`**
flag (default `true`). When `false`:

- The Chat tab disappears from the bottom tab bar.
- The `/chat` and `/chat/:id` routes are unreachable from app UI.
- The persisted conversations + messages remain in drift — flipping
  the toggle back on resurfaces them — so the toggle is reversible
  without data loss.

This is the **escape hatch** for two scenarios:

1. **Pitch demo polish.** Phase 11.4's chat tab can be hidden during a
   pitch tour if the operator wants the conversation to focus on the
   decoder wedge without a fifth tab visible. Settings → flip
   `chatEnabled` off → cold-restart → 4-tab bar.

2. **Caregivers who prefer the decoder wedge.** Some users want the
   single-shot "what do I do RIGHT NOW?" coach and nothing else.
   Hiding chat avoids competing for the same eyeball without
   uninstalling.

The flag is persisted via `StorageProvider.updateSettings` like every
other `AppSettings` field. The chat **services** (`ChatService`,
`ChatRepository`) stay alive regardless of the flag — only the UI
gates on it.

## Demo tour acceptance

`integration_test/demo_tour.dart` carries a second `testWidgets`
block that exercises the chat citation deep-link end-to-end without
depending on the Phase 11.4 chat-tab UI:

1. Construct an in-memory `CareblazersDatabase` + `ChatRepository`.
2. Wire a scripted `ChatLLMBackend` that yields a sundowning answer
   ending in `[card:sundowning_basics]`.
3. Call `ChatService.sendMessage(userText: "what's sundowning?")` and
   collect the streamed `Message`s.
4. Assert the final assistant message has `streamingDone: true` and
   `citations` containing `sundowning_basics`.
5. Pump `MessageBody(body: assistant.body)` inside a minimal
   `GoRouter` wired with the real `LibraryCardScreen` at `/library/:id`.
6. Tap the citation chip → assert `LibraryCardScreen` is on screen.

The walkthrough validates the user-facing chain that matters:
**ask question → see chip → tap → land on library**. Once Phase 11.4
ships the chat tab + screens, the first three steps will be replaced
by `tester.tap(chatTab) → tester.enterText(...) → tester.tap(send)`.

## Failure modes

| Symptom | Likely cause | Where to look |
|---|---|---|
| Citation chips don't render | Model omitted markers, or marker syntax drifted | `chat_system_prompt.dart` CITATIONS block + `_citationMarker` regex |
| Chip resolves to raw `[card:xyz]` text | `xyz` isn't in `libraryCards` | `libraryCardById` returns null → MessageBody fallback |
| Stream stalls at "typing…" | Shim down, or `claude` CLI not logged in | `python3 tools/claude_shim.py` in foreground, check `claude --version` |
| Chip nav goes nowhere | `/library/:id` route deregistered | `lib/routing/router.dart` `libraryCard` route |
| Chat tab visible in demo despite disable | `chatEnabled` flag not honoured by tab scaffold | Phase 11.4 wiring in `lib/widgets/tab_scaffold.dart` |

## Related docs

- [`BUILD_SPEC.md`](../BUILD_SPEC.md) §6 (provider interfaces),
  §7 (decoder system prompt — companion to the chat prompt),
  §8 (the shim contract).
- [`TASKS.md`](../TASKS.md) Phase 11 (the queue this work
  belongs to).
- [`TTS_BUNDLED.md`](TTS_BUNDLED.md) — separate concern; chat replies
  share the same TTS path as decoder scripts when the caregiver wants
  to hear a reply read aloud.
