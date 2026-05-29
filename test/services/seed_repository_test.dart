import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/services/seed_repository.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _fixedClock() => DateTime.utc(2026, 5, 29, 19, 0);

void main() {
  group('SeedRepository.populateAll — BUILD_SPEC.md §9 + Task 26', () {
    test('upserts Mary Henderson + inserts the 6 sample journal entries',
        () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final SeedRepository repo = SeedRepository(
        storage: storage,
        clock: _fixedClock,
      );

      await repo.populateAll();

      final Patient? patient = await storage.getPatient();
      expect(patient, isNotNull);
      expect(patient!.id, 'demo-patient-mary');
      expect(patient.name, 'Mary Henderson');

      // The storage watch reads through a 30-day window by default —
      // sample_journal.dart spaces its entries over the trailing ~10 days
      // relative to the injected clock, so all six fall inside.
      final List<JournalEntry> entries = await storage
          .watchJournalEntries(window: const Duration(days: 30))
          .first;
      expect(entries, hasLength(6));
    });

    test('seeded entries include 3 sundowning rows inside the 7-day window — '
        'enough to trip the §7.6 pattern-detector alert', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final SeedRepository repo = SeedRepository(
        storage: storage,
        clock: _fixedClock,
      );

      await repo.populateAll();

      final List<JournalEntry> entries = await storage
          .watchJournalEntries(window: const Duration(days: 30))
          .first;
      final DateTime cutoff = _fixedClock().subtract(const Duration(days: 7));
      final Iterable<JournalEntry> sundowningRecent = entries.where(
        (JournalEntry e) =>
            e.behavior.id == 'sundowning' && e.createdAt.isAfter(cutoff),
      );
      expect(sundowningRecent.length, greaterThanOrEqualTo(3));
    });

    test('is idempotent — running twice leaves the same 6 entries in place',
        () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final SeedRepository repo = SeedRepository(
        storage: storage,
        clock: _fixedClock,
      );

      await repo.populateAll();
      await repo.populateAll();

      final List<JournalEntry> entries = await storage
          .watchJournalEntries(window: const Duration(days: 30))
          .first;
      expect(entries, hasLength(6));
    });
  });
}
