import 'package:flutter/material.dart';
// `Provider` in [models/appointment.dart] collides with riverpod's own
// `Provider` — `hide` keeps the model name resolvable here without aliasing
// every callsite, the same way the recent-activity card + appointment
// screens do.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/appointment.dart';
import '../../models/care_task.dart';
import '../../models/journal_entry.dart';
import '../../models/medication.dart';
import '../../providers/care_tasks_provider.dart';
import '../../providers/journal_entries_provider.dart';
// The feed reads each source through the same seam its owning surface reads
// through — the journal stream, the dose-log "today" provider, the
// appointment repository, the task board — rather than minting parallel
// queries. (It deliberately keeps its own copies of the small summary +
// relative-time helpers: the Home Recent Activity card marks its versions
// `@visibleForTesting`, so they aren't a public API to reuse from here.)
import '../../screens/medication/dose_log_screen.dart' show dosesTodayProvider;
import '../../services/appointment_repository.dart';
import '../../services/medication_repository.dart'
    show DoseWindowGroup, ScheduledDose, groupDosesByWindow;
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'activity_screen.g.dart';

/// How many rows the activity feed materializes per page (Phase 14.32). The
/// feed is conceptually unbounded; the list grows a page at a time as the
/// caregiver scrolls so a long history doesn't build every row up front.
const int activityPageSize = 20;

/// Which surface an [ActivityFeedItem] came from (TASKS.md Phase 14.32,
/// BUILD_SPEC.md §5.14). Drives the leading dot color, the row's accessible
/// label, and the filter the chip row toggles against.
///
/// Five of the six kinds are independently filterable via the chip row
/// ([activityFilterCategories]); [appointment] is the exception. The spec's
/// chip list is `All / Doses / Notes / Tasks / Shifts / Expenses` — it omits
/// an Appointments chip while still naming "appointment kept" among the
/// meaningful events. So appointment rows surface under **All** (no chip
/// selected) but aren't independently filterable.
// TODO(decision): if an Appointments chip is wanted later, add
// [appointment] to [activityFilterCategories] — the rest of the pipeline
// already handles it.
enum ActivityCategory { dose, note, appointment, task, shift, expense }

/// The categories the filter-chip row exposes, in display order (Phase
/// 14.32). [ActivityCategory.appointment] is intentionally absent — see the
/// [ActivityCategory] doc.
const List<ActivityCategory> activityFilterCategories = <ActivityCategory>[
  ActivityCategory.dose,
  ActivityCategory.note,
  ActivityCategory.task,
  ActivityCategory.shift,
  ActivityCategory.expense,
];

/// One row in the chronological Care Circle activity feed (Phase 14.32).
///
/// Every source maps its own row shape onto this single shape so the merge
/// + sort is one pure operation regardless of how many sources feed it.
/// [createdAt] is the timeline position the feed sorts by, descending;
/// [route] is the location a tap pushes to reach the source detail.
@immutable
class ActivityFeedItem {
  const ActivityFeedItem({
    required this.id,
    required this.category,
    required this.summary,
    required this.createdAt,
    required this.route,
    this.doseWindow,
  });

  /// Source-prefixed so ids stay unique once several sources merge.
  final String id;
  final ActivityCategory category;
  final String summary;
  final DateTime createdAt;

  /// The location [ActivityScreen] pushes when the row is tapped.
  final String route;

  /// When set, this row is a folded medication window — the doses acted on
  /// in one window collapse into a single entry that renders the window
  /// header + each med with its status, the same way the Calendar and Home
  /// schedule group doses. [summary] is the plain-text fallback (used for
  /// the row's accessible label). Null for every non-dose row.
  final ActivityDoseWindow? doseWindow;
}

/// A folded medication window for the activity feed — the window's name and
/// the meds acted on in it, each with the status the caregiver logged.
@immutable
class ActivityDoseWindow {
  const ActivityDoseWindow({required this.windowLabel, required this.meds});

  /// The window's name ("Morning", "Evening", "As needed").
  final String windowLabel;

