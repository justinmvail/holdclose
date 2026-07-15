# Swallowed errors: the audit, and the rule

Written 2026-07-15, after a run of bugs that were all the same shape: the app
*had the error in its hands and threw it away*.

- The mic did nothing when tapped — the fake capture returned nothing and the
  handler did `catch (_) { _reset(); }`.
- The coach's voice was gibberish, then silent — the native bridge threw
  `ModelMissing` into a fire-and-forget future.
- Scan-to-import "wasn't working" — the vision model answered in prose, the JSON
  parse threw, and the parser returned `null` silently.
- "Couldn't add the appointment" — the model mangled the date; the executor
  refused; nothing surfaced the why.

Every one of these took far longer to fix than it should have, because the
failure left **no trace**. A tester's report ("scan isn't working") arrived with
a screenshot and no error, and the only way forward was to reproduce it blind.

---

## The one fact that makes this fixable

`main()` tees `debugPrint` into `LogBuffer` (`lib/main.dart` → `_captureLogs`),
and the in-app **"report a problem"** flow attaches `LogBuffer.instance.snapshot()`
to the feedback row. So:

> **Anything you `debugPrint` rides along with the next bug report, automatically.**

That means the cost of making a swallowed failure diagnosable is one line. The
uncaught-async and framework-error handlers are teed too, so an `unawaited`
future that throws is *already* logged globally (`Uncaught: …`) — you only need
to add a breadcrumb where you **catch and swallow** on purpose.

---

## The helper

`logNonFatal(where, error, [stack])` in `lib/services/log_buffer.dart`:

```dart
} catch (e) {
  logNonFatal('scan.prescription', e); // -> "[non-fatal] scan.prescription: <error>"
  draft = null;                         // graceful degradation, unchanged
}
```

The caregiver's experience is identical (they still get the "couldn't read it"
hint); the difference is the report now says *why*. `where` is a short greppable
site tag (`scan.jsonParse`, `search.npi`, `chatContext.medications`,
`sync.applyDoc`). Pass `stack` only when the tag alone won't place it.

---

## The rule

**When you catch an error and don't rethrow, decide out loud whether it's
diagnosable.**

- If a failure here would ever make a caregiver say "it didn't work" — a
  user-initiated action (scan, search, draft, buy, add) — it MUST leave a trace,
  and it SHOULD surface a "try again" to the user (most already do). `catch (_)`
  is banned on these paths.
- If it's genuinely non-fatal, self-correcting, and *frequent* (a cache write, a
  lifecycle callback, a per-open roster refresh), a bare `catch (_)` with a
  one-line comment is fine — a breadcrumb every few seconds is noise, not signal.
- Never `catch (_) {}` on a path whose failure would be a real head-scratcher and
  leave nothing behind. That is the exact bug this doc exists to prevent.

## What the 2026-07-15 audit converted

Traced (silent → breadcrumb), because a failure would be user-visible or a real
malfunction: the scan flows + both JSON-parse fall-throughs; NPI provider search;
insurance-appeal + visit-prep generation; billing buy/restore/verify; the six
`chat_context_builder` section reads + the whole-snapshot collapse (a coach that
silently loses its grounding); four `sync_service` catches (the class that hid
the 2026-07-13 circle wedge); the circle bootstrap/join/invite paths; boot-time
patient preload; export-row serialization.

Left silent, deliberately: additive deep-link wiring, the crash-reporter's own
guard (must never break the thing it reports on), lifecycle callbacks, the
DB-quarantine re-offer, sign-out auxiliary cleanup, local-first cache
refreshes/writes, and the settings-default fallback during export — all
documented, self-correcting, and high-frequency.

Pinned by `test/services/log_buffer_test.dart` (the helper's contract) and
`test/services/appointment_scanner_test.dart` (a malformed-JSON scan leaves a
breadcrumb, not a silent null).
