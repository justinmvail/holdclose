import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/health_log_entry.dart';
import '../../providers/health_log_provider.dart';
import '../../theme.dart';
import '../../widgets/form/form_error_view.dart';
import '../../widgets/form/format.dart';
import '../../widgets/path_header.dart';

/// Health Log list at `/medical/health-log` (TASKS.md Phase 14.17,
/// BUILD_SPEC.md §5.13).
///
/// A [PathHeader] (`Home › Medical › Health Log`, back to Medical) sits
/// above the loved one's vitals / symptom / note history, grouped by
/// local calendar day with the newest day first. Each row carries a
/// kind glyph, a one-line summary ([_summaryFor]), and a relative
/// timestamp.
///
/// The screen never reaches the database directly — it reads through the
/// [healthLogProvider] notifier (which loads every entry newest-first)
/// and the entry form writes through the same notifier, so a save / edit
/// / delete reflects here without a manual invalidate. The "+" floating
/// action pushes the add form at `/medical/health-log/new`; the empty
/// state offers the same destination inline.
class HealthLogScreen extends ConsumerWidget {
  const HealthLogScreen({super.key});

  static const Key listKey = Key('health-log-list');
  static const Key emptyStateKey = Key('health-log-empty');
  static const Key emptyCtaKey = Key('health-log-empty-cta');
  static const Key fabKey = Key('health-log-fab');

  /// Stable per-row key derived from the entry id. Tests tap by id rather
  /// than by visible summary so a copy edit doesn't break them.
  static Key rowKey(String entryId) => Key('health-log-row-$entryId');

  /// Stable per-day-section key derived from the day's ISO date.
  static Key daySectionKey(DateTime day) =>
      Key('health-log-day-${day.year}-${day.month}-${day.day}');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<HealthLogEntry>> async =
        ref.watch(healthLogProvider);
    final DateTime now = ref.watch(healthLogClockProvider)();

