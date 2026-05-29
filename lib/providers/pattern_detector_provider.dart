import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/journal_entry.dart';
import '../services/pattern_detector.dart';
import 'journal_entries_provider.dart';

// Re-export the alert types so existing consumers (the journal screen
// and its tests) keep their `pattern_detector_provider.dart` import.
// The detector logic and the data types it returns now live alongside
// each other in `services/pattern_detector.dart`.
export '../services/pattern_detector.dart'
    show PatternAlert, PatternSeverity;

part 'pattern_detector_provider.g.dart';

/// Pattern-detector hook for the journal screen (BUILD_SPEC.md §5.5 +
/// §7.6).
///
/// Watches the journal-entries stream and runs every rule on each
/// emission. While the underlying stream is still loading the provider
/// surfaces an empty list — the screen renders the entries section's
/// loading placeholder in that window, so no alert UI is missed.
///
/// The clock is read through [journalScreenClockProvider] so widget
/// tests that pin "now" for grouping see the same anchor for alert
/// windows — keeps fixtures deterministic without having to override
/// two providers.
@Riverpod(keepAlive: false)
List<PatternAlert> patternDetector(Ref ref) {
  final List<JournalEntry> entries =
      ref.watch(journalEntriesProvider).value ?? const <JournalEntry>[];
  final DateTime now = ref.watch(journalScreenClockProvider)();
  return const PatternDetector().detect(entries, now: now);
}
