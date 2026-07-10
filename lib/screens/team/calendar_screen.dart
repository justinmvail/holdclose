import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_event.dart';
import '../../models/caregiver.dart';
import '../../providers/care_events_provider.dart';
import '../../providers/care_tasks_provider.dart'
    show assignableCaregiversProvider;
import '../../providers/patient_timeline_provider.dart';
import '../../theme.dart';
import '../appointment/appointment_list_screen.dart' show appointmentAddDebounce;
import '../../widgets/form/form_error_view.dart';
import '../../widgets/form/format.dart';
import '../../widgets/path_header.dart';
import '../../widgets/schedule_grouping.dart';

/// Care Circle → Calendar at `/team/calendar` (TASKS.md Phase 14.29 v2,
/// BUILD_SPEC.md §5.14 v2).
///
/// **Shell v2 (week strip + agenda):** a [PathHeader]
/// (`Home › Care Circle › Calendar`, back to Care Circle), an audience
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
/// The three ways the Schedule can be read, toggled by the in-page
/// [SegmentedButton] (Cheyne: "multiple views… like what's coming up next
/// week"). All three honour the owner ("who does what") filter.
///   - [week] — the 7-day strip plus a by-day grouped agenda of every event
///     in the visible week (date-headed), so the whole week reads at a
///     glance rather than just the selected day.
///   - [day] — only the selected day, as a vertical agenda. The week
///     strip stays so the caregiver can still hop days.
///   - [upcoming] — a flat chronological list of the next 30 days of
///     events, date-headed, so "what's coming up" is one glance.
enum CalendarView { day, week, upcoming }

/// The visible window the [CalendarView.upcoming] agenda spans, starting
/// at today. 30 days so "what's coming up" is genuinely useful and reaches
/// well past the visible week (alpha report fb_1780960227608706: "Upcoming
/// only goes one day past week"). The patient-timeline forecast source
/// projects the same horizon so permanent meds populate the whole span.
const int _upcomingHorizonDays = 30;