  /// The acted-on meds in this window, in the order the repository grouped
  /// them (sorted by name).
  final List<ActivityDoseEntry> meds;
}

/// One medication within an [ActivityDoseWindow] — its display name
/// ("Donepezil 10 mg") and the status the caregiver logged.
@immutable
class ActivityDoseEntry {
  const ActivityDoseEntry({required this.name, required this.status});

  final String name;
  final DoseStatus status;
}

/// The category-dot hue (Phase 14.32). Dose / note / appointment match the
/// Home Recent Activity card's hues so the two surfaces share one color
/// language; task / shift / expense map onto the §3.1 brand tokens the
/// shared calendar already uses (task → `link`, shift → `success`), with
/// expense on brand navy. Exposed so tests assert the mapping without
/// reaching into private state.
@visibleForTesting
Color activityCategoryColor(BuildContext context, ActivityCategory category) {
  switch (category) {
    case ActivityCategory.dose:
      return ActivityScreen.doseColor; // teal
    case ActivityCategory.note:
      return ActivityScreen.noteColor; // plum
    case ActivityCategory.appointment:
      return ActivityScreen.appointmentColor; // coral
    case ActivityCategory.task:
      return context.cb.link; // cool blue
    case ActivityCategory.shift:
      return context.cb.success; // green
    case ActivityCategory.expense:
      return context.cb.primary; // navy
  }
}

/// The word label a chip / accessible row reads for [category] (Phase
/// 14.32). Plural to match the chip row copy (`Doses`, `Notes`, …).
@visibleForTesting
String activityCategoryLabel(ActivityCategory category) {
  switch (category) {
    case ActivityCategory.dose:
      return 'Doses';
    case ActivityCategory.note:
      return 'Notes';
    case ActivityCategory.appointment:
      return 'Appointments';
    case ActivityCategory.task:
      return 'Tasks';
    case ActivityCategory.shift:
      return 'Shifts';
    case ActivityCategory.expense:
      return 'Expenses';
  }
}

// ---------------------------------------------------------------------------
// Summary helpers (pure)
// ---------------------------------------------------------------------------

/// Short feed summary for a journal entry — the caregiver's situation text
/// for a wizard note, the behavior label for a decoder auto-log.
@visibleForTesting
String activityJournalSummary(JournalEntry entry) {
  if (entry.wizardKind) {
    final String? situation = entry.situationText?.trim();
    if (situation != null && situation.isNotEmpty) return situation;
    return 'Journal note';
  }
  return entry.behavior.label;
}

/// The word a dose's logged [status] reads as — the verb the old per-dose
/// summary used, now folded into the window row's accessible label.
String _doseStatusWord(DoseStatus status) => switch (status) {
      DoseStatus.skipped => 'Skipped',
      DoseStatus.missed => 'Missed',
      DoseStatus.taken || DoseStatus.late => 'Gave',
    };

/// Short feed summary for an appointment — "Appointment with Dr. Ortega",
/// or a soft fallback when the provider row is missing (deleted, or not yet
/// resolved).
@visibleForTesting
String activityAppointmentSummary(Provider? provider) {
  final String name = provider?.name ?? 'your provider';
  return 'Appointment with $name';
}

// ---------------------------------------------------------------------------
// Source → item mapping (pure, unit-testable without a widget tree)
// ---------------------------------------------------------------------------

/// Map a journal entry onto a feed row — a wizard note shows the caregiver's
/// situation text and a decoder auto-log shows the behavior label.
@visibleForTesting
ActivityFeedItem journalActivityFeedItem(JournalEntry entry) {
  return ActivityFeedItem(
    id: 'journal-${entry.id}',
    category: ActivityCategory.note,
    summary: activityJournalSummary(entry),
    createdAt: entry.createdAt,
    route: '/journal/${entry.id}',
  );
}

