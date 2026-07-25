import 'package:freezed_annotation/freezed_annotation.dart';

part 'journal_entry.freezed.dart';
part 'journal_entry.g.dart';

/// One caregiver-authored entry in the journal (BUILD_SPEC.md §5.5).
///
/// A free-text record of a moment: when it happened ([occurredAt]), what
/// was going on ([situationText]), what the caregiver tried
/// ([attemptsText]), plus optional [notes], a [voiceNotePath], and a
/// [photoPath]. Entries are created from the journal wizard (the home
/// tab's "Log a journal entry" path) AND the chat coach's
/// `[action:log_journal]` harness — both land a row in the same drift
/// table the journal screen reads from, so the entry shows up in the
/// list immediately.
///
/// Older rows persisted under a prior journal format deserialize
/// cleanly: their extra `behavior` / `triage` / `result` keys are simply
/// ignored by `fromJson`, leaving a timestamped entry with no body.
@freezed
abstract class JournalEntry with _$JournalEntry {
  const factory JournalEntry({
    required String id,
    required DateTime createdAt,
    DateTime? occurredAt,
    String? situationText,
    String? attemptsText,
    String? notes,
    String? voiceNotePath,
    String? photoPath,
  }) = _JournalEntry;

  factory JournalEntry.fromJson(Map<String, dynamic> json) =>
      _$JournalEntryFromJson(json);

  /// Build a caregiver-authored journal entry (BUILD_SPEC.md §13 +
  /// chat-harness action). Retained as a named constructor so the
  /// existing call sites — the journal wizard and the chat coach's
  /// `log_journal` action — don't have to change shape.
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
        createdAt: createdAt,
        occurredAt: occurredAt,
        situationText: situationText,
        attemptsText: attemptsText,
        notes: notes,
      );
}
