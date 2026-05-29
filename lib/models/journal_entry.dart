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
/// [triedDifferent] when they tap "Try a different approach".
enum JournalOutcome {
  pending,
  positive,
  triedDifferent,
}

/// One auto-logged entry in the journal — written every time the
/// decoder runs (BUILD_SPEC.md §5.5 + §7.5). The "journal fills
/// itself" promise from the welcome carousel.
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
    String? notes,
    String? voiceNotePath,
    String? photoPath,
  }) = _JournalEntry;

  factory JournalEntry.fromJson(Map<String, dynamic> json) =>
      _$JournalEntryFromJson(json);
}
