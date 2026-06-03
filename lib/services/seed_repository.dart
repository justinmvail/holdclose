import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/journal_entry.dart';
import '../providers/storage_provider.dart';
import '../seed/mary_henderson.dart';
import '../seed/sample_journal.dart';

part 'seed_repository.g.dart';

/// Loads the demo seed data into a freshly-reset [StorageProvider]
/// (BUILD_SPEC.md §9 + Task 26).
///
/// `populateAll()` upserts the [maryHenderson] crisis-card profile and
/// inserts the relative-dated journal entries from
/// [sampleJournalEntries]. Dose windows are no longer seeded — the
/// caregiver creates their own via the windows manager (Medications →
/// clock icon).
///
/// The reset-on-launch bootstrap in `lib/main.dart` calls
/// `storage.reset()` before invoking [populateAll]; this class does NOT
/// reset on its own, so callers can re-seed an in-memory store from a
/// test or rerun the seed mid-demo without nuking anything else first.
class SeedRepository {
  SeedRepository({
    required StorageProvider storage,
    DateTime Function()? clock,
  })  : _storage = storage,
        _clock = clock ?? DateTime.now;

  final StorageProvider _storage;
  final DateTime Function() _clock;

  Future<void> populateAll() async {
    await _storage.upsertPatient(maryHenderson());
    for (final JournalEntry entry in sampleJournalEntries(clock: _clock)) {
      await _storage.insertJournalEntry(entry);
    }
  }
}

/// Riverpod-wired singleton.
@Riverpod(keepAlive: true)
SeedRepository seedRepositoryBackend(Ref ref) => SeedRepository(
      storage: ref.watch(storageProvider),
    );

/// Alias for consumers.
final SeedRepositoryBackendProvider seedRepositoryProvider =
    seedRepositoryBackendProvider;
