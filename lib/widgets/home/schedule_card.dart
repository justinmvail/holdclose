import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_event.dart';
import '../../providers/home_clock_provider.dart';
import '../../providers/patient_timeline_provider.dart';
import '../../theme.dart';
import 'recent_activity_card.dart' show recentActivityKindColor;

/// The "Schedule" dashboard card — the caregiver's at-a-glance view of
/// what's happening with the patient **today**, **tomorrow**, and the
/// **rest of this week**. Replaces the single-row Next Appointment card
/// so a 9am visit tomorrow can't hide behind a noon dose today.
///
/// Reads [patientTimelineEventsProvider] (the same merged stream the
/// activity feed slices) and buckets by wall-clock day:
///   - **Today** — events with `start` between `[startOfToday, endOfToday]`
///     (past *and* future, so "I already gave 8am dose" stays visible).
///   - **Tomorrow** — events on the calendar day after today.
///   - **This Week** — events strictly after tomorrow and on or before
///     Saturday of the visible week.
///
/// Each row taps through to [CareEventX.detailRoute]; the card header
/// taps to the Team Calendar so the caregiver can zoom out. Empty days
/// collapse — if today has nothing, the Today header doesn't render.
class ScheduleCard extends ConsumerWidget {
  const ScheduleCard({super.key});

  static const Key cardKey = Key('home-schedule-card');
  static const Key emptyKey = Key('home-schedule-empty');
  static const Key skeletonKey = Key('home-schedule-skeleton');
  static const Key todaySectionKey = Key('home-schedule-today');
  static const Key tomorrowSectionKey = Key('home-schedule-tomorrow');
  static const Key thisWeekSectionKey = Key('home-schedule-this-week');
  static const Key viewCalendarKey = Key('home-schedule-view-calendar');
  static Key rowKey(String eventId) => Key('home-schedule-row-$eventId');

  /// Maximum rows surfaced per section. The card is glanceable; the
  /// caregiver clicks through to /team/calendar to see everything.
  static const int _maxToday = 5;
  static const int _maxTomorrow = 4;
  static const int _maxThisWeek = 4;

  static const double _radius = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CareEvent>> async =
        ref.watch(patientTimelineEventsProvider);
    final DateTime now = ref.watch(homeClockProvider)();

    final Widget body = async.when(
      loading: () => const _Skeleton(),
      error: (Object _, StackTrace __) =>
          const _Message(text: "We couldn't load your schedule."),
      data: (List<CareEvent> events) {
        final _Buckets b = _bucket(events, now);
        if (b.isEmpty) {
          return const _Message(text: 'No upcoming items.', emptyKey: true);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (b.today.isNotEmpty)
              _Section(
                key: todaySectionKey,
                label: 'Today',
                events: b.today.take(_maxToday).toList(growable: false),
                now: now,
              ),
            if (b.tomorrow.isNotEmpty) ...<Widget>[
              if (b.today.isNotEmpty) const SizedBox(height: 12),
              _Section(
                key: tomorrowSectionKey,
                label: 'Tomorrow',
                events: b.tomorrow.take(_maxTomorrow).toList(growable: false),
                now: now,
              ),
            ],
            if (b.thisWeek.isNotEmpty) ...<Widget>[
              if (b.today.isNotEmpty || b.tomorrow.isNotEmpty)
                const SizedBox(height: 12),
              _Section(
                key: thisWeekSectionKey,
                label: 'This week',
                events: b.thisWeek.take(_maxThisWeek).toList(growable: false),
                now: now,
              ),
            ],
          ],
        );
      },
    );

    return Material(
      color: careblazersColors.surfaceWarm,
      borderRadius: BorderRadius.circular(_radius),
      child: Padding(
        key: cardKey,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _Header(
              onTapCalendar: () => context.push('/team/calendar'),
            ),
            const SizedBox(height: 12),
            body,
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onTapCalendar});

  final VoidCallback onTapCalendar;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(
            'Schedule',
            style: tt.titleLarge?.copyWith(color: careblazersColors.primary),
          ),
        ),
        TextButton(
          key: ScheduleCard.viewCalendarKey,
          onPressed: onTapCalendar,
          style: TextButton.styleFrom(
            foregroundColor: careblazersColors.link,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Calendar →'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.label,
    required this.events,
    required this.now,
  });

  final String label;
  final List<CareEvent> events;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    // Fold consecutive same-minute dose events into a single row whose
    // title is the wall-clock time and whose subtitle lists the
    // medication names — caregivers asked for "show medication and
    // time and the description has which medications" instead of one
    // row per dose.
    final List<_RowModel> rows = groupDoseEventsByMinute(events);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: tt.titleMedium?.copyWith(
            color: careblazersColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        for (final _RowModel r in rows)
          r is _GroupedDoseRow
              ? _GroupedRow(model: r, now: now)
              : _Row(event: (r as _SingleRow).event, now: now),
      ],
    );
  }
}