/// The visible week + selected day are local state. The arrows shift
/// [_weekStart] by ±7 days and re-anchor the selected day to the new
/// week (defaulting to today if it falls in-week, else to Sunday).
/// Seeded from [calendarClockProvider] so tests pin "now".
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({
    super.key,
    this.fromMedical = false,
    this.initialDate,
  });

  /// When true (the Medical hub's "Schedule" entry passes `?from=medical`,
  /// lifted to this flag by the route builder), the path header shows the
  /// Medical breadcrumb + back label instead of the Care Circle path — the
  /// same calendar screen with contextual chrome.
  final bool fromMedical;

  /// When set (the chat coach's "take me to that day" navigation passes
  /// `?date=YYYY-MM-DD`, lifted here by the route builder), the calendar
  /// opens on this day's week with it selected, instead of defaulting to
  /// today.
  final DateTime? initialDate;

  /// The scrollable agenda body — kept for test continuity since the
  /// legacy 24-hour grid carried the same key.
  static const Key gridKey = Key('calendar-grid');
  static const Key prevWeekKey = Key('calendar-prev-week');
  static const Key nextWeekKey = Key('calendar-next-week');
  static const Key weekLabelKey = Key('calendar-week-label');
  static const Key audienceFilterKey = Key('calendar-audience-filter');
  static const Key emptyDayKey = Key('calendar-empty-day');

  /// The "+ Add appointment" affordance — opens the appointment form on
  /// the selected day. The add gap Cheyne flagged ("how do I schedule
  /// appointments on the calendar?").
  static const Key addFabKey = Key('calendar-add-fab');

  /// The Day / Week / Upcoming view switcher.
  static const Key viewSwitcherKey = Key('calendar-view-switcher');

  /// The flat next-30-days agenda body in the Upcoming view.
  static const Key upcomingListKey = Key('calendar-upcoming-list');
  static const Key upcomingEmptyKey = Key('calendar-upcoming-empty');

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

  /// Active "who" filter — null shows everyone's schedule; a caregiver id
  /// narrows to that person's assignments (plus the loved one's unassigned
  /// care, which belongs to no one in particular). Answers "what am I on
  /// the hook for?" / "who's doing what?" — the schedule's real job.
  String? _ownerFilter;

  /// The active view. Local state — persists for the life of the screen,
  /// no settings-model change (so no codegen). Defaults to the legacy
  /// Week view.
  CalendarView _view = CalendarView.week;

  DateTime get _week => _weekStart ??= weekStartFor(
        widget.initialDate ?? ref.read(calendarClockProvider)(),
      );

  DateTime get _selected => _selectedDay ??=
      dateOnly(widget.initialDate ?? ref.read(calendarClockProvider)());

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

  bool _matchesOwner(CareEvent e) {
    // "Everyone" → the whole schedule.
    if (_ownerFilter == null) return true;
    // A person → their own assignments + the loved one's unassigned care
    // (meds / appointments belong to no single caregiver); other people's
    // assigned tasks + shifts drop away.
    return e.ownerCaregiverId == _ownerFilter || e.ownerCaregiverId == null;
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
      filter: _matchesOwner,
    );

    // The Day + Week views both anchor on the selected day and keep the
    // week-cycling header (arrows + week label). The Upcoming view is a flat
    // horizon list, so it drops the header.
    final bool showsWeekNav = _view != CalendarView.upcoming;
    // The day-of-week chip strip only does anything in Day view (it picks
    // which single day the agenda shows). In Week view every day already
    // renders, so the strip was inert — tapping a chip changed nothing
    // (alpha report fb_1780960170044232: "Day selector doesn't do anything
    // on week setting"). Hide it outside Day view.
    final bool showsDayStrip = _view == CalendarView.day;

    return Scaffold(
      backgroundColor: context.hc.background,
      floatingActionButton: _AddAppointmentFab(
        onPressed: () => _openAddForm(context, selected, today),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // One schedule now, always under Care (the Medical/Team
                  // calendar duality is gone). [widget.fromMedical] is kept
                  // for route compatibility but no longer changes chrome.
                  const PathHeader(
                    breadcrumbs: <PathHeaderCrumb>[
                      PathHeaderCrumb(label: 'Home', route: '/'),
                      PathHeaderCrumb(label: 'Care', route: '/medical'),
                      PathHeaderCrumb(label: 'Schedule'),
                    ],
                    title: 'Schedule',
                    backLabel: 'Back to Care',
                    leadingIcon: Icons.schedule_outlined,
                  ),
                  const SizedBox(height: 8),
                  _ViewSwitcher(
                    view: _view,
                    onChanged: (CalendarView next) =>
                        setState(() => _view = next),
                  ),
                  const SizedBox(height: 8),
                  _OwnerFilter(
                    selectedId: _ownerFilter,
                    onChanged: (String? id) =>
                        setState(() => _ownerFilter = id),
                  ),
                  if (showsWeekNav) ...<Widget>[
                    const SizedBox(height: 8),
                    _WeekNav(
                      weekStart: weekStart,
                      onPrev: () => _shiftWeek(-1),
                      onNext: () => _shiftWeek(1),
                    ),
                  ],
                ],
              ),
            ),
            if (showsDayStrip) ...<Widget>[
              const SizedBox(height: 8),
              _WeekStrip(
                weekStart: weekStart,
                today: today,
                selected: selected,
                onSelect: _selectDay,
              ),
            ],
            const Divider(height: 24),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => FormErrorView(
                    message: "We couldn't load the calendar.\n$e"),
                data: (List<CareEvent> events) =>
                    _body(context, events, selected, today),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The view-specific body.
  ///   - [day] — only the selected day, as a vertical agenda.
  ///   - [week] — every event in the 7-day week containing the selected day,
  ///     grouped by day under date headers (so it's clearly more than one
  ///     day — the fix for "Day and Week look the same").
  ///   - [upcoming] — a flat horizon list of the next 30 days.
  Widget _body(
    BuildContext context,
    List<CareEvent> events,
    DateTime selected,
    DateTime today,
  ) {
    switch (_view) {
      case CalendarView.day:
        return _DayAgenda(
          events: events
              .where((CareEvent e) => dateOnly(e.start) == selected)
              .toList(growable: false),
          selected: selected,
          today: today,
          onTapEvent: (CareEvent event) => _openDetail(context, event),
        );
      case CalendarView.week:
        // The whole week CONTAINING the selected day (its Sunday + 6 days),
        // grouped by day so the caregiver sees the week at a glance — not
        // just the one selected day. Bounds are derived from the same
        // `selected` Day view anchors on, so Day and Week clip the (now
        // 30-day) forecast source identically — Day to one day, Week to the
        // seven days around it. A permanent med can't leak past either
        // window (alpha report fb_1780960326057462: Day/Week "going forever"
        // and "ending at different times").
        final DateTime weekStart = weekStartFor(selected);
        final DateTime weekEnd =
            weekStart.add(const Duration(days: CalendarScreen._daysPerWeek));
        return _GroupedAgenda(
          key: const Key('calendar-week-agenda'),
          events: events
              .where((CareEvent e) {
                final DateTime day = dateOnly(e.start);
                return !day.isBefore(weekStart) && day.isBefore(weekEnd);
              })
              .toList(growable: false),
          today: today,
          listKey: CalendarScreen.gridKey,
          emptyKey: CalendarScreen.emptyDayKey,
          emptyTitle: 'Nothing scheduled this week.',
          emptySubtitle: 'The week of ${_formatWeekLabel(weekStart)} is clear.',
          onTapEvent: (CareEvent event) => _openDetail(context, event),
        );
      case CalendarView.upcoming:
        final DateTime horizonEnd =
            today.add(const Duration(days: _upcomingHorizonDays));
        return _GroupedAgenda(
          events: events
              .where((CareEvent e) {
                final DateTime day = dateOnly(e.start);
                return !day.isBefore(today) && day.isBefore(horizonEnd);
              })
              .toList(growable: false),
          today: today,
          listKey: CalendarScreen.upcomingListKey,
          emptyKey: CalendarScreen.upcomingEmptyKey,
          emptyTitle: 'Nothing coming up.',
          emptySubtitle: 'The next 30 days are clear.',
          onTapEvent: (CareEvent event) => _openDetail(context, event),
        );
    }
  }

  /// Open the appointment form pre-anchored to the day the caregiver is
  /// looking at. In the Upcoming view there's no single selected day, so
  /// default to today.
  void _openAddForm(BuildContext context, DateTime selected, DateTime today) {
    // Guard against a fast double-tap on the FAB pushing the add form
    // twice (which let the caregiver save two identical appointments —
    // alpha bug: "got added twice", 2026-06-07). The shared time-based
    // debounce drops a same-frame second tap; `isCurrent` covers the
    // slower case where the first form is already on screen.
    if (!appointmentAddDebounce.shouldOpen()) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final DateTime day = _view == CalendarView.upcoming ? today : selected;
    final String date = '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    context.push('/appointments/new?date=$date');
  }

  void _openDetail(BuildContext context, CareEvent event) {
    final String? route = event.detailRoute;
    if (route != null) context.push(route);
  }
}

