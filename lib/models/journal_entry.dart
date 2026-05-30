import 'package:freezed_annotation/freezed_annotation.dart';

import 'behavior.dart';
import 'decoder_result.dart';
import 'triage.dart';

part 'journal_entry.freezed.dart';
part 'journal_entry.g.dart';

/// Outcome of a single decoder run (BUILD_SPEC.md §5.4 + §7.5).
///
/// Auto-logged as [pending] on result-screen mount, updated to
/// [positive] when the caregiver taps "That helped — log it" or to
/// [triedDifferent] when they tap "Try a different approach". The
/// orchestrator service flips it to [error] when the LLM stream
/// terminates with a [DecoderChunkError] so the failed call is still
/// visible in the journal instead of vanishing.
enum JournalOutcome {
  pending,
  positive,
  triedDifferent,
  error,
}

/// One entry in the journal. Two flavors live behind the same drift
/// row + the same JSON blob:
///
///   * **Decoder entry** (legacy auto-log from the decoder flow,
///     BUILD_SPEC.md §5.5 + §7.5) — `wizardKind == false`. Carries a
///     real [Behavior], [TriageAnswers], and [DecoderResult].
///   * **Wizard entry** (caregiver-authored, the home tab's "Log a
///     journal entry" path AND the chat coach's `[action:log_journal]`
///     harness) — `wizardKind == true`. Carries [occurredAt],
///     [situationText], [attemptsText] in the caregiver's own words.
///     [behavior] is the [wizardSentinelBehavior] placeholder; [triage]
///     and [result] are empty so the persisted JSON stays
///     round-trippable through the same `fromJson`.
///
/// The flag means a single drift table, a single freezed model, a
/// single list query. The journal list screen branches on [wizardKind]
/// when it builds the row label so the wizard entry doesn't try to
/// show "Sundowning · Tried distracting" — it shows the caregiver's
/// situation text directly.
@freezed
abstract class JournalEntry with _$JournalEntry {
  const factory JournalEntry({
    required String id,
    required Behavior behavior,
    required TriageAnswers triage,
    required DecoderResult result,
    required JournalOutcome outcome,
    required int attempt,
    required DateTime createdAt,
    @Default(false) bool wizardKind,
    DateTime? occurredAt,
    String? situationText,
    String? attemptsText,
    String? notes,
    String? voiceNotePath,
    String? photoPath,
  }) = _JournalEntry;

  factory JournalEntry.fromJson(Map<String, dynamic> json) =>
      _$JournalEntryFromJson(json);

  /// Placeholder behavior stamped on wizard-authored entries. Lives
  /// outside [Behavior.canonical] so the behavior-keyed UIs (decoder
  /// behavior picker, fake-LLM seed lookup, behavior chip rendering)
  /// don't mistake it for a real card-mapped behavior.
  static const Behavior wizardSentinelBehavior = Behavior(
    id: 'wizard',
    label: 'A moment',
    glyph: 'note',
  );

  /// Build a caregiver-authored journal entry (BUILD_SPEC.md §13 +
  /// chat-harness action). Stamps the sentinel behavior + empty
  /// triage/result so the row persists through the existing
  /// `toJson`/`fromJson` round-trip; the surface UIs check [wizardKind]
  /// to render the caregiver's own text instead of decoder fields.
  static JournalEntry wizard({
    required String id,
    required DateTime createdAt,
    DateTime? occurredAt,
    String? situationText,
    String? attemptsText,
    String? notes,
  }) =>
      JournalEntry(
        id: id,
        behavior: wizardSentinelBehavior,
        triage: const TriageAnswers(),
        result: DecoderResult(
          say: const <String>[],
          tweak: const <String>[],
          dontSay: const <String>[],
          generatedAt: createdAt,
        ),
        outcome: JournalOutcome.pending,
        attempt: 1,
        createdAt: createdAt,
        wizardKind: true,
        occurredAt: occurredAt,
        situationText: situationText,
        attemptsText: attemptsText,
        notes: notes,
      );
}
