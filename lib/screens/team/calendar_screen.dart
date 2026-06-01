import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_event.dart';
import '../../providers/care_events_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Care Team → Calendar at `/team/calendar` (TASKS.md Phase 14.29,
/// BUILD_SPEC.md §5.14).
///
/// A 7-day week view: a [PathHeader] (`Home › Care Team › Calendar`, back
/// to Care Team) with week-cycling arrows, a day-of-week header row, and a
/// scrollable 7-column × 24-hour grid. Each [CareEvent] renders as a
/// colored block positioned by its start time and sized by its duration;
/// the color encodes the [CareEventKind] (appointment / task / shift /
/// note). Tapping a block routes to the source detail
/// ([CareEventX.detailRoute]).
///
/// The four event sources are unified by [careEventsProvider]; this screen
/// only watches the merged list and lays it out. The visible week is local
/// state — the arrows shift [_weekStart] by ±7 days — seeded from
/// [calendarClockProvider] so tests pin "now".
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  static const Key gridKey = Key('calendar-grid');
  static const Key prevWeekKey = Key('calendar-prev-week');
  static const Key nextWeekKey = Key('calendar-next-week');
  static const Key weekLabelKey = Key('calendar-week-label');

  /// Stable per-block key derived from the event id so tests tap a node
  /// rather than a copy string.
  static Key blockKey(String eventId) => Key('calendar-block-$eventId');

  /// Pixels per hour row — the grid is [_hoursPerDay] × this tall.
  static const double hourHeight = 44;

  /// Width of the left-hand hour-label gutter.
  static const double gutterWidth = 52;

  static const int _hoursPerDay = 24;
  static const int _daysPerWeek = 7;

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// Midnight on the Sunday that opens the visible week. Seeded lazily on
  /// the first build from [calendarClockProvider].
  DateTime? _weekStart;

  DateTime get _week => _weekStart ??= weekStartFor(
        ref.read(calendarClockProvider)(),
      );

  void _shiftWeek(int weeks) {
    setState(() {
      _weekStart = _week.add(Duration(days: CalendarScreen._daysPerWeek * weeks));
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CareEvent>> async = ref.watch(careEventsProvider);
    final DateTime weekStart = _week;
    final DateTime today = dateOnly(ref.watch(calendarClockProvider)());

    return Scaffold(
      backgroundColor: careblazersColors.background,
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
                      PathHeaderCrumb(label: 'Care Team', route: '/team'),
                      PathHeaderCrumb(label: 'Calendar'),
                    ],
                    title: 'Calendar',
                    backLabel: 'Back to Care Team',
                    leadingIcon: Icons.calendar_view_week_outlined,
                  ),
                  const SizedBox(height: 8),
                  _WeekNav(
                    weekStart: weekStart,
                    onPrev: () => _shiftWeek(-1),
                    onNext: () => _shiftWeek(1),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _DayHeaderRow(weekStart: weekStart, today: today),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (List<CareEvent> events) => _WeekGrid(
                  weekStart: weekStart,
                  byDay: _bucketByDay(events, weekStart),
                  onTapEvent: (CareEvent event) => _openDetail(context, event),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context, CareEvent event) {
    final String? route = event.detailRoute;
    if (route != null) context.push(route);
  }
}

/// Group [events] into seven day-buckets relative to [weekStart]. Events
/// outside the visible Sun–Sat window are dropped.
List<List<CareEvent>> _bucketByDay(List<CareEvent> events, DateTime weekStart) {
  final List<List<CareEvent>> byDay = <List<CareEvent>>[
    for (int i = 0; i < CalendarScreen._daysPerWeek; i++) <CareEvent>[],
  ];
  for (final CareEvent event in events) {
    final int dayIndex = dateOnly(event.start).difference(weekStart).inDays;
    if (dayIndex >= 0 && dayIndex < CalendarScreen._daysPerWeek) {
      byDay[dayIndex].add(event);
    }
  }
  return byDay;
}

/// Week-cycling header: a previous-week arrow, the week label, a
/// next-week arrow.
class _WeekNav extends StatelessWidget {
  const _WeekNav({
    required this.weekStart,
    required this.onPrev,
    required this.onNext,
  });

  final DateTime weekStart;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Semantics(
          button: true,
          label: 'Previous week',
          child: IconButton(
            key: CalendarScreen.prevWeekKey,
            icon: const Icon(Icons.chevron_left),
            color: careblazersColors.link,
            onPressed: onPrev,
            tooltip: 'Previous week',
          ),
        ),
        Expanded(
          child: Text(
            _formatWeekLabel(weekStart),
            key: CalendarScreen.weekLabelKey,
            textAlign: TextAlign.center,
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Semantics(
          button: true,
          label: 'Next week',
          child: IconButton(
            key: CalendarScreen.nextWeekKey,
            icon: const Icon(Icons.chevron_right),
            color: careblazersColors.link,
            onPressed: onNext,
            tooltip: 'Next week',
          ),
        ),
      ],
    );
  }
}

/// The day-of-week header row: an empty gutter-width spacer aligned over
/// the hour gutter, then seven labeled day columns. Today's column is
/// accented.
class _DayHeaderRow extends StatelessWidget {
  const _DayHeaderRow({required this.weekStart, required this.today});

  final DateTime weekStart;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          const SizedBox(width: CalendarScreen.gutterWidth),
          for (int i = 0; i < CalendarScreen._daysPerWeek; i++)
            Expanded(
              child: Builder(
                builder: (BuildContext context) {
                  final DateTime day = weekStart.add(Duration(days: i));
                  final bool isToday = dateOnly(day) == today;
                  final Color color = isToday
                      ? careblazersColors.cta
                      : careblazersColors.primarySoft;
                  return Column(
                    children: <Widget>[
                      Text(
                        _weekdaysShort[day.weekday % 7],
                        style: textTheme.bodyMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${day.day}',
                        style: textTheme.bodyMedium?.copyWith(color: color),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// The scrollable body: a 24-hour gutter beside seven day columns, all
/// sharing one vertical scroll.
class _WeekGrid extends StatelessWidget {
  const _WeekGrid({
    required this.weekStart,
    required this.byDay,
    required this.onTapEvent,
  });

  final DateTime weekStart;
  final List<List<CareEvent>> byDay;
  final ValueChanged<CareEvent> onTapEvent;

  @override
  Widget build(BuildContext context) {
    const double totalHeight =
        CalendarScreen._hoursPerDay * CalendarScreen.hourHeight;
    return SingleChildScrollView(
      key: CalendarScreen.gridKey,
      child: SizedBox(
        height: totalHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _HourGutter(),
            for (int i = 0; i < CalendarScreen._daysPerWeek; i++)
              Expanded(
                child: _DayColumn(
                  events: byDay[i],
                  onTapEvent: onTapEvent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The left-hand hour labels — "12 AM", "1 AM" … one per hour row.
class _HourGutter extends StatelessWidget {
  const _HourGutter();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SizedBox(
      width: CalendarScreen.gutterWidth,
      child: Column(
        children: <Widget>[
          for (int h = 0; h < CalendarScreen._hoursPerDay; h++)
            SizedBox(
              height: CalendarScreen.hourHeight,
              child: Padding(
                padding: const EdgeInsets.only(right: 6, top: 2),
                child: Text(
                  _formatHour(h),
                  textAlign: TextAlign.right,
                  style: textTheme.bodyMedium?.copyWith(
                    color: careblazersColors.primarySoft,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One day's column: hour gridlines behind the day's positioned event
/// blocks.
class _DayColumn extends StatelessWidget {
  const _DayColumn({required this.events, required this.onTapEvent});

  final List<CareEvent> events;
  final ValueChanged<CareEvent> onTapEvent;

  @override
  Widget build(BuildContext context) {
    const double totalHeight =
        CalendarScreen._hoursPerDay * CalendarScreen.hourHeight;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: careblazersColors.surfaceWarm,
          ),
        ),
      ),
      child: SizedBox(
        height: totalHeight,
        child: Stack(
          children: <Widget>[
            for (int h = 0; h < CalendarScreen._hoursPerDay; h++)
              Positioned(
                top: h * CalendarScreen.hourHeight,
                left: 0,
                right: 0,
                child: Container(
                  height: 1,
                  color: careblazersColors.surfaceWarm,
                ),
              ),
            for (final CareEvent event in events)
              _positionedBlock(event),
          ],
        ),
      ),
    );
  }

  Widget _positionedBlock(CareEvent event) {
    final double top = (event.start.hour + event.start.minute / 60) *
        CalendarScreen.hourHeight;
    final double rawHeight =
        event.blockDuration.inMinutes / 60 * CalendarScreen.hourHeight;
    final double height = rawHeight < _minBlockHeight ? _minBlockHeight : rawHeight;
    return Positioned(
      top: top,
      left: 1,
      right: 1,
      height: height,
      child: _EventBlock(event: event, onTap: () => onTapEvent(event)),
    );
  }
}

/// A single colored event block. Color encodes the [CareEventKind]; the
/// whole block is the tap target.
class _EventBlock extends StatelessWidget {
  const _EventBlock({required this.event, required this.onTap});

  final CareEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color color = _kindColor(event.kind);
    return Semantics(
      button: true,
      label: '${event.title}, ${_kindLabel(event.kind)}. Double-tap to open.',
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: CalendarScreen.blockKey(event.id),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              event.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
          "We couldn't load the calendar.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Geometry + formatting helpers
// ---------------------------------------------------------------------------

const double _minBlockHeight = 20;

/// Block color per [CareEventKind] (BUILD_SPEC.md §5.14). The spec's
/// coral/teal/amber/plum placeholders map onto the four most-distinct
/// brand tokens (CLAUDE.md / docs/MENU_LAYOUT_SPEC.md discard the
/// placeholder color names in favour of the §3.1 palette): appointment →
/// `cta` (coral), task → `link` (the cool interactive accent, for teal),
/// shift → `success` (green, for amber), note → `accentDeep` (for plum).
Color _kindColor(CareEventKind kind) {
  switch (kind) {
    case CareEventKind.appointment:
      return careblazersColors.cta;
    case CareEventKind.task:
      return careblazersColors.link;
    case CareEventKind.shift:
      return careblazersColors.success;
    case CareEventKind.note:
      return careblazersColors.accentDeep;
  }
}

String _kindLabel(CareEventKind kind) {
  switch (kind) {
    case CareEventKind.appointment:
      return 'appointment';
    case CareEventKind.task:
      return 'task';
    case CareEventKind.shift:
      return 'shift';
    case CareEventKind.note:
      return 'note';
  }
}

/// Midnight on the same calendar day as [t] (strips the time-of-day).
DateTime dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

/// Midnight on the Sunday on or before [t] — the opening day of the week
/// the calendar shows (US-style Sunday-start week).
DateTime weekStartFor(DateTime t) {
  final DateTime day = dateOnly(t);
  // DateTime.weekday is Mon=1..Sun=7; `% 7` maps Sunday to 0 so the
  // subtraction lands on the most recent Sunday.
  return day.subtract(Duration(days: day.weekday % 7));
}

const List<String> _weekdaysShort = <String>[
  'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat',
];

const List<String> _monthsShort = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Jun 1 – 7" within a month, "May 31 – Jun 6" across one.
String _formatWeekLabel(DateTime weekStart) {
  final DateTime weekEnd = weekStart.add(const Duration(days: 6));
  final String startMonth = _monthsShort[weekStart.month - 1];
  if (weekStart.month == weekEnd.month) {
    return '$startMonth ${weekStart.day} – ${weekEnd.day}';
  }
  final String endMonth = _monthsShort[weekEnd.month - 1];
  return '$startMonth ${weekStart.day} – $endMonth ${weekEnd.day}';
}

/// "12 AM", "1 AM" … "12 PM" … "11 PM" for the gutter.
String _formatHour(int hour24) {
  final int rawHour = hour24 % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String suffix = hour24 < 12 ? 'AM' : 'PM';
  return '$hour $suffix';
}
