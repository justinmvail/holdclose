import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/seed/sample_journal.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _fixedClock() => DateTime.utc(2026, 5, 29, 19, 0);

void main() {
  group('sampleJournalEntries — BUILD_SPEC.md §9.2', () {
    test('returns exactly 6 entries', () {
      expect(sampleJournalEntries(clock: _fixedClock), hasLength(6));
    });

    test('demonstrates the §7.6 sundowning pattern: 3 entries inside 7 days',
        () {
      final List<JournalEntry> entries =
          sampleJournalEntries(clock: _fixedClock);
      final DateTime cutoff = _fixedClock().subtract(const Duration(days: 7));
      final Iterable<JournalEntry> sundowning7d = entries.where(
        (JournalEntry e) =>
            e.behavior.id == 'sundowning' && e.createdAt.isAfter(cutoff),
      );
      expect(sundowning7d.length, 3);
    });

    test('every entry references a canonical behavior id', () {
      const Set<String> canonical = <String>{
        'upset',
        'refusing_care',
        'wants_home',
        'asking_for_someone',
        'accusing',
        'sundowning',
        'wandering',
        'hallucinating',
      };
      for (final JournalEntry e in sampleJournalEntries(clock: _fixedClock)) {
        expect(canonical, contains(e.behavior.id),
            reason: 'entry ${e.id} has unknown behavior ${e.behavior.id}');
      }
    });

    test('every entry carries a non-empty DecoderResult', () {
      for (final JournalEntry e in sampleJournalEntries(clock: _fixedClock)) {
        expect(e.result.say, isNotEmpty);
        expect(e.result.tweak, isNotEmpty);
        expect(e.result.dontSay, isNotEmpty);
      }
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
