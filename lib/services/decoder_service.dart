import 'dart:async';
import 'dart:math' as math;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/behavior.dart';
import '../models/decoder_result.dart';
import '../models/journal_entry.dart';
import '../models/patient.dart';
import '../models/triage.dart';
import '../providers/llm_provider.dart';
import '../providers/storage_provider.dart';

part 'decoder_service.g.dart';

/// Mint a journal-entry id. Overridable so tests get deterministic ids
/// to assert against. Production uses [_defaultEntryIdFactory] which
/// stamps a millisecond timestamp + a 32-bit random suffix.
typedef DecoderEntryIdFactory = String Function();

String _defaultEntryIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'decoder-$ms-$rand';
}

/// Orchestrates one decoder call (BUILD_SPEC.md §5.4 + §7.2 + §7.5).
///
/// Wraps [LLMProvider.generateDecoderScript] with the "journal fills
/// itself" auto-log promise from the welcome carousel: the very first
/// LLM emission writes a [JournalOutcome.pending] [JournalEntry] to
/// [StorageProvider]; the terminal [DecoderChunkDone] updates the entry
/// with the parsed [DecoderResult]; a [DecoderChunkError] flips the
/// outcome to [JournalOutcome.error] so the failed run is still visible
/// in the journal instead of vanishing.
///
/// The result screen reads through [decoderResultProvider]; this service
/// is the single seam screens and provider plumbing share when they
/// need direct, non-riverpod access to the decoder pipeline (e.g.
/// integration tests, future background prefetch).
class DecoderService {
  DecoderService({
    required this.llm,
    required this.storage,
    DecoderEntryIdFactory? entryIdFactory,
    DateTime Function()? clock,
  })  : entryIdFactory = entryIdFactory ?? _defaultEntryIdFactory,
        clock = clock ?? DateTime.now;

  final LLMProvider llm;
  final StorageProvider storage;
  final DecoderEntryIdFactory entryIdFactory;
  final DateTime Function() clock;

  /// Build the §7.2 user-message body. Delegates to
  /// [ClaudeCLIProvider.buildUserMessage] so the canonical shape lives
  /// in one place — the shim and the orchestrator can't drift apart.
  static String buildUserMessage({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) =>
      ClaudeCLIProvider.buildUserMessage(
        behavior: behavior,
        triage: triage,
        patient: patient,
        attempt: attempt,
      );

  /// Stream the decoder script for [behavior] + [triage] + [attempt].
  ///
  /// Forwards every [DecoderChunk] the LLM emits unchanged so callers
  /// (the result screen, tests) see the same shape they'd see talking
  /// to the LLM directly. The side effects — write-pending on first
  /// emission, update-with-result on done, update-outcome-error on
  /// error — happen between yields so a subscriber observing the
  /// stream always sees the storage write that corresponds to the
  /// chunk they just received.
  Stream<DecoderChunk> decode({
    required Behavior behavior,
    required TriageAnswers triage,
    required int attempt,
  }) async* {
    final Patient? patient = await storage.getPatient();
    final PatientContext patientCtx = patient == null
        ? const PatientContext(stage: 'unspecified', age: 0)
        : PatientContext(stage: patient.diagnosis, age: patient.age);

    JournalEntry? entry;

    await for (final DecoderChunk chunk in llm.generateDecoderScript(
      behavior: behavior,
      triage: triage,
      patient: patientCtx,
      attempt: attempt,
    )) {
      // Auto-log on first emission — the journal entry is the
      // persistence anchor for outcome updates downstream.
      if (entry == null) {
        entry = JournalEntry(
          id: entryIdFactory(),
          behavior: behavior,
          triage: triage,
          result: DecoderResult(
            say: const <String>[],
            tweak: const <String>[],
            dontSay: const <String>[],
            generatedAt: clock(),
          ),
          outcome: JournalOutcome.pending,
          attempt: attempt,
          createdAt: clock(),
        );
        await storage.insertJournalEntry(entry);
      }

      switch (chunk) {
        case DecoderChunkPartial():
          yield chunk;

        case DecoderChunkDone(:final DecoderResult result):
          entry = entry.copyWith(result: result);
          await storage.updateJournalEntry(entry);
          yield chunk;
          return;

        case DecoderChunkError():
          entry = entry.copyWith(outcome: JournalOutcome.error);
          await storage.updateJournalEntry(entry);
          yield chunk;
          return;
      }
    }

    // Stream closed without a terminal chunk — treat as an error so
    // the auto-logged entry doesn't sit at `pending` forever.
    if (entry != null) {
      await storage.updateJournalEntry(
        entry.copyWith(outcome: JournalOutcome.error),
      );
      yield const DecoderChunk.error(
        message: 'decoder stream closed without a terminal chunk',
      );
    }
  }
}

/// Riverpod-wired singleton (BUILD_SPEC.md §15). Screens and tests that
/// want the orchestrator read `ref.watch(decoderServiceProvider)` and
/// get one instance shared across the app — the LLM provider and
/// storage backend are themselves singletons, so the wrapper is cheap
/// to keep alive.
@Riverpod(keepAlive: true)
DecoderService decoderService(Ref ref) => DecoderService(
      llm: ref.watch(llmProvider),
      storage: ref.watch(storageProvider),
    );