/// The Day / Week / Upcoming view toggle (Cheyne: "multiple views… like
/// what's coming up next week"). A [SegmentedButton] so the active view
/// reads at a glance and the brand CTA color fills the selection.
class _ViewSwitcher extends StatelessWidget {
  const _ViewSwitcher({required this.view, required this.onChanged});

  final CalendarView view;
  final ValueChanged<CalendarView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<CalendarView>(
        key: CalendarScreen.viewSwitcherKey,
        segments: const <ButtonSegment<CalendarView>>[
          ButtonSegment<CalendarView>(
            value: CalendarView.day,
            label: Text('Day', maxLines: 1, softWrap: false),
            icon: Icon(Icons.view_day_outlined),
          ),
          ButtonSegment<CalendarView>(
            value: CalendarView.week,
            label: Text('Week', maxLines: 1, softWrap: false),
            icon: Icon(Icons.view_week_outlined),
          ),
          ButtonSegment<CalendarView>(
            value: CalendarView.upcoming,
            label: Text('Upcoming', maxLines: 1, softWrap: false),
            icon: Icon(Icons.list_alt_outlined),
          ),
        ],
        selected: <CalendarView>{view},
        showSelectedIcon: false,
        onSelectionChanged: (Set<CalendarView> next) =>
            onChanged(next.first),
        // Compact treatment mirrors Settings' `_compactSegmentStyle`:
        // tighter padding + a smaller label so "Upcoming" fits on one line
        // (alpha report fb_1780960095402023: "Upcoming has a weird word wrap
        // issue"). The brand fg/bg fills layer on top.
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          ),
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) =>
                states.contains(WidgetState.selected)
                    ? Colors.white
                    : context.hc.primary,
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) =>
                states.contains(WidgetState.selected)
                    ? context.hc.cta
                    : context.hc.surfaceWarm,
          ),
        ),
      ),
    );
  }
}