/// Fold the acted-on doses into one feed row **per medication window** —
/// "Morning Medication" with each med + its logged status — instead of one
/// row per dose, matching the Calendar and Home schedule grouping. The
/// caller passes only doses the caregiver has acted on (`log != null`);
/// across windows the order follows [groupDosesByWindow] (by anchor time),
/// and the feed's own newest-first sort then places each window by its most
/// recent action.
@visibleForTesting
List<ActivityFeedItem> doseWindowActivityFeedItems(
  List<ScheduledDose> actedDoses,
) {
  return <ActivityFeedItem>[
    for (final DoseWindowGroup g in groupDosesByWindow(actedDoses))
      _doseWindowFeedItem(g),
  ];
}

ActivityFeedItem _doseWindowFeedItem(DoseWindowGroup group) {
  final List<ActivityDoseEntry> meds = <ActivityDoseEntry>[
    for (final ScheduledDose d in group.doses)
      ActivityDoseEntry(
        name: '${d.medication.name} ${d.medication.dosage}',
        status: d.log!.status,
      ),
  ];
  // Anchor the entry to the window's most recent action so it sorts among
  // the other events by when the caregiver last acted in this window.
  final DateTime createdAt = group.doses
      .map((ScheduledDose d) => d.log!.takenAt ?? d.scheduledFor)
      .reduce((DateTime a, DateTime b) => a.isAfter(b) ? a : b);
  return ActivityFeedItem(
    id: 'dose-window-${group.window.id}-'
        '${createdAt.millisecondsSinceEpoch}',
    category: ActivityCategory.dose,
    summary: '${group.window.label} medications',
    createdAt: createdAt,
    route: '/medications/today',
    doseWindow: ActivityDoseWindow(
      windowLabel: group.window.label,
      meds: meds,
    ),
  );
}

/// Map an appointment onto a feed row. The appointment model carries no
/// "kept at" timestamp, so [Appointment.startsAt] stands in as the timeline
/// position — `formatRelativeTime` renders an upcoming visit as "in 2 days"
/// so it still reads sensibly here (same compromise the Home card makes).
@visibleForTesting
ActivityFeedItem appointmentActivityFeedItem(
  Appointment appointment,
  Provider? provider,
) {
  return ActivityFeedItem(
    id: 'appointment-${appointment.id}',
    category: ActivityCategory.appointment,
    summary: activityAppointmentSummary(provider),
    createdAt: appointment.startsAt,
    route: '/appointments/${appointment.id}',
  );
}

/// Map a completed task onto a feed row (TASKS.md Phase 14.32: "task
/// completed"). [task.completedAt] is expected non-null — the aggregator
/// only maps finished tasks — and is the timeline position. The row routes
/// back to the task board (there is no per-task detail page in v1).
@visibleForTesting
ActivityFeedItem taskActivityFeedItem(CareTask task) {
  return ActivityFeedItem(
    id: 'task-${task.id}',
    category: ActivityCategory.task,
    summary: 'Completed ${task.title}',
    createdAt: task.completedAt!,
    route: '/team/tasks',
  );
}

// ---------------------------------------------------------------------------
// Merge + filter (pure)
// ---------------------------------------------------------------------------

/// Sort [items] by [ActivityFeedItem.createdAt] descending — the whole
/// feed's ordering contract collapses to this one pure step, so an
/// out-of-order insertion in any single source still lands in the right
/// place. Unlike the Home card this keeps **every** item (no top-N
/// truncation); the screen paginates the result instead.
@visibleForTesting
List<ActivityFeedItem> mergeActivity(Iterable<ActivityFeedItem> items) {
  final List<ActivityFeedItem> sorted = items.toList()
    ..sort((ActivityFeedItem a, ActivityFeedItem b) =>
        b.createdAt.compareTo(a.createdAt));
  return List<ActivityFeedItem>.unmodifiable(sorted);
}

