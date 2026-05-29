import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/triage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  JournalEntry sundowningEntry({
    JournalOutcome outcome = JournalOutcome.positive,
    String? notes,
    String? voiceNotePath,
    String? photoPath,
  }) =>
      JournalEntry(
        id: 'entry-001',
        behavior: Behavior.byId('sundowning')!,
        triage: const TriageAnswers(
          when: TriageWhen.lateAfternoonEvening,
          whatChanged: TriageWhatChanged.nothing,
          whatTried: TriageWhatTried.talked,
        ),
        result: DecoderResult(
          say: const <String>[
            "That sounds really hard. I'm right here with you.",
          ],
          tweak: const <String>['Dim overhead lights.'],
          dontSay: const <String>["Don't say 'it's not bedtime yet'."],
          generatedAt: DateTime.utc(2026, 5, 29, 19, 42),
        ),
        outcome: outcome,
        attempt: 1,
        createdAt: DateTime.utc(2026, 5, 29, 19, 42, 30),
        notes: notes,
        voiceNotePath: voiceNotePath,
        photoPath: photoPath,
      );

  group('JournalOutcome', () {
    test('has the 3 BUILD_SPEC.md §7.5 values', () {
      expect(
        JournalOutcome.values,
        containsAll(<JournalOutcome>[
          JournalOutcome.pending,
          JournalOutcome.positive,
          JournalOutcome.triedDifferent,
        ]),
      );
      expect(JournalOutcome.values, hasLength(3));
    });
  });

  group('JournalEntry JSON round-trip', () {
    test('round-trips a minimal positive-outcome entry', () {
      final JournalEntry entry = sundowningEntry();
      expect(
        JournalEntry.fromJson(entry.toJson()),
        equals(entry),
      );
    });

    test('round-trips with notes + voice note + photo attachments', () {
      final JournalEntry entry = sundowningEntry(
        notes: 'Dimming worked instantly.',
        voiceNotePath: 'assets/seed/sample-voice-1.m4a',
        photoPath: 'assets/seed/sample-photo-1.jpg',
      );
      expect(
        JournalEntry.fromJson(entry.toJson()),
        equals(entry),
      );
    });

    test('round-trips a pending-outcome entry (just-logged)', () {
      final JournalEntry entry =
          sundowningEntry(outcome: JournalOutcome.pending);
      expect(
        JournalEntry.fromJson(entry.toJson()).outcome,
        JournalOutcome.pending,
      );
    });

    test('round-trips a tried-different outcome', () {
      final JournalEntry entry =
          sundowningEntry(outcome: JournalOutcome.triedDifferent);
      expect(
        JournalEntry.fromJson(entry.toJson()).outcome,
        JournalOutcome.triedDifferent,
      );
    });
  });
}