/// The "+ Add" affordance — opens the appointment form on the selected
/// day. Closes Cheyne's "how do I schedule appointments on the calendar?"
/// gap. No emoji on the label per the brand voice; the leading "+" is an
/// icon, not a primary-CTA emoji.
class _AddAppointmentFab extends StatelessWidget {
  const _AddAppointmentFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      key: CalendarScreen.addFabKey,
      heroTag: 'calendar-add-fab',
      onPressed: onPressed,
      backgroundColor: context.hc.ctaFilled,
      foregroundColor: Colors.white,
      icon: const Icon(Icons.add),
      label: const Text('Add appointment'),
    );
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
            color: context.hc.link,
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
              color: context.hc.primary,
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
            color: context.hc.link,
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
        ? context.hc.cta
        : context.hc.surfaceWarm;
    final Color fg = isSelected
        ? Colors.white
        : (isToday ? context.hc.cta : context.hc.primary);
    final BoxBorder? border = (!isSelected && isToday)
        ? Border.all(color: context.hc.cta, width: 1.5)
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
    required this.today,
    required this.onTapEvent,
  });

  final List<CareEvent> events;
  final DateTime selected;

  /// Midnight today — a dose window only taps through to the dose log
  /// when it's today's window (the log shows today's doses).
  final DateTime today;

  final ValueChanged<CareEvent> onTapEvent;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return _EmptyDay(selected: selected);
    }
    // Fold the day's medication doses into their time windows — the same
    // "Morning Medication · 8:00 AM" grouping the Home schedule uses — so
    // a window's meds list under one header instead of one row per dose.
    final List<ScheduleRow> rows = groupDoseEventsByWindow(events);
    return ListView.separated(
      key: CalendarScreen.gridKey,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int i) {
        final ScheduleRow r = rows[i];
        if (r is DoseGroupRow) {
          return _DoseWindowRow(group: r.group, today: today);
        }
        final CareEvent event = (r as EventRow).event;
        return _AgendaRow(event: event, onTap: () => onTapEvent(event));
      },
    );
  }
}

/// A by-day grouped agenda — the shared body of the Week and Upcoming
/// views. Events are grouped under a date header per day (so a multi-day
/// span like the week or the next two weeks reads top-down), with the same
/// dose-window folding the day agenda uses keeping meds compact. The owner
/// filter is already applied upstream (the events passed in are
/// pre-filtered + pre-sorted ascending by start). Keys + empty-state copy
/// are injected so the two callers keep their distinct test hooks and
/// "this week" / "next two weeks" wording.
class _GroupedAgenda extends StatelessWidget {
  const _GroupedAgenda({
    super.key,
    required this.events,
    required this.today,
    required this.listKey,
    required this.emptyKey,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.onTapEvent,
  });

