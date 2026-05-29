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
/// inserts the six relative-dated journal entries from
/// [sampleJournalEntries] so the pitch demo always boots into a known
/// state — Mary loaded, the journal pre-populated with enough sundowning
/// activity to surface the §7.6 pattern alert.
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

  /// Insert-or-replace every demo seed row. Safe to call against a
  /// store that already holds the seed — the patient row is upserted
  /// by id and the journal entries collide on their stable `seed-*`
  /// ids so a re-run leaves the store in the same shape.
  Future<void> populateAll() async {
    await _storage.upsertPatient(maryHenderson());
    for (final JournalEntry entry in sampleJournalEntries(clock: _clock)) {
      await _storage.insertJournalEntry(entry);
    }
  }
}

/// Riverpod-wired singleton. The reset-on-launch bootstrap and any
/// future "Reload seed data" Settings button (BUILD_SPEC.md §5.10 Demo
/// mode) both read through this provider so the seed flow uses the same
/// [StorageProvider] backend the rest of the app sees.
///
/// Named `seedRepositoryBackend` (not `seedRepository`) so the generated
/// class is [SeedRepositoryBackendProvider], leaving room for the
/// natural-language [seedRepositoryProvider] alias below.
@Riverpod(keepAlive: true)
SeedRepository seedRepositoryBackend(Ref ref) => SeedRepository(
      storage: ref.watch(storageProvider),
    );

/// Alias for consumers — matches the `seedRepositoryProvider` name the
/// bootstrap and any test override reach for.
final SeedRepositoryBackendProvider seedRepositoryProvider =
    seedRepositoryBackendProvider;
