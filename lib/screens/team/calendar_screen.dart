import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_event.dart';
import '../../providers/care_events_provider.dart';
import '../../providers/patient_timeline_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Which audience's events the Calendar surfaces. [both] is the
/// default — what's happening with the patient AND who's covering when.
/// [patient] narrows to the dosing / appointments / journal /
/// health-log / routines stream; [team] narrows to the
/// appointment / task / shift / note coordination layer. Appointment
/// kind is in BOTH audiences so it never hides under either filter.
enum CalendarAudience { both, patient, team }

/// Care Team → Calendar at `/team/calendar` (TASKS.md Phase 14.29 v2,
/// BUILD_SPEC.md §5.14 v2).
///
/// **Shell v2 (week strip + agenda):** a [PathHeader]
/// (`Home › Care Team › Calendar`, back to Care Team), an audience
/// filter (Both / Patient / Team), a week-cycling header, a 7-day
/// strip with a selectable day, and a scrollable agenda of that day's
/// events as full-width cards. Replaces the legacy 7-col × 24-hour
/// grid — the grid forced a 12-point font and lost clarity the moment
/// a busy day had more than three events overlap.
///
/// Two streams feed the agenda: the team-coordination layer
/// ([careEventsProvider] — appointments / tasks / shifts / notes) and
/// the patient-care layer ([patientTimelineEventsProvider] — dosings,
/// journal entries, health-log entries, care-plan routines). They
/// merge, dedup by id (the appointment kind is in both audiences), and
/// the audience chip filter narrows on demand. Default is
/// [CalendarAudience.both].
///
/// The visible week + selected day are local state. The arrows shift
/// [_weekStart] by ±7 days and re-anchor the selected day to the new
/// week (defaulting to today if it falls in-week, else to Sunday).
/// Seeded from [calendarClockProvider] so tests pin "now".
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  /// The scrollable agenda body — kept for test continuity since the
  /// legacy 24-hour grid carried the same key.
  static const Key gridKey = Key('calendar-grid');
  static const Key prevWeekKey = Key('calendar-prev-week');
  static const Key nextWeekKey = Key('calendar-next-week');
  static const Key weekLabelKey = Key('calendar-week-label');
  static const Key audienceFilterKey = Key('calendar-audience-filter');
  static const Key emptyDayKey = Key('calendar-empty-day');

  /// Stable per-event key — present on the agenda row so tests tap a
  /// node rather than a copy string. Same naming the legacy grid used,
  /// so existing block-keyed assertions keep working.
  static Key blockKey(String eventId) => Key('calendar-block-$eventId');

  /// Stable per-day key on the week strip so tests tap a day by date
  /// rather than by ordinal position.
  static Key dayChipKey(DateTime day) =>
      Key('calendar-day-chip-${day.year}-${day.month}-${day.day}');

  static const int _daysPerWeek = 7;

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// Midnight on the Sunday that opens the visible week. Seeded lazily
  /// on the first build from [calendarClockProvider].
  DateTime? _weekStart;

  /// Midnight on the currently-selected day. Seeded lazily to "today"
  /// on first build; re-anchored on week shift.
  DateTime? _selectedDay;

  /// Active audience filter. Defaults to [CalendarAudience.both] so the
  /// caregiver sees the patient AND team event streams unless they
  /// narrow.
  CalendarAudience _audience = CalendarAudience.both;

  DateTime get _week => _weekStart ??= weekStartFor(
        ref.read(calendarClockProvider)(),
      );

  DateTime get _selected =>
      _selectedDay ??= dateOnly(ref.read(calendarClockProvider)());

  void _shiftWeek(int weeks) {
    setState(() {
      final DateTime nextWeek =
          _week.add(Duration(days: CalendarScreen._daysPerWeek * weeks));
      _weekStart = nextWeek;
      // Re-anchor the selected day: today if it falls in the new week,
      // else the new week's Sunday. Keeps the selection inside the
      // visible strip without making the caregiver re-tap.
      final DateTime today = dateOnly(ref.read(calendarClockProvider)());
      final int todayIndex = today.difference(nextWeek).inDays;
      _selectedDay = (todayIndex >= 0 &&
              todayIndex < CalendarScreen._daysPerWeek)
          ? today
          : nextWeek;
    });
  }

  void _selectDay(DateTime day) {
    setState(() => _selectedDay = dateOnly(day));
  }

  bool _matchesAudience(CareEvent e) {
    switch (_audience) {
      case CalendarAudience.both:
        return true;
      case CalendarAudience.patient:
        return e.isPatientScoped;
      case CalendarAudience.team:
        return e.isTeamScoped;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CareEvent>> teamAsync =
        ref.watch(careEventsProvider);
    final AsyncValue<List<CareEvent>> patientAsync =
        ref.watch(patientTimelineEventsProvider);
    final DateTime weekStart = _week;
    final DateTime selected = _selected;
    final DateTime today = dateOnly(ref.watch(calendarClockProvider)());

    // Merge team-scoped + patient-scoped streams + dedup by id (the
    // appointment kind is in both audiences and would otherwise appear
    // twice). Sort ascending by start to match the legacy contract.
    final AsyncValue<List<CareEvent>> async = _combine(
      teamAsync,
      patientAsync,
      filter: _matchesAudience,
    );

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  _AudienceFilter(
                    audience: _audience,
                    onChanged: (CalendarAudience next) =>
                        setState(() => _audience = next),
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
            _WeekStrip(
              weekStart: weekStart,
              today: today,
              selected: selected,
              onSelect: _selectDay,
            ),
            const Divider(height: 24),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (List<CareEvent> events) => _DayAgenda(
                  events: events
                      .where((CareEvent e) =>
                          dateOnly(e.start) == selected)
                      .toList(growable: false),
                  selected: selected,
                  onTapEvent: (CareEvent event) =>
                      _openDetail(context, event),
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

/// The 7-day strip: a horizontal row of tappable day chips for the
/// visible week. The selected day fills with the CTA color; today's
/// chip is outlined when not selected; the rest sit on a soft surface.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.weekStart,
    required this.today,
    required this.selected,
    required this.onSelect,
  });

  final DateTime weekStart;
  final DateTime today;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < CalendarScreen._daysPerWeek; i++)
            Expanded(
              child: _DayChip(
                day: weekStart.add(Duration(days: i)),
                isSelected:
                    dateOnly(weekStart.add(Duration(days: i))) == selected,
                isToday: dateOnly(weekStart.add(Duration(days: i))) == today,
                onTap: onSelect,
              ),
            ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.day,
    required this.isSelected,
    required this.isToday,
    required this.onTap,
  });

  final DateTime day;
  final bool isSelected;
  final bool isToday;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color fill = isSelected
        ? careblazersColors.cta
        : careblazersColors.surfaceWarm;
    final Color fg = isSelected
        ? Colors.white
        : (isToday ? careblazersColors.cta : careblazersColors.primary);
    final BoxBorder? border = (!isSelected && isToday)
        ? Border.all(color: careblazersColors.cta, width: 1.5)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: CalendarScreen.dayChipKey(day),
          onTap: () => onTap(day),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(12),
              border: border,
            ),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _weekdaysShort[day.weekday % 7],
                  style: textTheme.bodySmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${day.day}',
                  style: textTheme.titleMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The selected day's agenda — a vertical list of cards. Empty days
