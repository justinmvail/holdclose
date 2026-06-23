import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/seed/sample_journal.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _fixedClock() => DateTime.utc(2026, 5, 29, 19, 0);

void main() {
  group('sampleJournalEntries — BUILD_SPEC.md §9.2', () {
    test('returns exactly 6 free-text entries', () {
      expect(sampleJournalEntries(clock: _fixedClock), hasLength(6));
    });

    test('every entry carries the seed-journal-N id', () {
      final List<JournalEntry> entries =
          sampleJournalEntries(clock: _fixedClock);
      expect(
        entries.map((JournalEntry e) => e.id).toList(),
        <String>[
          'seed-journal-1',
          'seed-journal-2',
          'seed-journal-3',
          'seed-journal-4',
          'seed-journal-5',
          'seed-journal-6',
        ],
      );
    });

    test('every entry has a situation; most carry the attempts the caregiver '
        'tried', () {
      for (final JournalEntry e in sampleJournalEntries(clock: _fixedClock)) {
        expect(e.situationText, isNotNull,
            reason: 'entry ${e.id} has no situation text');
        expect(e.situationText, isNotEmpty);
        expect(e.attemptsText, isNotNull,
            reason: 'entry ${e.id} has no attempts text');
        expect(e.attemptsText, isNotEmpty);
      }
    });

    test('a cluster of entries lands inside the trailing 7 days', () {
      final List<JournalEntry> entries =
          sampleJournalEntries(clock: _fixedClock);
      final DateTime cutoff = _fixedClock().subtract(const Duration(days: 7));
      final Iterable<JournalEntry> recent = entries.where(
        (JournalEntry e) => e.createdAt.isAfter(cutoff),
      );
      expect(recent.length, greaterThanOrEqualTo(3),
          reason: 'the journal should open populated for the demo');
    });

    test('createdAt timestamps are derived from the injected clock', () {
      final List<JournalEntry> a = sampleJournalEntries(clock: _fixedClock);
      final List<JournalEntry> b = sampleJournalEntries(
        clock: () => _fixedClock().add(const Duration(days: 30)),
      );
      // Same id => later clock yields later createdAt by the same delta.
      final Map<String, DateTime> bById = <String, DateTime>{
        for (final JournalEntry e in b) e.id: e.createdAt,
      };
      for (final JournalEntry e in a) {
        expect(bById[e.id], isNotNull);
        expect(bById[e.id]!.difference(e.createdAt),
            const Duration(days: 30));
      }
    });
  });
}
