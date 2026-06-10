import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_event.dart';
import '../../providers/home_clock_provider.dart';
import '../../providers/patient_timeline_provider.dart';
import '../../theme.dart';
import '../schedule_grouping.dart';

/// The "Schedule" dashboard card — the caregiver's at-a-glance view of
/// what's happening with the patient **today** and **tomorrow**. Replaces
/// the single-row Next Appointment card so a 9am visit tomorrow can't hide
/// behind a noon dose today.
///
/// Reads [patientTimelineEventsProvider] (the same merged stream the
/// activity feed slices) and buckets by wall-clock day:
///   - **Today** — events with `start` between `[startOfToday, endOfToday]`
///     (past *and* future, so "I already gave 8am dose" stays visible).
///   - **Tomorrow** — events on the calendar day after today.
///
/// Events from the day after tomorrow onward are dropped — the caregiver
/// taps Calendar → for the wider view. Each row taps through to
/// [CareEventX.detailRoute]; the card header
/// taps to the Team Calendar so the caregiver can zoom out. Empty days
/// collapse — if today has nothing, the Today header doesn't render.
class ScheduleCard extends ConsumerWidget {
  const ScheduleCard({super.key});

  static const Key cardKey = Key('home-schedule-card');
  static const Key emptyKey = Key('home-schedule-empty');
  static const Key skeletonKey = Key('home-schedule-skeleton');
  static const Key todaySectionKey = Key('home-schedule-today');
  static const Key tomorrowSectionKey = Key('home-schedule-tomorrow');
  static const Key viewCalendarKey = Key('home-schedule-view-calendar');
  static const Key moreRowKey = Key('home-schedule-more');
  static Key rowKey(String eventId) => Key('home-schedule-row-$eventId');

  /// Maximum **rows** surfaced per section — a medication window counts as
  /// one row, so a window's meds are never split or dropped by the cap.
  /// The card stays glanceable; overflow rolls into a "+N more" link to
  /// /team/calendar. (Was a per-event cap of 5 today / 4 tomorrow, which
  /// truncated raw dose events *before* they grouped into windows — so a
  /// med past the cut vanished from a window and tomorrow's smaller limit
  /// dropped one the day still had.)
  static const int _maxRowsPerSection = 6;

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
                events: b.today,
                maxRows: _maxRowsPerSection,
                now: now,
              ),
            if (b.tomorrow.isNotEmpty) ...<Widget>[
              if (b.today.isNotEmpty) const SizedBox(height: 12),
              _Section(
                key: tomorrowSectionKey,
                label: 'Tomorrow',
                events: b.tomorrow,
                maxRows: _maxRowsPerSection,
                now: now,
              ),
            ],
          ],
        );
      },
    );

    return Material(
      color: context.cb.surfaceWarm,
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
            style: tt.titleLarge?.copyWith(color: context.cb.primary),
          ),
        ),
        TextButton(
          key: ScheduleCard.viewCalendarKey,
          onPressed: onTapCalendar,
          style: TextButton.styleFrom(
            foregroundColor: context.cb.link,
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
    required this.maxRows,
    required this.now,
  });

  final String label;
  final List<CareEvent> events;
  final int maxRows;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    // Fold a window's dose events into a single row headed by the window
    // name + time ("Morning · 8:00 AM") with the medications listed
    // beneath — caregivers asked to see the time window and which meds
    // are due then, instead of one row per dose.
    //
    // Group BEFORE capping so the cap counts rows (a window = one row), not
    // raw doses — otherwise a window's later meds get sliced off mid-window
    // and a med the day actually has just disappears.
    final List<ScheduleRow> allRows = groupDoseEventsByWindow(events);
    final List<ScheduleRow> rows =
        allRows.take(maxRows).toList(growable: false);
    final int hidden = allRows.length - rows.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Full-width tinted band behind the day label so Today and
        // Tomorrow read as distinct sections at a glance. Alpha feedback
        // (fb_1780960026009050) asked for a more prominent divide between
        // days — bumped the band's vertical padding (taller bar) and the
        // tint contrast a notch so the day boundary stands out.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: context.cb.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: tt.titleMedium?.copyWith(
              color: context.cb.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final ScheduleRow r in rows)
          r is DoseGroupRow
              ? _GroupedRow(model: r.group, now: now)
              : _Row(event: (r as EventRow).event, now: now),
        if (hidden > 0) _MoreRow(count: hidden),
      ],
    );
  }
}