    return Scaffold(
      backgroundColor: context.hc.background,
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
                  PathHeaderCrumb(label: 'Health Log'),
                ],
                title: 'Health Log',
                backLabel: 'Back to Care',
                leadingIcon: Icons.monitor_heart_outlined,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => FormErrorView(
                    message: "We couldn't load the health log.\n$e"),
                data: (List<HealthLogEntry> entries) {
                  if (entries.isEmpty) return const _EmptyState();
                  return _GroupedList(
                    groups: _groupByDay(entries, now),
                    now: now,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: async.maybeWhen(
        data: (List<HealthLogEntry> entries) {
          if (entries.isEmpty) return null;
          return _AddEntryFab(
            onPressed: () => context.push('/medical/health-log/new'),
          );
        },
        orElse: () => null,
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
      key: HealthLogScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.monitor_heart_outlined,
            size: 56,
            color: context.hc.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'No entries yet.',
            style: textTheme.headlineMedium?.copyWith(
              color: context.hc.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Jot vitals, a symptom you noticed, or a quick note about your '
            "loved one's day. It's an easy way to bring the real picture to "
            'the next doctor visit.',
            style: textTheme.bodyLarge?.copyWith(
              color: context.hc.text,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'Add an entry. Open the new health-log entry form.',
            child: ElevatedButton.icon(
              key: HealthLogScreen.emptyCtaKey,
              onPressed: () => context.push('/medical/health-log/new'),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                'Add an entry',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: context.hc.ctaFilled,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupedList extends StatelessWidget {
  const _GroupedList({required this.groups, required this.now});

  final List<_DayGroup> groups;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    // Flatten the day groups into one item list so the (unbounded)
    // history builds rows lazily. Render order is unchanged: each day
    // header followed by that day's entries.
    final List<_LogRow> rows = <_LogRow>[
      for (final _DayGroup group in groups) ...<_LogRow>[
        _HeaderRow(group),
        for (final HealthLogEntry entry in group.entries) _EntryItemRow(entry),
      ],
    ];
    return ListView.builder(
      key: HealthLogScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: rows.length,
      itemBuilder: (BuildContext context, int i) {
        switch (rows[i]) {
          case _HeaderRow(group: final _DayGroup group):
            return _DayHeader(
              key: HealthLogScreen.daySectionKey(group.day),
              label: group.label,
            );
          case _EntryItemRow(entry: final HealthLogEntry entry):
            return _EntryRow(entry: entry, now: now);
        }
      },
    );
  }
}

/// One row in the flattened health-log list — a day header or an entry —
/// so a single lazy ListView scrolls the whole history.
sealed class _LogRow {
  const _LogRow();
}

class _HeaderRow extends _LogRow {
  const _HeaderRow(this.group);
  final _DayGroup group;
}

class _EntryItemRow extends _LogRow {
  const _EntryItemRow(this.entry);
  final HealthLogEntry entry;
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Text(
        label,
        style: textTheme.titleLarge?.copyWith(
          color: context.hc.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.now});

  final HealthLogEntry entry;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String summary = _summaryFor(entry);
    final String when = _relativeTime(entry.recordedAt, now);
    final Color glyphColor = _kindColor(context, entry.kind);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: '${_kindLabel(entry.kind)}. $summary. $when. '
            'Double-tap to edit.',
        child: Material(
          color: context.hc.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: HealthLogScreen.rowKey(entry.id),
            borderRadius: BorderRadius.circular(16),
            onTap: () =>
                context.push('/medical/health-log/${entry.id}/edit'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: glyphColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _kindGlyph(entry.kind),
                      size: 22,
                      color: glyphColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          summary,
                          style: textTheme.bodyLarge?.copyWith(
                            color: context.hc.text,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          when,
                          style: textTheme.bodyMedium?.copyWith(
                            color: context.hc.primarySoft,
                          ),
                        ),
                      ],
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

class _AddEntryFab extends StatelessWidget {
  const _AddEntryFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add an entry. Open the new health-log entry form.',
      child: FloatingActionButton.extended(
        key: HealthLogScreen.fabKey,
        heroTag: 'health-log-add-fab',
        onPressed: onPressed,
        backgroundColor: context.hc.ctaFilled,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Add entry',
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grouping + formatting helpers
// ---------------------------------------------------------------------------

/// One day's worth of entries — the bucket [_GroupedList] renders under a
/// single [_DayHeader].
@immutable
class _DayGroup {
  const _DayGroup({
    required this.day,
    required this.label,
    required this.entries,
  });

  final DateTime day;
  final String label;
  final List<HealthLogEntry> entries;
}

/// Bucket [entries] (already newest-first) by local calendar day,
/// preserving order so the newest day — and the newest entry within it —
/// stays on top.
List<_DayGroup> _groupByDay(List<HealthLogEntry> entries, DateTime now) {
  final List<_DayGroup> groups = <_DayGroup>[];
  final List<HealthLogEntry> currentEntries = <HealthLogEntry>[];
  DateTime? currentDay;

  void flush() {
    final DateTime? day = currentDay;
    if (day == null) return;
    groups.add(_DayGroup(
      day: day,
      label: _dayLabel(day, now),
      entries: List<HealthLogEntry>.unmodifiable(currentEntries),
    ));
  }

  for (final HealthLogEntry e in entries) {
    final DateTime local = e.recordedAt.toLocal();
    final DateTime day = DateTime(local.year, local.month, local.day);
    if (currentDay == null || day != currentDay) {
      flush();
      currentDay = day;
      currentEntries.clear();
    }
    currentEntries.add(e);
  }
  flush();
  return groups;
}

const List<String> _weekdaysShort = <String>[
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
];

/// "Today" / "Yesterday" for the two nearest days, otherwise a
/// "Mon, Jun 1" weekday + month-day stamp.
String _dayLabel(DateTime day, DateTime now) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime yesterday = today.subtract(const Duration(days: 1));
  if (day == today) return 'Today';
  if (day == yesterday) return 'Yesterday';
  return '${_weekdaysShort[day.weekday - 1]}, '
      '${monthAbbreviations[day.month - 1]} ${day.day}';
}

/// "just now" / "5m ago" / "3h ago" within the last day, otherwise the
/// clock time the entry was recorded ("2:30 PM"). A future-stamped entry
/// (clock skew) reads as "just now" rather than a negative interval.
String _relativeTime(DateTime at, DateTime now) {
  final Duration delta = now.difference(at);
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return formatClock12h(at.toLocal());
}

/// One-line summary the row shows for [entry], keyed off its kind
/// (TASKS.md Phase 14.17):
///   - vitals  → "BP 130/82 · HR 76 · 98.6°F · 110 mg/dL · 152 lb"
///     (only the fields present)
///   - symptom → "Headache · 3/5" (note text + severity when set)
///   - note    → the first 60 characters of the note text
String _summaryFor(HealthLogEntry entry) {
  switch (entry.kind) {
    case HealthLogKind.vitals:
      final List<String> parts = <String>[];
      if (entry.systolic != null && entry.diastolic != null) {
        parts.add('BP ${entry.systolic}/${entry.diastolic}');
      }
      if (entry.heartRate != null) parts.add('HR ${entry.heartRate}');
      if (entry.temperatureF != null) {
        parts.add('${_formatReading(entry.temperatureF!)}°F');
      }
      if (entry.glucoseMgDl != null) {
        parts.add('${entry.glucoseMgDl} mg/dL');
      }
      if (entry.weightLbs != null) {
        parts.add('${_formatReading(entry.weightLbs!)} lb');
      }
      if (parts.isNotEmpty) return parts.join(' · ');
      final String notes = entry.notes?.trim() ?? '';
      return notes.isEmpty ? 'Vitals' : _truncate(notes, 60);
    case HealthLogKind.symptom:
      final List<String> parts = <String>[];
      final String notes = entry.notes?.trim() ?? '';
      if (notes.isNotEmpty) parts.add(_truncate(notes, 60));
      if (entry.severity != null) parts.add('${entry.severity}/5');
      return parts.isEmpty ? 'Symptom' : parts.join(' · ');
    case HealthLogKind.note:
      final String notes = entry.notes?.trim() ?? '';
      return notes.isEmpty ? 'Note' : _truncate(notes, 60);
  }
}

/// Drop a trailing `.0` so a whole-number reading reads "99°F" / "152 lb"
/// not "99.0°F" / "152.0 lb", but keep "98.6°F" / "152.5 lb" intact.
String _formatReading(double t) {
  if (t == t.roundToDouble()) return t.toStringAsFixed(0);
  return t.toStringAsFixed(1);
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max).trimRight()}…';

String _kindLabel(HealthLogKind kind) {
  switch (kind) {
    case HealthLogKind.vitals:
      return 'Vitals';
    case HealthLogKind.symptom:
      return 'Symptom';
    case HealthLogKind.note:
      return 'Note';
  }
}

IconData _kindGlyph(HealthLogKind kind) {
  switch (kind) {
    case HealthLogKind.vitals:
      return Icons.favorite_outline;
    case HealthLogKind.symptom:
      return Icons.sick_outlined;
    case HealthLogKind.note:
      return Icons.sticky_note_2_outlined;
  }
}

Color _kindColor(BuildContext context, HealthLogKind kind) {
  switch (kind) {
    case HealthLogKind.vitals:
      return context.hc.accentDeep;
    case HealthLogKind.symptom:
      return context.hc.cta;
    case HealthLogKind.note:
      return context.hc.link;
  }
}
