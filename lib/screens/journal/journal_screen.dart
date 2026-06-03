import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/behavior.dart';
import '../../models/journal_entry.dart';
import '../../providers/journal_entries_provider.dart';
import '../../providers/pattern_detector_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';
import 'journal_wizard_screen.dart' show JournalWizardArgs;

/// Journal tab root (BUILD_SPEC.md §5.5).
///
/// Watches [journalEntriesProvider] (last 30 days) + [patternDetectorProvider]
/// and renders one of three states:
///
/// * loading → small spinner anchored to the title (drift's first
///   stream emission is usually one microtask away, so this is rarely
///   visible in production but the AsyncValue requires it),
/// * empty → the §5.5 "Your journal fills itself." promise + a CTA
///   that pushes `/decoder/behavior`,
/// * populated → "This week" summary card, an optional "Heads up"
///   pattern flag card, and the entries grouped Today / Yesterday /
///   Earlier with the newest first.
///
/// The screen is intentionally a tab root — `automaticallyImplyLeading:
/// false` keeps a stray back arrow from appearing if the tab shell ever
/// ends up nested under another navigator.
class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key});

  /// Widget key for the empty-state CTA so tests tap by intent rather
  /// than by copy.
  static const Key emptyCtaKey = Key('journal-empty-cta');

  /// FAB that opens the entry-method chooser (Quick note / Wizard).
  static const Key addEntryFabKey = Key('journal-add-entry-fab');

  /// Rows in the chooser sheet — quick free-text entry vs. the guided
  /// coaching wizard. Test taps target these keys instead of copy.
  static const Key quickNoteOptionKey = Key('journal-add-option-quick-note');
  static const Key wizardOptionKey = Key('journal-add-option-wizard');

  /// Widget key for the "This week" summary card.
  static const Key weekSummaryKey = Key('journal-week-summary');

  /// Widget key for the pattern-alert "Heads up" card. Only present
  /// when [patternDetectorProvider] returns a non-empty list.
  static const Key patternAlertKey = Key('journal-pattern-alert');

  /// Widget key for the chronological list view holding the grouped
  /// entries.
  static const Key entriesListKey = Key('journal-entries-list');

  /// Stable per-entry key derived from the entry id — tests + the
  /// integration tour tap by id, not by visible time.
  static Key entryTileKey(String id) => Key('journal-entry-tile-$id');

  /// Stable per-group key so tests assert section ordering without
  /// scraping the visible string twice.
  static Key groupHeaderKey(String label) =>
      Key('journal-group-header-${label.toLowerCase()}');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<JournalEntry>> entriesAsync =
        ref.watch(journalEntriesProvider);
    final List<PatternAlert> alerts = ref.watch(patternDetectorProvider);
    final DateTime now = ref.watch(journalScreenClockProvider)();

    return Scaffold(
      backgroundColor: careblazersColors.background,
      floatingActionButton: FloatingActionButton.extended(
        key: addEntryFabKey,
        backgroundColor: careblazersColors.cta,
        foregroundColor: Colors.white,
        onPressed: () => showJournalAddSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('Add entry'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Medical', route: '/medical'),
                  PathHeaderCrumb(label: 'Journal'),
                ],
                title: 'Journal',
                backLabel: 'Back to Medical',
                leadingIcon: Icons.book_outlined,
              ),
            ),
            Expanded(
              child: entriesAsync.when(
                // Storage's first emission lands within a microtask of mount,
                // so the loading state is essentially invisible to a real
                // caregiver. Render a static placeholder rather than a
                // CircularProgressIndicator — its infinite animation would
                // wedge `pumpAndSettle` in widget tests that don't override
                // storage (e.g. the route-registration probes).
                loading: () => const SizedBox.shrink(),
                error: (Object error, StackTrace _) =>
                    _ErrorView(message: '$error'),
                data: (List<JournalEntry> entries) {
                  if (entries.isEmpty) {
                    return const _EmptyState();
                  }
                  return _PopulatedView(
                    entries: entries,
                    alerts: alerts,
                    now: now,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet the Journal FAB opens — surfaces both entry paths
/// (free-text quick note + the guided wizard) so the caregiver picks
/// the cognitive load they have in the moment.
void showJournalAddSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: careblazersColors.background,
    showDragHandle: true,
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: JournalScreen.quickNoteOptionKey,
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Quick note'),
              subtitle: const Text('Just write what happened.'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push(
                  '/journal/new',
                  extra: const JournalWizardArgs(quickNote: true),
                );
              },
            ),
            ListTile(
              key: JournalScreen.wizardOptionKey,
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Coaching wizard'),
              subtitle: const Text('Guided steps with Dr. Natali\'s script.'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push('/journal/new');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Empty state (§5.5)
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.eco_outlined,
            size: 64,
            color: careblazersColors.success,
          ),
          const SizedBox(height: 16),
          Text(
            'Your journal fills itself.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Each time you use the decoder, the moment gets logged here '
            'automatically. Try it once and come back.',
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.text,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'Open the decoder. Start logging your first moment.',
            child: ElevatedButton(
              key: JournalScreen.emptyCtaKey,
              style: ElevatedButton.styleFrom(
                backgroundColor: careblazersColors.cta,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: () => context.push('/decoder/behavior'),
              child: Text(
                'Open the decoder',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Populated view: summary + alerts + grouped list
// ---------------------------------------------------------------------------

class _PopulatedView extends StatelessWidget {
  const _PopulatedView({
    required this.entries,
    required this.alerts,
    required this.now,
  });

  final List<JournalEntry> entries;
  final List<PatternAlert> alerts;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final _GroupedEntries grouped = _GroupedEntries.from(entries, now);
    final _WeekStats stats = _WeekStats.from(entries, now);

    return ListView(
      key: JournalScreen.entriesListKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        _WeekSummaryCard(stats: stats),
        if (alerts.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _PatternAlertCard(alerts: alerts),
        ],
        const SizedBox(height: 20),
        for (final _GroupedSection section in grouped.sections) ...<Widget>[
          _GroupHeader(label: section.label),
          const SizedBox(height: 8),
          for (final JournalEntry entry in section.entries)
            _EntryTile(entry: entry, now: now),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Week summary card (§5.5)
// ---------------------------------------------------------------------------

class _WeekSummaryCard extends StatelessWidget {
  const _WeekSummaryCard({required this.stats});

  final _WeekStats stats;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: JournalScreen.weekSummaryKey,
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'This week',
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '📊  ${stats.thisWeek} incidents logged',
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            stats.trendSubline,
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.primarySoft,
            ),
          ),
          if (stats.topBehaviors.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'Most common:',
              style: textTheme.bodyMedium?.copyWith(
                color: careblazersColors.primarySoft,
              ),
            ),
            const SizedBox(height: 4),
            for (final _BehaviorCount bc in stats.topBehaviors)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${bc.glyph}  ${bc.label} · ${bc.count}',
                  style: textTheme.bodyLarge?.copyWith(
                    color: careblazersColors.text,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pattern alert card (§5.5)
// ---------------------------------------------------------------------------

class _PatternAlertCard extends StatelessWidget {
  const _PatternAlertCard({required this.alerts});

  final List<PatternAlert> alerts;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: JournalScreen.patternAlertKey,
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: careblazersColors.accentDeep.withValues(alpha: 0.6),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '⚠  Heads up',
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.accentDeep,
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < alerts.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
              child: Text(
                alerts[i].text,
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grouped list (§5.5)
// ---------------------------------------------------------------------------

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: JournalScreen.groupHeaderKey(label),
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        label,
        style: textTheme.titleLarge?.copyWith(
          color: careblazersColors.primarySoft,
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.now});

  final JournalEntry entry;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String time = _formatClock(entry.createdAt);
    final String? whatWorked = _whatWorkedSub(entry);

    return Semantics(
      button: true,
      label:
          '${entry.behavior.label} at $time. Double-tap to open this entry.',
      child: Material(
        color: careblazersColors.background,
        child: InkWell(
          key: JournalScreen.entryTileKey(entry.id),
          onTap: () => context.push('/journal/${entry.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.behavior.glyph,
                  style: const TextStyle(fontSize: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '$time   ${entry.behavior.label}',
                        style: textTheme.bodyLarge?.copyWith(
                          color: careblazersColors.primary,
                        ),
                      ),
                      if (whatWorked != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          whatWorked,
                          style: textTheme.bodyMedium?.copyWith(
                            color: careblazersColors.primarySoft,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: careblazersColors.primarySoft,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error fallback
// ---------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          "We couldn't load the journal.\n$message",
          style: textTheme.bodyLarge?.copyWith(
            color: careblazersColors.text,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pretty-prints [t] as "7:42 PM" — 12-hour clock with no leading zero
/// on the hour to keep the entry tile's leading column narrow.
String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}

/// "What worked" sub-line for an entry tile (BUILD_SPEC.md §5.5).
///
/// Returns null when there is nothing useful to show — the tile then
/// renders without a second row instead of an empty-looking gap.
String? _whatWorkedSub(JournalEntry entry) {
  switch (entry.outcome) {
    case JournalOutcome.positive:
      if (entry.result.tweak.isNotEmpty) {
        return 'What worked: ${entry.result.tweak.first}';
      }
      if (entry.result.say.isNotEmpty) {
        return 'What worked: ${entry.result.say.first}';
      }
      return 'That helped.';
    case JournalOutcome.triedDifferent:
      return 'Tried a different approach.';
    case JournalOutcome.error:
      return "Couldn't reach the coach.";
    case JournalOutcome.pending:
      return null;
  }
}

@immutable
class _BehaviorCount {
  const _BehaviorCount({
    required this.id,
    required this.label,
    required this.glyph,
    required this.count,
  });

  final String id;
  final String label;
  final String glyph;
  final int count;
}

@immutable
class _WeekStats {
  const _WeekStats({
    required this.thisWeek,
    required this.lastWeek,
    required this.topBehaviors,
  });

  final int thisWeek;
  final int lastWeek;
  final List<_BehaviorCount> topBehaviors;

  /// Bucket [entries] (already 30-day windowed) into the two 7-day
  /// windows the summary card compares, and rank the top-3 behaviors
  /// over the current window.
  factory _WeekStats.from(List<JournalEntry> entries, DateTime now) {
    final DateTime thisWeekCutoff = now.subtract(const Duration(days: 7));
    final DateTime lastWeekCutoff = now.subtract(const Duration(days: 14));

    int thisWeek = 0;
    int lastWeek = 0;
    final Map<String, int> counts = <String, int>{};
    final Map<String, Behavior> behaviors = <String, Behavior>{};

    for (final JournalEntry e in entries) {
      if (e.createdAt.isAfter(thisWeekCutoff)) {
        thisWeek += 1;
        counts[e.behavior.id] = (counts[e.behavior.id] ?? 0) + 1;
        behaviors[e.behavior.id] = e.behavior;
      } else if (e.createdAt.isAfter(lastWeekCutoff)) {
        lastWeek += 1;
      }
    }

    final List<MapEntry<String, int>> ranked = counts.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value));
    final List<_BehaviorCount> top = <_BehaviorCount>[
      for (final MapEntry<String, int> r in ranked.take(3))
        _BehaviorCount(
          id: r.key,
          label: behaviors[r.key]!.label,
          glyph: behaviors[r.key]!.glyph,
          count: r.value,
        ),
    ];

    return _WeekStats(
      thisWeek: thisWeek,
      lastWeek: lastWeek,
      topBehaviors: top,
    );
  }

  /// Subline comparing this week to last week (BUILD_SPEC.md §5.5).
  String get trendSubline {
    if (lastWeek == 0 && thisWeek == 0) {
      return 'Nothing logged in the last two weeks.';
    }
    if (lastWeek == 0) {
      return 'Last week: 0 — first week tracking.';
    }
    final String trend;
    if (thisWeek < lastWeek) {
      trend = 'improving';
    } else if (thisWeek == lastWeek) {
      trend = 'about the same';
    } else {
      trend = 'increasing';
    }
    return 'Last week: $lastWeek — $trend.';
  }
}

@immutable
class _GroupedSection {
  const _GroupedSection({required this.label, required this.entries});

  final String label;
  final List<JournalEntry> entries;
}

@immutable
class _GroupedEntries {
  const _GroupedEntries({required this.sections});

  final List<_GroupedSection> sections;

  /// Bucket [entries] into Today / Yesterday / Earlier relative to
  /// [now]. Order within each bucket follows [entries] (newest first,
  /// matching the storage layer's contract). Empty buckets are dropped
  /// so the list never renders a bare header.
  factory _GroupedEntries.from(List<JournalEntry> entries, DateTime now) {
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime yesterday = today.subtract(const Duration(days: 1));

    final List<JournalEntry> todays = <JournalEntry>[];
    final List<JournalEntry> yesterdays = <JournalEntry>[];
    final List<JournalEntry> earlier = <JournalEntry>[];

    for (final JournalEntry e in entries) {
      final DateTime day =
          DateTime(e.createdAt.year, e.createdAt.month, e.createdAt.day);
      if (!day.isBefore(today)) {
        todays.add(e);
      } else if (!day.isBefore(yesterday)) {
        yesterdays.add(e);
      } else {
        earlier.add(e);
      }
    }

    return _GroupedEntries(
      sections: <_GroupedSection>[
        if (todays.isNotEmpty)
          _GroupedSection(label: 'Today', entries: todays),
        if (yesterdays.isNotEmpty)
          _GroupedSection(label: 'Yesterday', entries: yesterdays),
        if (earlier.isNotEmpty)
          _GroupedSection(label: 'Earlier', entries: earlier),
      ],
    );
  }
}