/// Overflow affordance — when a section has more rows than the cap, this
/// rolls the remainder into a single tap-through to the full Calendar so
/// nothing is silently dropped.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return InkWell(
      key: ScheduleCard.moreRowKey,
      onTap: () => GoRouter.of(context).push('/team/calendar'),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          '+$count more in Calendar',
          style: tt.bodyMedium?.copyWith(
            color: context.cb.link,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _GroupedRow extends StatelessWidget {
  const _GroupedRow({required this.model, required this.now});

  final DoseWindowGroup model;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final bool past = model.start.isBefore(now);
    final String time = _formatClock(model.start);
    final Color baseText = past
        ? context.cb.text.withValues(alpha: 0.55)
        : context.cb.text;
    final Color labelColor = past
        ? context.cb.primary.withValues(alpha: 0.55)
        : context.cb.primary;
    final Color timeColor = past
        ? context.cb.primarySoft.withValues(alpha: 0.55)
        : context.cb.primarySoft;
    final String? label = model.windowLabel;
    // Only today's group taps through — the dose log shows TODAY's doses,
    // so a Tomorrow group has no matching destination and stays static
    // rather than misrouting to today's medications.
    final bool isToday = model.start.year == now.year &&
        model.start.month == now.month &&
        model.start.day == now.day;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      // Today's window group taps through to the dose log — the same
      // destination a single dose row routed to before the meds folded
      // into window groups.
      child: InkWell(
        key: ScheduleCard.rowKey(model.firstEventId),
        onTap: isToday
            ? () => GoRouter.of(context).push('/medications/today')
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Header: window name leads, time trails — "Morning · 8:00 AM"
              // — plus a chevron when the group taps through, matching a
              // single-event row (fb_1781045816196914).
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Text.rich(
                  label == null
                      ? TextSpan(
                          text: time,
                          style: tt.bodyMedium?.copyWith(
                            color: labelColor,
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              // "Medication" appended to the window name so a
                              // dose group reads unambiguously as meds among
                              // the appointments + other events the schedule
                              // mixes in — "Morning Medication" not "Morning".
                              text: '$label Medication',
                              style: tt.bodyMedium?.copyWith(
                                color: labelColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(
                              text: '  ·  $time',
                              style: tt.bodyMedium?.copyWith(
                                color: timeColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              if (isToday)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: context.cb.primarySoft,
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Each medication on its own row, indented under the header.
          // Checkmark = logged dose, hollow circle = still pending.
          for (final ({String name, bool taken}) m in model.meds)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
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
                        decoration:
                            m.taken ? TextDecoration.lineThrough : null,
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
    final Color takenColor = context.cb.success;
    final Color pendingColor = context.cb.primarySoft;
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
    final bool past = event.start.isBefore(now);
    final String time = _formatClock(event.start);
    final String? route = event.detailRoute;
    final VoidCallback? onTap = route == null
        ? null
        : () => GoRouter.of(context).push(route);
    // Same header format as a medication window — "Title  ·  Time", title
    // navy/bold + time soft/bold, no leading kind-dot — so every schedule
    // entry reads identically (fb_1781045816196914). A single event just
    // has no sub-rows beneath it.
    final Color labelColor = past
        ? context.cb.primary.withValues(alpha: 0.55)
        : context.cb.primary;
    final Color timeColor = past
        ? context.cb.primarySoft.withValues(alpha: 0.55)
        : context.cb.primarySoft;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        key: ScheduleCard.rowKey(event.id),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: event.title,
                        style: tt.bodyMedium?.copyWith(
                          color: labelColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(
                        text: '  ·  $time',
                        style: tt.bodyMedium?.copyWith(
                          color: timeColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: context.cb.primarySoft,
                ),
            ],
          ),
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
        color: context.cb.primary.withValues(alpha: 0.08),
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
        style: tt.bodyLarge?.copyWith(color: context.cb.text),
      ),
    );
  }
}

/// Two buckets keyed by [_bucket]. Each list is sorted ascending by
/// [CareEvent.start] in the same pass.
@immutable
class _Buckets {
  const _Buckets({
    required this.today,
    required this.tomorrow,
  });

  final List<CareEvent> today;
  final List<CareEvent> tomorrow;

  bool get isEmpty => today.isEmpty && tomorrow.isEmpty;
}

/// Pure bucketer — pulled out so the day-window math is unit-testable
/// without a widget tree. The card looks one day ahead: events from the
/// day after tomorrow onward are dropped (the caregiver taps Calendar →
/// for the wider view). [events] is assumed already sorted ascending by
/// [CareEvent.start] (as [patientTimelineEvents] returns it); the
/// bucketer keeps that order within each list.
@visibleForTesting
({List<CareEvent> today, List<CareEvent> tomorrow})
    bucketSchedule(List<CareEvent> events, DateTime now) {
  final _Buckets b = _bucket(events, now);
  return (today: b.today, tomorrow: b.tomorrow);
}

_Buckets _bucket(List<CareEvent> events, DateTime now) {
  final DateTime startOfToday = DateTime(now.year, now.month, now.day);
  final DateTime startOfTomorrow =
      startOfToday.add(const Duration(days: 1));
  final DateTime startOfDayAfter =
      startOfTomorrow.add(const Duration(days: 1));
  final List<CareEvent> today = <CareEvent>[];
  final List<CareEvent> tomorrow = <CareEvent>[];
  for (final CareEvent e in events) {
    final DateTime s = e.start;
    if (s.isBefore(startOfToday)) continue;
    if (s.isBefore(startOfTomorrow)) {
      today.add(e);
    } else if (s.isBefore(startOfDayAfter)) {
      tomorrow.add(e);
    }
  }
  return _Buckets(today: today, tomorrow: tomorrow);
}

String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}