/// Per-section row model. Most events render as a [_SingleRow]; dose
/// occurrences sharing the same wall-clock minute fold into a
/// [_GroupedDoseRow] so the time leads and the meds list as the
/// description.
sealed class _RowModel {
  const _RowModel();
}

class _SingleRow extends _RowModel {
  const _SingleRow(this.event);
  final CareEvent event;
}

class _GroupedDoseRow extends _RowModel {
  const _GroupedDoseRow({
    required this.start,
    required this.meds,
    required this.firstEventId,
  });

  /// Wall-clock the shared minute resolves to.
  final DateTime start;

  /// Per-medication status at this minute, alphabetical by name.
  final List<({String name, bool taken})> meds;

  /// The first event's id, used as a stable key for tests/hits.
  final String firstEventId;

  /// True when every dose at this minute has already been logged.
  bool get allLogged => meds.every((({String name, bool taken}) m) => m.taken);
}

/// Group consecutive dose events (doseScheduled / doseLogged) that
/// share a wall-clock minute. Other event kinds pass through in their
/// original order. The input is assumed already sorted ascending by
/// [CareEvent.start]; the output preserves that ordering. Private
/// return type by design — the row model is a render detail not
/// meant for external consumers.
// ignore: library_private_types_in_public_api
List<_RowModel> groupDoseEventsByMinute(List<CareEvent> events) {
  final List<_RowModel> out = <_RowModel>[];
  int i = 0;
  while (i < events.length) {
    final CareEvent e = events[i];
    final bool isDose = e.kind == CareEventKind.doseScheduled ||
        e.kind == CareEventKind.doseLogged;
    if (!isDose) {
      out.add(_SingleRow(e));
      i++;
      continue;
    }
    final DateTime keyMinute = DateTime(
      e.start.year,
      e.start.month,
      e.start.day,
      e.start.hour,
      e.start.minute,
    );
    int j = i;
    // Aggregate per-medication taken status: a medication counts as
    // taken if ANY event at this minute is doseLogged for it. Two
    // identical-titled dose events at the same minute (rare but
    // possible) collapse to one chip.
    final Map<String, bool> takenByName = <String, bool>{};
    while (j < events.length) {
      final CareEvent c = events[j];
      final bool cIsDose = c.kind == CareEventKind.doseScheduled ||
          c.kind == CareEventKind.doseLogged;
      if (!cIsDose) break;
      final DateTime cMinute = DateTime(
        c.start.year,
        c.start.month,
        c.start.day,
        c.start.hour,
        c.start.minute,
      );
      if (cMinute != keyMinute) break;
      final bool taken = c.kind == CareEventKind.doseLogged;
      takenByName.update(c.title, (bool prev) => prev || taken,
          ifAbsent: () => taken);
      j++;
    }
    final List<({String name, bool taken})> meds = takenByName.entries
        .map((MapEntry<String, bool> e) =>
            (name: e.key, taken: e.value))
        .toList()
      ..sort((({String name, bool taken}) a, ({String name, bool taken}) b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    out.add(_GroupedDoseRow(
      start: keyMinute,
      meds: meds,
      firstEventId: e.id,
    ));
    i = j;
  }
  return out;
}

class _GroupedRow extends StatelessWidget {
  const _GroupedRow({required this.model, required this.now});

  final _GroupedDoseRow model;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final bool past = model.start.isBefore(now);
    final String time = _formatClock(model.start);
    final Color baseText = past
        ? careblazersColors.text.withValues(alpha: 0.55)
        : careblazersColors.text;
    return Padding(
      key: ScheduleCard.rowKey(model.firstEventId),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Time leads — one line, bold so the slot is the visual
          // anchor even before the caregiver reads the med names.
          SizedBox(
            width: 64,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                time,
                style: tt.bodyMedium?.copyWith(
                  color: baseText,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Each medication on its own row with a status mark.
          // Checkmark = logged dose, hollow circle = still pending.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final ({String name, bool taken}) m in model.meds)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        _DoseStatusMark(taken: m.taken, dimmed: past),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.bodyMedium?.copyWith(
                              color: baseText,
                              decoration: m.taken
                                  ? TextDecoration.lineThrough
                                  : null,
                              decorationColor: baseText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DoseStatusMark extends StatelessWidget {
  const _DoseStatusMark({required this.taken, required this.dimmed});
  final bool taken;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final Color takenColor = careblazersColors.success;
    final Color pendingColor = careblazersColors.primarySoft;
    if (taken) {
      return Icon(
        Icons.check_circle,
        size: 18,
        color: dimmed ? takenColor.withValues(alpha: 0.55) : takenColor,
      );
    }
    return Icon(
      Icons.radio_button_unchecked,
      size: 18,
      color: dimmed
          ? pendingColor.withValues(alpha: 0.55)
          : pendingColor,
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.event, required this.now});

  final CareEvent event;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final Color dot = recentActivityKindColor(event.kind);
    final bool past = event.start.isBefore(now);
    final String time = _formatClock(event.start);
    final String? route = event.detailRoute;
    final VoidCallback? onTap = route == null
        ? null
        : () => GoRouter.of(context).push(route);
    return InkWell(
      key: ScheduleCard.rowKey(event.id),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: past ? dot.withValues(alpha: 0.35) : dot,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 64,
              child: Text(
                time,
                style: tt.bodyMedium?.copyWith(
                  color: past
                      ? careblazersColors.text.withValues(alpha: 0.55)
                      : careblazersColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                event.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.bodyMedium?.copyWith(
                  color: past
                      ? careblazersColors.text.withValues(alpha: 0.55)
                      : careblazersColors.text,
                ),
              ),
            ),
            if (route != null)
              Icon(
                Icons.chevron_right,
                size: 18,
                color: careblazersColors.primarySoft,
              ),
          ],
        ),
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      key: ScheduleCard.skeletonKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SkeletonRow(),
        _SkeletonRow(),
        _SkeletonRow(),
      ],
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          _Block(width: 8, height: 8, radius: 4),
          SizedBox(width: 10),
          _Block(width: 56, height: 12, radius: 6),
          SizedBox(width: 8),
          Expanded(child: _Block(width: 0, height: 12, radius: 6)),
        ],
      ),
    );
  }
}