/// render a single-line placeholder so the area never feels broken.
class _DayAgenda extends StatelessWidget {
  const _DayAgenda({
    required this.events,
    required this.selected,
    required this.onTapEvent,
  });

  final List<CareEvent> events;
  final DateTime selected;
  final ValueChanged<CareEvent> onTapEvent;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return _EmptyDay(selected: selected);
    }
    return ListView.separated(
      key: CalendarScreen.gridKey,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: events.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int i) => _AgendaRow(
        event: events[i],
        onTap: () => onTapEvent(events[i]),
      ),
    );
  }
}

class _AgendaRow extends StatelessWidget {
  const _AgendaRow({required this.event, required this.onTap});

  final CareEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color color = _kindColor(event.kind);
    final String label = _kindLabel(event.kind);
    final String startClock = _formatClock(event.start);
    final DateTime? end = event.end;
    final String? endClock = end == null ? null : _formatClock(end);
    final String? tapHint = event.detailRoute == null
        ? null
        : 'Double-tap to open.';
    final String semanticLabel = <String>[
      event.title,
      label,
      end == null ? startClock : '$startClock to $endClock',
      if (tapHint != null) tapHint,
    ].join('. ');
    return Semantics(
      button: event.detailRoute != null,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Material(
          color: careblazersColors.surfaceWarm,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: CalendarScreen.blockKey(event.id),
            onTap: onTap,
            child: IntrinsicHeight(
              child: Row(
                children: <Widget>[
                  Container(
                    width: 6,
                    color: color,
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SizedBox(
                      width: 64,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            startClock,
                            style: textTheme.bodyMedium?.copyWith(
                              color: careblazersColors.text,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (endClock != null) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              endClock,
                              style: textTheme.bodySmall?.copyWith(
                                color: careblazersColors.primarySoft,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            event.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyLarge?.copyWith(
                              color: careblazersColors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            label,
                            style: textTheme.bodySmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (event.detailRoute != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        Icons.chevron_right,
                        color: careblazersColors.primarySoft,
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

class _EmptyDay extends StatelessWidget {
  const _EmptyDay({required this.selected});

  final DateTime selected;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: CalendarScreen.emptyDayKey,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Nothing scheduled.',
            style: textTheme.titleMedium?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatLongDate(selected),
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.text.withValues(alpha: 0.7),
            ),
          ),
        ],
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
// Formatting + color helpers
// ---------------------------------------------------------------------------

/// Block color per [CareEventKind] (BUILD_SPEC.md §5.14). The spec's
/// coral/teal/amber/plum placeholders map onto the four most-distinct
/// brand tokens (CLAUDE.md / docs/MENU_LAYOUT_SPEC.md discard the
/// placeholder color names in favour of the §3.1 palette): appointment →
/// `cta` (coral), task → `link` (the cool interactive accent, for teal),
/// shift → `success` (green, for amber), note → `accentDeep` (for plum).
/// Patient-scoped kinds map onto the Home Recent Activity hues so the
/// calendar and the home feed read the same.
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
    case CareEventKind.doseScheduled:
    case CareEventKind.doseLogged:
      return careblazersColors.link;
    case CareEventKind.healthLogEntry:
      return careblazersColors.primary;
    case CareEventKind.journalEntry:
      return careblazersColors.accentDeep;
    case CareEventKind.carePlanItem:
      return careblazersColors.success;
  }
}

String _kindLabel(CareEventKind kind) {
  switch (kind) {
    case CareEventKind.appointment:
      return 'Appointment';
    case CareEventKind.task:
      return 'Task';
    case CareEventKind.shift:
      return 'Shift';
    case CareEventKind.note:
      return 'Note';
    case CareEventKind.doseScheduled:
      return 'Dose';
    case CareEventKind.doseLogged:
      return 'Dose taken';
    case CareEventKind.healthLogEntry:
      return 'Health log';
    case CareEventKind.journalEntry:
      return 'Journal';
    case CareEventKind.carePlanItem:
      return 'Routine';
  }
}

const List<String> _weekdaysShort = <String>[
  'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat',
];

const List<String> _weekdaysLong = <String>[
  'Sunday', 'Monday', 'Tuesday', 'Wednesday',
  'Thursday', 'Friday', 'Saturday',
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

/// "Wed, Jun 3" — used as the empty-day subtitle.
String _formatLongDate(DateTime d) {
  final String weekday = _weekdaysLong[d.weekday % 7];
  final String month = _monthsShort[d.month - 1];
  return '$weekday, $month ${d.day}';
}

/// Strip the time-of-day off [d], leaving midnight in the local zone.
/// Used to compare two `DateTime`s by calendar day without snagging on
/// wall-clock minutes.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Midnight on the Sunday that opens the week containing [now]. Sunday
/// is `weekday == 7` in Dart's ISO numbering, which wraps to 0 in our
/// `_weekdaysShort` lookup — the math here treats Sun as day 0.
DateTime weekStartFor(DateTime now) {
  final DateTime today = dateOnly(now);
  final int sundayOffset = today.weekday % 7; // Sun=0, Mon=1, ..., Sat=6
  return today.subtract(Duration(days: sundayOffset));
}

/// "12 AM", "1:30 PM" — the agenda's time stripe.
String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  if (t.minute == 0) {
    return '$hour $suffix';
  }
  final String minute = t.minute.toString().padLeft(2, '0');
  return '$hour:$minute $suffix';
}

/// Merge two `AsyncValue<List<CareEvent>>` streams into one. Errors
/// propagate (team error wins; otherwise patient error); loading is
/// sticky until both have data. Once both are loaded, the lists are
/// concatenated, deduped by [CareEvent.id], filtered through [filter],
/// and sorted ascending by [CareEvent.start].
AsyncValue<List<CareEvent>> _combine(
  AsyncValue<List<CareEvent>> a,
  AsyncValue<List<CareEvent>> b, {
  required bool Function(CareEvent) filter,
}) {
  if (a.hasError) {
    return AsyncValue<List<CareEvent>>.error(a.error!, a.stackTrace!);
  }
  if (b.hasError) {
    return AsyncValue<List<CareEvent>>.error(b.error!, b.stackTrace!);
  }
  final List<CareEvent>? aList = a.asData?.value;
  final List<CareEvent>? bList = b.asData?.value;
  if (aList == null || bList == null) {
    return const AsyncValue<List<CareEvent>>.loading();
  }
  final Map<String, CareEvent> byId = <String, CareEvent>{};
  for (final CareEvent e in <CareEvent>[...aList, ...bList]) {
    if (!filter(e)) continue;
    byId[e.id] = e;
  }
  final List<CareEvent> merged = byId.values.toList()
    ..sort((CareEvent x, CareEvent y) => x.start.compareTo(y.start));
  return AsyncValue<List<CareEvent>>.data(merged);
}

/// Segmented filter row: Both | Patient | Team. Lives under the
/// PathHeader so the caregiver can narrow without scrolling.
class _AudienceFilter extends StatelessWidget {
  const _AudienceFilter({required this.audience, required this.onChanged});

  final CalendarAudience audience;
  final ValueChanged<CalendarAudience> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<CalendarAudience>(
        key: CalendarScreen.audienceFilterKey,
        segments: const <ButtonSegment<CalendarAudience>>[
          ButtonSegment<CalendarAudience>(
            value: CalendarAudience.both,
            label: Text('Both'),
            icon: Icon(Icons.merge_type),
          ),
          ButtonSegment<CalendarAudience>(
            value: CalendarAudience.patient,
            label: Text('Patient'),
            icon: Icon(Icons.favorite_outline),
          ),
          ButtonSegment<CalendarAudience>(
            value: CalendarAudience.team,
            label: Text('Team'),
            icon: Icon(Icons.groups_outlined),
          ),
        ],
        selected: <CalendarAudience>{audience},
        onSelectionChanged: (Set<CalendarAudience> next) {
          if (next.isEmpty) return;
          onChanged(next.first);
        },
        showSelectedIcon: false,
      ),
    );
  }
}
