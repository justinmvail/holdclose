import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/behavior.dart';
import '../models/decoder_result.dart';
import '../models/journal_entry.dart';
import '../models/patient.dart';
import '../models/triage.dart';
import 'llm_provider.dart';
import 'storage_provider.dart';

part 'decoder_result_provider.g.dart';

/// Tuple of inputs the [decoderResult] family keys off (BUILD_SPEC.md
/// §5.4 + §7.2). Carried through `go_router` extras from the triage
/// screen and again as the family argument so that incrementing
/// [attempt] (via the "Try a different approach" button) spawns a
/// distinct provider instance with its own LLM call + journal entry.
typedef DecoderResultArgs = ({
  Behavior behavior,
  TriageAnswers triage,
  int attempt,
});

/// One snapshot of the in-flight decoder script (BUILD_SPEC.md §5.4 +
/// §7.3). The [decoderResult] family stream emits these as text arrives
/// from the LLM and once more on done.
///
/// While streaming: [partial] is null OR a best-effort parse of the
/// accumulated JSON, [accumulatedJson] is the raw growing buffer, and
/// [done] is false. The screen renders the partial via word-by-word
/// fade-in.
///
/// On done: [partial] holds the fully parsed [DecoderResult], [entryId]
/// is the just-written journal row id, and [done] is true. The screen
/// flips to the full-layout view with the outcome buttons enabled.
@immutable
class DecoderProgress {
  const DecoderProgress({
    required this.partial,
    required this.accumulatedJson,
    required this.entry,
    required this.done,
  });

  /// Best-effort parsed result. Null while the accumulated JSON is still
  /// growing; non-null once the buffer first parses cleanly AND on done.
  final DecoderResult? partial;

  /// Raw JSON the LLM has emitted so far. Survives partial chunks so the
  /// caption fade-in can grow a stable text surface even before the JSON
  /// is structurally complete.
  final String accumulatedJson;

  /// The [JournalEntry] auto-written on first done. Null on every
  /// streaming chunk and on error. Held in full (rather than just an id)
  /// so the screen's "That helped" / "Try a different approach" callbacks
  /// can `copyWith(outcome: ...)` and round-trip through
  /// [StorageProvider.updateJournalEntry] without losing the original
  /// `createdAt` timestamp that the journal grouping depends on.
  final JournalEntry? entry;

  /// True only on the terminal emission.
  final bool done;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DecoderProgress &&
          other.partial == partial &&
          other.accumulatedJson == accumulatedJson &&
          other.entry == entry &&
          other.done == done);

  @override
  int get hashCode =>
      Object.hash(partial, accumulatedJson, entry, done);
}

/// Build-time override hook for the entry-id minter so tests get
/// deterministic ids. Production uses [_defaultEntryIdFactory] which
/// stamps a millisecond timestamp + a 32-bit random suffix — collision
/// chance is irrelevant for a single-user, on-device journal.
typedef EntryIdFactory = String Function();

String _defaultEntryIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'decoder-$ms-$rand';
}

/// Wall clock the auto-log uses to stamp [JournalEntry.createdAt].
/// Overridable so widget tests pin a fixed time.
@Riverpod(keepAlive: true)
DateTime Function() decoderResultClock(Ref ref) => DateTime.now;

/// Entry-id factory the auto-log uses. Overridable so widget tests get
/// stable journal-entry ids to assert against.
@Riverpod(keepAlive: true)
EntryIdFactory decoderResultEntryIdFactory(Ref ref) =>
    _defaultEntryIdFactory;

/// Stream the decoder script for [args] (BUILD_SPEC.md §5.4 + §7.5).
///
/// Subscribes to [LLMProvider.generateDecoderScript] and forwards
/// progress to the result screen as [DecoderProgress] snapshots. On the
/// first [DecoderChunk.done] emission, writes a [JournalEntry] (outcome
/// [JournalOutcome.pending]) to [StorageProvider] so the "journal fills
/// itself" promise (BUILD_SPEC.md §5.5) holds even if the caregiver
/// closes the app before tapping an outcome button.
///
/// `keepAlive: false` so backing off this screen disposes the provider
/// and any in-flight LLM stream — a half-finished call shouldn't hold
/// the LLM channel open if the caregiver bailed mid-stream.
@Riverpod(keepAlive: false)
Stream<DecoderProgress> decoderResult(
  Ref ref,
  DecoderResultArgs args,
) async* {
  final LLMProvider llm = ref.watch(llmProvider);
  final StorageProvider storage = ref.watch(storageProvider);
  final DateTime Function() clock = ref.watch(decoderResultClockProvider);
  final EntryIdFactory mintId =
      ref.watch(decoderResultEntryIdFactoryProvider);

  final Patient? patient = await storage.getPatient();
  final PatientContext patientCtx = patient == null
      ? const PatientContext(stage: 'unspecified', age: 0)
      : PatientContext(stage: patient.diagnosis, age: patient.age);

  bool logged = false;

  await for (final DecoderChunk chunk in llm.generateDecoderScript(
    behavior: args.behavior,
    triage: args.triage,
    patient: patientCtx,
    attempt: args.attempt,
  )) {
    switch (chunk) {
      case DecoderChunkPartial(:final String accumulatedJson):
        yield DecoderProgress(
          partial: _tryParsePartial(accumulatedJson),
          accumulatedJson: accumulatedJson,
          entry: null,
          done: false,
        );

      case DecoderChunkDone(:final DecoderResult result):
        // Auto-log on first done. The journal entry is the persistence
        // anchor for "That helped" / "Tried different approach" → the
        // result screen updates this row's outcome on tap.
        JournalEntry? logEntry;
        if (!logged) {
          logged = true;
          logEntry = JournalEntry(
            id: mintId(),
            behavior: args.behavior,
            triage: args.triage,
            result: result,
            outcome: JournalOutcome.pending,
            attempt: args.attempt,
            createdAt: clock(),
          );
          await storage.insertJournalEntry(logEntry);
        }
        yield DecoderProgress(
          partial: result,
          accumulatedJson: jsonEncode(<String, dynamic>{
            'say': result.say,
            'tweak': result.tweak,
            'dont_say': result.dontSay,
          }),
          entry: logEntry,
          done: true,
        );
        return;

      case DecoderChunkError(:final String message):
        throw DecoderResultException(message);
    }
  }
}

/// Surface for [DecoderChunkError] messages so the [AsyncError] the
/// result screen catches carries a typed payload rather than a bare
/// string. The screen's retry button calls
/// `ref.invalidate(decoderResultProvider(args))` to re-run.
@immutable
class DecoderResultException implements Exception {
  const DecoderResultException(this.message);

  final String message;

  @override
  String toString() => 'DecoderResultException: $message';
}

/// Best-effort parse of an in-flight JSON snapshot (BUILD_SPEC.md §7.3).
///
/// Returns null when the buffer hasn't yet grown into a structurally
/// complete `{say, tweak, dont_say}` object — the caption fade-in
/// renders directly from [DecoderProgress.accumulatedJson] in that case,
/// so a null here just suppresses the "structured" preview, not the
/// streaming text.
DecoderResult? _tryParsePartial(String text) {
  if (text.trim().isEmpty) return null;
  try {
    final dynamic decoded = json.decode(text);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['say'] is! List ||
        decoded['tweak'] is! List ||
        decoded['dont_say'] is! List) {
      return null;
    }
    return DecoderResult(
      say: (decoded['say'] as List<dynamic>)
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      tweak: (decoded['tweak'] as List<dynamic>)
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      dontSay: (decoded['dont_say'] as List<dynamic>)
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      generatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  } on FormatException {
    return null;
  }
}