  final List<CareEvent> events;
  final DateTime today;
  final Key listKey;
  final Key emptyKey;
  final String emptyTitle;
  final String emptySubtitle;
  final ValueChanged<CareEvent> onTapEvent;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    if (events.isEmpty) {
      return Padding(
        key: emptyKey,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              emptyTitle,
              style: textTheme.titleMedium?.copyWith(
                color: context.hc.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              emptySubtitle,
              style: textTheme.bodyMedium?.copyWith(
                color: context.hc.text.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    // Group the horizon's events by calendar day, preserving the ascending
    // order, then fold each day's doses into their windows.
    final List<DateTime> days = <DateTime>[];
    final Map<DateTime, List<CareEvent>> byDay = <DateTime, List<CareEvent>>{};
    for (final CareEvent e in events) {
      final DateTime day = dateOnly(e.start);
      (byDay[day] ??= <CareEvent>[]).add(e);
      if (!days.contains(day)) days.add(day);
    }

    // Flatten into a single item list: a header per day followed by its
    // (window-folded) rows, so one ListView scrolls the whole horizon.
    final List<_UpcomingItem> items = <_UpcomingItem>[];
    for (final DateTime day in days) {
      items.add(_UpcomingHeaderItem(day));
      for (final ScheduleRow r in groupDoseEventsByWindow(byDay[day]!)) {
        items.add(_UpcomingRowItem(r));
      }
    }

    return ListView.separated(
      key: listKey,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int i) {
        final _UpcomingItem item = items[i];
        if (item is _UpcomingHeaderItem) {
          return Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 8, bottom: 2),
            child: Text(
              _formatUpcomingHeader(item.day, today),
              style: textTheme.titleMedium?.copyWith(
                color: context.hc.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
        }
        final ScheduleRow r = (item as _UpcomingRowItem).row;
        if (r is DoseGroupRow) {
          return _DoseWindowRow(group: r.group, today: today);
        }
        final CareEvent event = (r as EventRow).event;
        return _AgendaRow(event: event, onTap: () => onTapEvent(event));
      },
    );
  }
}

/// One row in the flattened Upcoming list — either a day header or a
/// (possibly dose-folded) event row.
sealed class _UpcomingItem {
  const _UpcomingItem();
}

class _UpcomingHeaderItem extends _UpcomingItem {
  const _UpcomingHeaderItem(this.day);
  final DateTime day;
}

class _UpcomingRowItem extends _UpcomingItem {
  const _UpcomingRowItem(this.row);
  final ScheduleRow row;
}

class _AgendaRow extends StatelessWidget {
  const _AgendaRow({required this.event, required this.onTap});

  final CareEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color color = _kindColor(context, event.kind);
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
          color: context.hc.surfaceWarm,
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
                              color: context.hc.text,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (endClock != null) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              endClock,
                              style: textTheme.bodySmall?.copyWith(
                                color: context.hc.primarySoft,
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
                              color: context.hc.primary,
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
                        color: context.hc.primarySoft,
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

/// A folded medication window in the agenda — the day's doses sharing one
/// window slot, headed "Morning Medication · 8:00 AM" with each med + its
/// taken/pending mark beneath. Mirrors the Home schedule's grouping
/// (`groupDoseEventsByWindow`). Today's window taps through to the dose
/// log; other days have no per-day destination and stay static.
class _DoseWindowRow extends StatelessWidget {
  const _DoseWindowRow({required this.group, required this.today});

  final DoseWindowGroup group;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color color = _kindColor(context, CareEventKind.doseScheduled);
    final String time = _formatClock(group.start);
    // "Morning Medication" so the window reads unambiguously as meds among
    // the appointments + other events the agenda mixes in. A label-less
    // legacy dose falls back to a bare "Medication".
    final String header = group.windowLabel == null
        ? 'Medication'
        : '${group.windowLabel} Medication';
    final bool isToday = dateOnly(group.start) == today;
    final String semanticLabel = <String>[
      header,
      time,
      for (final ({String name, bool taken}) m in group.meds)
        '${m.name} ${m.taken ? 'taken' : 'due'}',
      if (isToday) 'Double-tap to open today\'s medications.',
    ].join('. ');

    return Semantics(
      button: isToday,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Material(
          color: context.hc.surfaceWarm,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: CalendarScreen.blockKey(group.firstEventId),
            onTap: isToday
                ? () => GoRouter.of(context).push('/medications/today')
                : null,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(width: 6, color: color),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SizedBox(
                      width: 64,
                      child: Text(
                        time,
                        style: textTheme.bodyMedium?.copyWith(
                          color: context.hc.text,
                          fontWeight: FontWeight.w700,
                        ),
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
                            header,
                            style: textTheme.bodyLarge?.copyWith(
                              color: context.hc.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final ({String name, bool taken}) m
                              in group.meds)
                            Padding(
                              padding: const EdgeInsets.only(top: 2, bottom: 2),
                              child: Row(
                                children: <Widget>[
                                  _DoseMark(taken: m.taken),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      m.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodyMedium?.copyWith(
                                        color: context.hc.text,
                                        decoration: m.taken
                                            ? TextDecoration.lineThrough
                                            : null,
                                        decorationColor:
                                            context.hc.text,
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
                  if (isToday)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        Icons.chevron_right,
                        color: context.hc.primarySoft,
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

class _DoseMark extends StatelessWidget {
  const _DoseMark({required this.taken});

  final bool taken;

  @override
  Widget build(BuildContext context) {
    return Icon(
      taken ? Icons.check_circle : Icons.radio_button_unchecked,
      size: 18,
      color: taken ? context.hc.success : context.hc.primarySoft,
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
              color: context.hc.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatLongDate(selected),
            style: textTheme.bodyMedium?.copyWith(
              color: context.hc.text.withValues(alpha: 0.7),
            ),
          ),
        ],
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
Color _kindColor(BuildContext context, CareEventKind kind) {
  switch (kind) {
    case CareEventKind.appointment:
      return context.hc.cta;
    case CareEventKind.task:
      return context.hc.link;
    case CareEventKind.shift:
      return context.hc.success;
    case CareEventKind.note:
      return context.hc.accentDeep;
    case CareEventKind.doseScheduled:
    case CareEventKind.doseLogged:
      return context.hc.link;
    case CareEventKind.healthLogEntry:
      return context.hc.primary;
    case CareEventKind.journalEntry:
      return context.hc.accentDeep;
    case CareEventKind.carePlanItem:
      return context.hc.success;
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

/// "Jun 1 – 7" within a month, "May 31 – Jun 6" across one.
String _formatWeekLabel(DateTime weekStart) {
  final DateTime weekEnd = weekStart.add(const Duration(days: 6));
  final String startMonth = monthAbbreviations[weekStart.month - 1];
  if (weekStart.month == weekEnd.month) {
    return '$startMonth ${weekStart.day} – ${weekEnd.day}';
  }
  final String endMonth = monthAbbreviations[weekEnd.month - 1];
  return '$startMonth ${weekStart.day} – $endMonth ${weekEnd.day}';
}

/// "Wed, Jun 3" — used as the empty-day subtitle.
String _formatLongDate(DateTime d) {
  final String weekday = _weekdaysLong[d.weekday % 7];
  final String month = monthAbbreviations[d.month - 1];
  return '$weekday, $month ${d.day}';
}

/// The Upcoming view's per-day header. "Today" / "Tomorrow" for the two
/// nearest days so the soonest items read fastest, else "Wed, Jun 3".
String _formatUpcomingHeader(DateTime day, DateTime today) {
  final int delta = dateOnly(day).difference(today).inDays;
  if (delta == 0) return 'Today';
  if (delta == 1) return 'Tomorrow';
  return _formatLongDate(day);
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

/// Per-person filter row: "Everyone" + a chip per care-circle caregiver.
/// Selecting a person narrows the schedule to what THEY are on the hook for
/// (their assigned tasks / shifts) plus the loved one's unassigned care, so
/// the team can see who does what. Collapses to nothing when there's no
/// care circle yet — a lone "Everyone" chip would do nothing.
class _OwnerFilter extends ConsumerWidget {
  const _OwnerFilter({required this.selectedId, required this.onChanged});

  /// null = Everyone; otherwise a caregiver id.
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  /// Stable per-chip key for tests/goldens.
  static Key chipKey(String? id) => Key('calendar-owner-${id ?? 'everyone'}');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Caregiver> caregivers =
        ref.watch(assignableCaregiversProvider).asData?.value ??
            const <Caregiver>[];
    if (caregivers.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      key: CalendarScreen.audienceFilterKey,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          _chip(context, label: 'Everyone', id: null),
          for (final Caregiver c in caregivers) ...<Widget>[
            const SizedBox(width: 8),
            _chip(context, label: c.displayName, id: c.id),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, {required String label, required String? id}) {
    final bool selected = selectedId == id;
    return ChoiceChip(
      key: chipKey(id),
      label: Text(label),
      selected: selected,
      selectedColor: context.hc.primary,
      backgroundColor: context.hc.surfaceWarm,
      labelStyle: TextStyle(
        color: selected ? Colors.white : context.hc.text,
        fontWeight: FontWeight.w600,
      ),
      onSelected: (_) => onChanged(id),
    );
  }
}