/// Narrow [items] to the [selected] categories (Phase 14.32). An empty
/// [selected] means the **All** chip is active — every row passes,
/// appointments included. A non-empty set keeps only rows whose category is
/// in it; because appointments have no chip, selecting any chip hides them.
/// Pure so the filter-combination tests run without a widget tree.
@visibleForTesting
List<ActivityFeedItem> filterActivity(
  List<ActivityFeedItem> items,
  Set<ActivityCategory> selected,
) {
  if (selected.isEmpty) return items;
  return items
      .where((ActivityFeedItem i) => selected.contains(i.category))
      .toList();
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Shift-sourced activity rows ([ActivityCategory.shift]) — the seam Phase
/// 14.31 (Shifts) wires once a shift handoff is a first-class event
/// (TASKS.md Phase 14.32). Contributes nothing until then; kept as an
/// overridable provider so [teamActivity] can merge all sources without this
/// phase pre-building the Shifts module. Tests override it to inject sample
/// shift rows — the same seam pattern the shared calendar uses for its
/// not-yet-landed task/shift sources.
@riverpod
Future<List<ActivityFeedItem>> activityShiftItems(Ref ref) async =>
    const <ActivityFeedItem>[];

/// Expense-sourced activity rows ([ActivityCategory.expense]) — the seam
/// Phase 14.33 (Expenses) wires once an added expense is a first-class
/// event. Empty until then; see [activityShiftItems] for the rationale.
@riverpod
Future<List<ActivityFeedItem>> activityExpenseItems(Ref ref) async =>
    const <ActivityFeedItem>[];

/// The unified Care Circle activity feed (TASKS.md Phase 14.32, BUILD_SPEC.md
/// §5.14).
///
/// Draws from the same source pool as the Home Recent Activity card (Phase
/// 14.11) — journal notes, acted-on doses, appointments, and now completed
/// tasks — plus the [activityShiftItems] / [activityExpenseItems] seams that
/// later phases fill in. Every source is mapped onto an [ActivityFeedItem]
/// and the whole set is sorted newest-first. Unlike the card this is
/// **unbounded** (no top-N) — the screen paginates and filters the result.
///
/// Tests override the leaf providers with fakes (or override this provider
/// wholesale for the display + golden cases), so the future resolves
/// synchronously inside the harness.
@riverpod
Future<List<ActivityFeedItem>> teamActivity(Ref ref) async {
  final List<JournalEntry> entries =
      await ref.watch(journalEntriesProvider.future);
  final List<ScheduledDose> doses = await ref.watch(dosesTodayProvider.future);

  final AppointmentRepository repo =
      ref.watch(appointmentRepositoryProvider);
  final List<Appointment> appointments = await repo.listAppointments();
  final List<Provider> providers = await repo.listProviders();
  final Map<String, Provider> providerById = <String, Provider>{
    for (final Provider p in providers) p.id: p,
  };

  final List<CareTask> tasks = await ref.watch(careTasksProvider.future);

  final List<ActivityFeedItem> shiftItems =
      await ref.watch(activityShiftItemsProvider.future);
  final List<ActivityFeedItem> expenseItems =
      await ref.watch(activityExpenseItemsProvider.future);

  final List<ActivityFeedItem> items = <ActivityFeedItem>[
    for (final JournalEntry e in entries) journalActivityFeedItem(e),
    // Only doses the caregiver has acted on are "activity" — an upcoming,
    // unlogged dose isn't a handoff-worthy event. Acted doses fold into one
    // row per medication window (the same grouping the Calendar + Home
    // schedule use) instead of one row each.
    ...doseWindowActivityFeedItems(
      doses.where((ScheduledDose d) => d.log != null).toList(),
    ),
    for (final Appointment a in appointments)
      appointmentActivityFeedItem(a, providerById[a.providerId]),
    // Only completed tasks are activity — an open/claimed task lives on the
    // board, not in the history feed.
    for (final CareTask t in tasks)
      if (t.completedAt != null) taskActivityFeedItem(t),
    ...shiftItems,
    ...expenseItems,
  ];

  return mergeActivity(items);
}

/// Wall clock the feed samples for its relative-time stamps. Overridable so
/// widget + golden tests pin a fixed "now" and the stamps stay stable across
/// host time — same pattern [calendarClockProvider] uses.
@Riverpod(keepAlive: true)
DateTime Function() activityClock(Ref ref) => DateTime.now;

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Care Circle → Activity at `/team/activity` (TASKS.md Phase 14.32,
/// BUILD_SPEC.md §5.14).
///
/// A [PathHeader] (`Home › Care Circle › Activity`, back to Care Circle) over a
/// multi-select filter-chip row (All / Doses / Notes / Tasks / Shifts /
/// Expenses) and an unbounded, paginated, chronological feed of every
/// meaningful care event. Each row carries a category-color dot, a one-line
/// summary, and a relative time; tapping it pushes that event's source
/// detail. Pull-to-refresh re-queries the source providers.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  // Category-dot hues. Dose teal / note plum / appointment coral match the
  // Home Recent Activity card so the dashboard + feed share one color
  // language; task / shift / expense resolve to brand tokens (see
  // [activityCategoryColor]).
  static const Color doseColor = Color(0xFF1F8A70); // teal
  static const Color noteColor = Color(0xFF7B4B94); // plum
  static const Color appointmentColor = Color(0xFFE5573F); // coral

  /// The "All" chip.
  static const Key allChipKey = Key('activity-chip-all');

  /// The scrollable feed body.
  static const Key listKey = Key('activity-list');

  /// The empty-state body.
  static const Key emptyKey = Key('activity-empty');

  /// The error-state body.
  static const Key errorKey = Key('activity-error');

  /// The trailing "loading more" footer shown while more pages remain.
  static const Key loadMoreKey = Key('activity-load-more');

  /// Per-category chip key.
  static Key chipKey(ActivityCategory c) => Key('activity-chip-${c.name}');

  /// Stable per-row key — the source-prefixed [ActivityFeedItem.id].
  static Key rowKey(String itemId) => Key('activity-row-$itemId');

  /// The category dot for a row — tests read its color to assert the hue.
  static Key dotKey(String itemId) => Key('activity-dot-$itemId');

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  /// Empty = the "All" chip is active. A non-empty set is the union of the
  /// individually-toggled category chips.
  final Set<ActivityCategory> _selected = <ActivityCategory>{};

  /// How many rows are currently materialized; grows a page at a time as the
  /// caregiver scrolls toward the end.
  int _visibleCount = activityPageSize;

  void _toggle(ActivityCategory category) {
    setState(() {
      if (_selected.contains(category)) {
        _selected.remove(category);
      } else {
        _selected.add(category);
      }
      // A filter change re-bounds the visible window so the first page of
      // the newly-filtered set shows from the top.
      _visibleCount = activityPageSize;
    });
  }

  void _selectAll() {
    setState(() {
      _selected.clear();
      _visibleCount = activityPageSize;
    });
  }

  /// Re-query every source feeding the feed (BUILD_SPEC.md §5.14
  /// "Pull-to-refresh re-queries the providers"). The journal stream is
  /// already live off drift, so invalidating the future-backed sources +
  /// the aggregator is enough to pull fresh data; awaiting the aggregator's
  /// future keeps the refresh spinner up until the new feed resolves.
  Future<void> _refresh() async {
    ref.invalidate(dosesTodayProvider);
    ref.invalidate(careTasksProvider);
    ref.invalidate(activityShiftItemsProvider);
    ref.invalidate(activityExpenseItemsProvider);
    ref.invalidate(teamActivityProvider);
    await ref.read(teamActivityProvider.future);
  }

  /// Grow the visible window when the list scrolls within a page-height of
  /// the bottom and more rows remain. Returns false so the notification
  /// keeps bubbling.
  bool _onScroll(ScrollNotification notification, int total) {
    if (notification.metrics.pixels >=
            notification.metrics.maxScrollExtent - 400 &&
        _visibleCount < total) {
      setState(() {
        _visibleCount =
            (_visibleCount + activityPageSize).clamp(0, total).toInt();
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<ActivityFeedItem>> async =
        ref.watch(teamActivityProvider);
    final DateTime now = ref.watch(activityClockProvider)();

    return Scaffold(
      backgroundColor: context.cb.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const PathHeader(
                    breadcrumbs: <PathHeaderCrumb>[
                      PathHeaderCrumb(label: 'Home', route: '/'),
                      PathHeaderCrumb(label: 'Care Circle', route: '/team'),
                      PathHeaderCrumb(label: 'Activity'),
                    ],
                    title: 'Activity',
                    backLabel: 'Back to Care Circle',
                    leadingIcon: Icons.timeline_outlined,
                  ),
                  const SizedBox(height: 12),
                  _FilterChips(
                    selected: _selected,
                    onToggle: _toggle,
                    onSelectAll: _selectAll,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(
                  message: '$e',
                  onRetry: _refresh,
                ),
                data: (List<ActivityFeedItem> all) {
                  final List<ActivityFeedItem> filtered =
                      filterActivity(all, _selected);
                  return RefreshIndicator(
                    onRefresh: _refresh,
                    color: context.cb.cta,
                    child: _Feed(
                      items: filtered,
                      now: now,
                      visibleCount: _visibleCount,
                      onScroll: (ScrollNotification n) =>
                          _onScroll(n, filtered.length),
                    ),
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

/// The All / Doses / Notes / Tasks / Shifts / Expenses chip row, horizontally
/// scrollable so it never wraps off-screen. "All" reads selected whenever no
/// category chip is active.
class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.selected,
    required this.onToggle,
    required this.onSelectAll,
  });

  final Set<ActivityCategory> selected;
  final ValueChanged<ActivityCategory> onToggle;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          _Chip(
            chipKey: ActivityScreen.allChipKey,
            label: 'All',
            selected: selected.isEmpty,
            onTap: onSelectAll,
          ),
          for (final ActivityCategory category in activityFilterCategories)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _Chip(
                chipKey: ActivityScreen.chipKey(category),
                label: activityCategoryLabel(category),
                selected: selected.contains(category),
                onTap: () => onToggle(category),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.chipKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key chipKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color border =
        selected ? context.cb.cta : context.cb.primarySoft;
    final Color fill = selected
        ? context.cb.cta.withValues(alpha: 0.12)
        : Colors.transparent;
    final Color fg = selected ? context.cb.cta : context.cb.text;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        key: chipKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: textTheme.labelLarge?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// The scrollable feed itself. Always scrollable (even when short or empty)
/// so the pull-to-refresh gesture stays available. Materializes only the
/// first [visibleCount] rows; a trailing footer marks where more remain.
class _Feed extends StatelessWidget {
  const _Feed({
    required this.items,
    required this.now,
    required this.visibleCount,
    required this.onScroll,
  });

  final List<ActivityFeedItem> items;
  final DateTime now;
  final int visibleCount;
  final bool Function(ScrollNotification) onScroll;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return ListView(
        key: ActivityScreen.listKey,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: const <Widget>[_EmptyState()],
      );
    }

    final int shown = visibleCount.clamp(0, items.length);
    final bool hasMore = shown < items.length;

    return NotificationListener<ScrollNotification>(
      onNotification: onScroll,
      child: ListView.builder(
        key: ActivityScreen.listKey,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        itemCount: shown + (hasMore ? 1 : 0),
        itemBuilder: (BuildContext context, int index) {
          if (index >= shown) {
            return const _LoadMoreFooter();
          }
          return _ActivityRow(item: items[index], now: now);
        },
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item, required this.now});

  final ActivityFeedItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color dotColor = activityCategoryColor(context, item.category);
    final String relative = activityRelativeTime(item.createdAt, now);
    final String kind = activityCategoryLabel(item.category);
    final ActivityDoseWindow? window = item.doseWindow;
    // A dose-window row reads its window + each med's status; every other
    // row reads its one-line summary.
    final String semanticLabel = window == null
        ? '$kind. ${item.summary}. $relative. Double-tap to open.'
        : <String>[
            kind,
            '${window.windowLabel} medications',
            for (final ActivityDoseEntry m in window.meds)
              '${_doseStatusWord(m.status)} ${m.name}',
            relative,
            'Double-tap to open.',
          ].join('. ');

    return Semantics(
      container: true,
      button: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Material(
          color: context.cb.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: ActivityScreen.rowKey(item.id),
            onTap: () => context.push(item.route),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    // Nudge the dot down onto the summary's first line.
                    padding: const EdgeInsets.only(top: 6),
                    child: _CategoryDot(
                      color: dotColor,
                      dotKey: ActivityScreen.dotKey(item.id),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: window == null
                        ? Text(
                            item.summary,
                            style: textTheme.bodyLarge?.copyWith(
                              color: context.cb.primary,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          )
                        : _DoseWindowBody(window: window),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    relative,
                    style: textTheme.bodyMedium?.copyWith(
                      color: context.cb.primarySoft,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryDot extends StatelessWidget {
  const _CategoryDot({required this.color, required this.dotKey});

  final Color color;
  final Key dotKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: dotKey,
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The body of a folded medication-window row — the window header over each
/// med with the status the caregiver logged. Mirrors the Calendar's window
/// card so the two surfaces read alike.
class _DoseWindowBody extends StatelessWidget {
  const _DoseWindowBody({required this.window});

  final ActivityDoseWindow window;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '${window.windowLabel} Medication',
          style: textTheme.bodyLarge?.copyWith(
            color: context.cb.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        for (final ActivityDoseEntry m in window.meds)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Row(
              children: <Widget>[
                _DoseStatusIcon(status: m.status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      color: context.cb.text,
                      // A given dose reads as "done" (struck through), the
                      // same as the Calendar; a skip / miss stays upright
                      // because it's the notable exception.
                      decoration: (m.status == DoseStatus.taken ||
                              m.status == DoseStatus.late)
                          ? TextDecoration.lineThrough
                          : null,
                      decorationColor: context.cb.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DoseStatusIcon extends StatelessWidget {
  const _DoseStatusIcon({required this.status});

  final DoseStatus status;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = switch (status) {
      DoseStatus.taken || DoseStatus.late => (
          Icons.check_circle,
          context.cb.success,
        ),
      DoseStatus.skipped => (
          Icons.do_not_disturb_on_outlined,
          context.cb.primarySoft,
        ),
      DoseStatus.missed => (
          Icons.error_outline,
          context.cb.error,
        ),
    };
    return Icon(icon, size: 18, color: color);
  }
}

class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: ActivityScreen.loadMoreKey,
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: ActivityScreen.emptyKey,
      padding: const EdgeInsets.fromLTRB(8, 40, 8, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.timeline_outlined,
            size: 56,
            color: context.cb.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'Nothing here yet.',
            style: textTheme.titleLarge?.copyWith(
              color: context.cb.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'As your care circle logs doses, notes, visits, and tasks, '
            'every moment shows up here.',
            style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: onRetry,
      color: context.cb.cta,
      child: ListView(
        key: ActivityScreen.errorKey,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        children: <Widget>[
          Text(
            "We couldn't load your care team's activity.\nPull down to try "
            'again.',
            style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

/// A coarse "20 min ago" / "in 2 days" relative stamp for the feed.
///
/// Buckets the gap between [at] and [now] into minutes, hours, days, then
/// weeks, with anything under a minute reading "just now". A past [at]
/// renders "<n> ago"; a future [at] (an upcoming appointment, whose timeline
/// position is its `startsAt`) renders "in <n>". Pure so the bucket
/// boundaries are unit-testable without a widget tree.
@visibleForTesting
String activityRelativeTime(DateTime at, DateTime now) {
  final int deltaSeconds = now.difference(at).inSeconds;
  final int seconds = deltaSeconds.abs();
  if (seconds < 60) return 'just now';
  final String magnitude = _relativeMagnitude(seconds);
  return deltaSeconds >= 0 ? '$magnitude ago' : 'in $magnitude';
}

String _relativeMagnitude(int seconds) {
  final int minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes min';
  final int hours = minutes ~/ 60;
  if (hours < 24) return hours == 1 ? '1 hr' : '$hours hrs';
  final int days = hours ~/ 24;
  if (days < 7) return days == 1 ? '1 day' : '$days days';
  final int weeks = days ~/ 7;
  return weeks == 1 ? '1 wk' : '$weeks wks';
}