@immutable
class _Block extends StatelessWidget {
  const _Block({required this.width, required this.height, required this.radius});
  final double width;
  final double height;
  final double radius;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: width == 0 ? null : width,
      height: height,
      decoration: BoxDecoration(
        color: careblazersColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.emptyKey = false});
  final String text;
  final bool emptyKey;
  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Padding(
      key: emptyKey ? ScheduleCard.emptyKey : null,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: tt.bodyLarge?.copyWith(color: careblazersColors.text),
      ),
    );
  }
}

/// Three buckets keyed by [_bucket]. Each list is sorted ascending by
/// [CareEvent.start] in the same pass.
@immutable
class _Buckets {
  const _Buckets({
    required this.today,
    required this.tomorrow,
    required this.thisWeek,
  });

  final List<CareEvent> today;
  final List<CareEvent> tomorrow;
  final List<CareEvent> thisWeek;

  bool get isEmpty =>
      today.isEmpty && tomorrow.isEmpty && thisWeek.isEmpty;
}

/// Pure bucketer — pulled out so the day-window math is unit-testable
/// without a widget tree. The week ends Saturday relative to [now] —
/// matches the Team Calendar's Sun-anchored week so the two surfaces
/// agree on "this week". [events] is assumed already sorted ascending
/// by [CareEvent.start] (as [patientTimelineEvents] returns it); the
/// bucketer keeps that order within each list.
@visibleForTesting
({List<CareEvent> today, List<CareEvent> tomorrow, List<CareEvent> thisWeek})
    bucketSchedule(List<CareEvent> events, DateTime now) {
  final _Buckets b = _bucket(events, now);
  return (today: b.today, tomorrow: b.tomorrow, thisWeek: b.thisWeek);
}

_Buckets _bucket(List<CareEvent> events, DateTime now) {
  final DateTime startOfToday = DateTime(now.year, now.month, now.day);
  final DateTime startOfTomorrow =
      startOfToday.add(const Duration(days: 1));
  final DateTime startOfDayAfter =
      startOfTomorrow.add(const Duration(days: 1));
  // Saturday of the week containing today (Sun-anchored).
  final int weekdayFromSun = now.weekday % 7; // Sun=0, Mon=1, ..., Sat=6
  final DateTime endOfThisWeek = startOfToday
      .add(Duration(days: 7 - weekdayFromSun));
  final List<CareEvent> today = <CareEvent>[];
  final List<CareEvent> tomorrow = <CareEvent>[];
  final List<CareEvent> thisWeek = <CareEvent>[];
  for (final CareEvent e in events) {
    final DateTime s = e.start;
    if (s.isBefore(startOfToday)) continue;
    if (s.isBefore(startOfTomorrow)) {
      today.add(e);
    } else if (s.isBefore(startOfDayAfter)) {
      tomorrow.add(e);
    } else if (s.isBefore(endOfThisWeek)) {
      thisWeek.add(e);
    }
  }
  return _Buckets(today: today, tomorrow: tomorrow, thisWeek: thisWeek);
}

String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}
