import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/journal_entry.dart';
import '../../providers/journal_entries_provider.dart';
import '../../providers/pattern_detector_provider.dart';
import '../../theme.dart';
import '../../widgets/form/form_error_view.dart';
import '../../widgets/form/format.dart';
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
///   that opens the add-entry sheet,
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
      backgroundColor: context.hc.background,
      floatingActionButton: FloatingActionButton.extended(
        key: addEntryFabKey,
        // Each shell branch keeps its FAB mounted (IndexedStack), and a
        // route pushed over the shell animates its Hero subtree against the
        // active branch's — default-tagged FABs across branches/routes
        // collide ("multiple heroes share the same tag"). A per-screen tag
        // keeps every FAB's Hero unique.
        heroTag: 'journal-add-fab',
        backgroundColor: context.hc.ctaFilled,
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
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Journal'),
                ],
                title: 'Journal',
                backLabel: 'Back to Care',
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
                error: (Object error, StackTrace _) => FormErrorView(
                    message: "We couldn't load the journal.\n$error"),
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
    backgroundColor: context.hc.background,
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
              title: const Text('Guided entry'),
              subtitle: const Text('Step through when, what happened, and '
                  'what you tried.'),
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
            color: context.hc.success,
          ),
          const SizedBox(height: 16),
          Text(
            'Your journal, in your words.',
            style: textTheme.headlineMedium?.copyWith(
              color: context.hc.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Jot down the moments that matter — what happened, what you '
            'tried, what helped. Add your first one whenever you’re ready.',
            style: textTheme.bodyLarge?.copyWith(
              color: context.hc.text,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'Add your first journal entry.',
            child: ElevatedButton(
              key: JournalScreen.emptyCtaKey,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.hc.ctaFilled,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: () => showJournalAddSheet(context),
              child: Text(
                'Add your first entry',
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

    // Flatten the summary card + grouped sections into one item list
    // (same shape as the calendar's _GroupedAgenda) so the unbounded
    // entry history builds lazily instead of all at once.
    final List<_JournalListItem> items = <_JournalListItem>[
      const _SummaryItem(),
      if (alerts.isNotEmpty) ...<_JournalListItem>[
        const _GapItem(12),
        const _AlertsItem(),
      ],
      const _GapItem(20),
      for (final _GroupedSection section in grouped.sections)
        ...<_JournalListItem>[
          _HeaderItem(section.label),
          const _GapItem(8),
          for (final JournalEntry entry in section.entries) _EntryItem(entry),
          const _GapItem(16),
        ],
    ];

    return ListView.builder(
      key: JournalScreen.entriesListKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int i) {
        switch (items[i]) {
          case _SummaryItem():
            return _WeekSummaryCard(stats: stats);
          case _AlertsItem():
            return _PatternAlertCard(alerts: alerts);
          case _GapItem(height: final double height):
            return SizedBox(height: height);
          case _HeaderItem(label: final String label):
            return _GroupHeader(label: label);
          case _EntryItem(entry: final JournalEntry entry):
            return _EntryTile(entry: entry, now: now);
        }
      },
    );
  }
}

/// One row in the flattened journal list — the summary card, the alerts
/// card, a fixed-height gap, a group header, or an entry tile. Mirrors
/// the calendar's `_UpcomingItem` flatten so the ListView can build
/// rows lazily without changing the rendered order or spacing.
sealed class _JournalListItem {
  const _JournalListItem();
}

class _SummaryItem extends _JournalListItem {
  const _SummaryItem();
}

class _AlertsItem extends _JournalListItem {
  const _AlertsItem();
}

class _GapItem extends _JournalListItem {
  const _GapItem(this.height);
  final double height;
}

class _HeaderItem extends _JournalListItem {
  const _HeaderItem(this.label);
  final String label;
}

class _EntryItem extends _JournalListItem {
  const _EntryItem(this.entry);
  final JournalEntry entry;
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
        color: context.hc.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'This week',
            style: textTheme.titleLarge?.copyWith(
              color: context.hc.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '📊  ${stats.thisWeek} entries logged',
            style: textTheme.bodyLarge?.copyWith(
              color: context.hc.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            stats.trendSubline,
            style: textTheme.bodyMedium?.copyWith(
              color: context.hc.primarySoft,
            ),
          ),
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
        color: context.hc.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: context.hc.accentDeep.withValues(alpha: 0.6),
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
              color: context.hc.accentDeep,
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < alerts.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
              child: Text(
                alerts[i].text,
                style: textTheme.bodyLarge?.copyWith(
                  color: context.hc.text,
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
          color: context.hc.primarySoft,
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
    final String time = formatClock12h(entry.createdAt);
    final String title = _entryTitle(entry);
    final String? sub = _entrySub(entry);

    return Semantics(
      button: true,
      label: '$title at $time. Double-tap to open this entry.',
      child: Material(
        color: context.hc.background,
        child: InkWell(
          key: JournalScreen.entryTileKey(entry.id),
          onTap: () => context.push('/journal/${entry.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.edit_note_outlined,
                  size: 26,
                  color: context.hc.primarySoft,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '$time   $title',
                        style: textTheme.bodyLarge?.copyWith(
                          color: context.hc.primary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (sub != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          sub,
                          style: textTheme.bodyMedium?.copyWith(
                            color: context.hc.primarySoft,
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
                  color: context.hc.primarySoft,
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
// Helpers
// ---------------------------------------------------------------------------

/// Title line for an entry tile — the first line of the caregiver's
/// situation text, or a plain "Journal note" when the entry has none.
String _entryTitle(JournalEntry entry) {
  final String? s = entry.situationText?.trim();
  if (s != null && s.isNotEmpty) return s.split('\n').first;
  return 'Journal note';
}

/// Optional second line for an entry tile — a preview of what the
/// caregiver tried, or their notes. Null when there's nothing to show.
String? _entrySub(JournalEntry entry) {
  final String? attempts = entry.attemptsText?.trim();
  if (attempts != null && attempts.isNotEmpty) {
    return attempts.split('\n').first;
  }
  final String? notes = entry.notes?.trim();
  if (notes != null && notes.isNotEmpty) return notes.split('\n').first;
  return null;
}

@immutable
class _WeekStats {
  const _WeekStats({
    required this.thisWeek,
    required this.lastWeek,
  });

  final int thisWeek;
  final int lastWeek;

  /// Bucket [entries] (already 30-day windowed) into the two 7-day
  /// windows the summary card compares.
  factory _WeekStats.from(List<JournalEntry> entries, DateTime now) {
    final DateTime thisWeekCutoff = now.subtract(const Duration(days: 7));
    final DateTime lastWeekCutoff = now.subtract(const Duration(days: 14));

    int thisWeek = 0;
    int lastWeek = 0;

    for (final JournalEntry e in entries) {
      if (e.createdAt.isAfter(thisWeekCutoff)) {
        thisWeek += 1;
      } else if (e.createdAt.isAfter(lastWeekCutoff)) {
        lastWeek += 1;
      }
    }

    return _WeekStats(
      thisWeek: thisWeek,
      lastWeek: lastWeek,
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
