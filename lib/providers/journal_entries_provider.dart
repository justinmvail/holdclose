import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/journal_entry.dart';
import 'storage_provider.dart';

part 'journal_entries_provider.g.dart';

/// Rolling window the journal screen surfaces (BUILD_SPEC.md §5.5).
///
/// 30 days matches the "Doctor visit prep" affordance on Home — the
/// week summary card slices the same stream a second time to compute
/// the 7-day "this week" count.
const Duration journalWindow = Duration(days: 30);

/// Streams the caregiver's journal entries within [journalWindow], newest
/// first (BUILD_SPEC.md §5.5).
///
/// Watches [storageProvider] so a journal write (from the wizard or the
/// chat coach's `log_journal` action) flows through the journal screen
/// without an explicit invalidate. `keepAlive: false` — when the
/// journal tab is off-screen, the underlying drift watch can rest.
@Riverpod(keepAlive: false)
Stream<List<JournalEntry>> journalEntries(Ref ref) {
  final StorageProvider storage = ref.watch(storageProvider);
  return storage.watchJournalEntries(window: journalWindow);
}

/// Wall clock the journal screen uses to derive "Today / Yesterday /
/// Earlier" buckets (BUILD_SPEC.md §5.5). Overridable so widget tests
/// pin a fixed time and the grouping stays deterministic regardless of
/// the test host's local time.
@Riverpod(keepAlive: true)
DateTime Function() journalScreenClock(Ref ref) => DateTime.now;

/// One row from the journal stream, filtered by id (BUILD_SPEC.md §5.6).
///
/// Resolves to null when the id isn't found — covers two cases the
/// entry detail screen handles the same way: a deep-link to a deleted
/// entry, and the moment after the user taps "Delete" but before
/// `context.pop` fires. The screen reads through this rather than
/// [journalEntriesProvider] directly so a save from the detail editor
/// propagates back through the shared drift watch — no manual
/// invalidation needed.
@Riverpod(keepAlive: false)
AsyncValue<JournalEntry?> journalEntryById(Ref ref, String id) {
  final AsyncValue<List<JournalEntry>> async =
      ref.watch(journalEntriesProvider);
  return async.whenData((List<JournalEntry> entries) {
    for (final JournalEntry e in entries) {
      if (e.id == id) return e;
    }
    return null;
  });
}
