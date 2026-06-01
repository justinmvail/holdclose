import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/medication.dart';
import '../../services/medication_repository.dart';
import '../../theme.dart';
// The status-dot hues are reused verbatim from the Home "Medications
// Today" card so the same dose reads with the same color on both
// surfaces — teal "given", amber "due", coral "needs attention".
import '../../widgets/home/medications_today_card.dart'
    show MedicationsTodayCard;
import '../../widgets/path_header.dart';
// Reuse the override-able wall clock the dose-log screen + Home card
// already sample "now" from, so day-selection and status comparison
// agree across every medication surface (and tests pin one clock).
import '../medication/dose_log_screen.dart' show doseLogClockProvider;

part 'med_schedule_screen.g.dart';

/// Every scheduled dose on the local-calendar day of [day], joined with
/// its [DoseLog] if the caregiver has acted (TASKS.md Phase 14.20).
///
/// A family keyed on the *normalized* day ([MedScheduleScreen] only ever
/// passes a `DateTime(y, m, d)` midnight) so cycling `‹ Yesterday` /
/// `Tomorrow ›` re-queries against a stable key — [DateTime] is a value
/// type, so the same calendar day reuses the cached future instead of
/// re-running on every rebuild.
@riverpod
Future<List<ScheduledDose>> dosesForDay(Ref ref, DateTime day) async {
  final MedicationRepository repo =
      ref.watch(medicationRepositoryBackendProvider);
  return repo.dosesByDay(day);
}

/// Med Schedule screen at `/medical/schedule` (TASKS.md Phase 14.20,
/// BUILD_SPEC.md §5.13).
///
/// A [PathHeader] (`Home › Medical › Med Schedule`, back to Medical) sits
/// above a day-cycle row (`‹ Yesterday` / `Tomorrow ›` chips around the
/// displayed day's label) and a vertical **24-hour timeline**. Each hour
/// mark carries a left-gutter time label; today's scheduled doses render
/// as markers anchored at their scheduled time, showing the medication
/// name, strength, and current status (taken / due / missed) in the same
/// dot colors as the Home dose card.
///
/// The timeline opens scrolled to **6 AM** (the typical first-dose hour)
/// so the morning routine is on screen without a scroll; the caregiver
/// can drag up to reach the midnight–6 AM stretch.
class MedScheduleScreen extends ConsumerStatefulWidget {
  const MedScheduleScreen({super.key});

  static const Key timelineKey = Key('med-schedule-timeline');
  static const Key prevDayKey = Key('med-schedule-prev-day');
  static const Key nextDayKey = Key('med-schedule-next-day');
  static const Key dayLabelKey = Key('med-schedule-day-label');
  static const Key emptyKey = Key('med-schedule-empty');
  static const Key nowLineKey = Key('med-schedule-now-line');

  /// Stable per-marker key derived from the (medicationId, scheduledFor)
  /// pair — schedule id alone collides when one med has two doses a day.
  static Key markerKey(String medicationId, DateTime scheduledFor) =>
      Key('med-schedule-marker-$medicationId-'
          '${scheduledFor.millisecondsSinceEpoch}');

  /// Pixel height of one hour on the timeline. Load-bearing for the
  /// marker-position contract: a marker's top edge sits at
  /// `minutesSinceMidnight / 60 * hourHeight`.
  static const double hourHeight = 64;

  /// Left gutter that holds the hour-mark time labels.
  static const double gutterWidth = 56;

  /// Vertical offset (from midnight) of a dose at [scheduledFor]. Pure so
  /// the marker-placement contract (±1px of the scheduled time) is
  /// unit-testable without a widget tree.
  static double offsetForTime(DateTime scheduledFor) =>
      (scheduledFor.hour * 60 + scheduledFor.minute) / 60.0 * hourHeight;

  @override
  ConsumerState<MedScheduleScreen> createState() => _MedScheduleScreenState();
}

class _MedScheduleScreenState extends ConsumerState<MedScheduleScreen> {
  /// Days from today the timeline is showing. 0 = today, -1 = yesterday,
  /// +1 = tomorrow, and so on.
  int _dayOffset = 0;

  DateTime _dayFor(DateTime now) {
    final DateTime today = DateTime(now.year, now.month, now.day);
    // Step the calendar via the constructor rather than Duration(days:)
    // so a DST transition doesn't slide the day by an hour.
    return DateTime(today.year, today.month, today.day + _dayOffset);
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = ref.watch(doseLogClockProvider)();
    final DateTime day = _dayFor(now);
    final AsyncValue<List<ScheduledDose>> async =
        ref.watch(dosesForDayProvider(day));

    return Scaffold(
      backgroundColor: careblazersColors.background,
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
                  PathHeaderCrumb(label: 'Med Schedule'),
                ],
                title: 'Med Schedule',
                backLabel: 'Back to Medical',
                leadingIcon: Icons.schedule_outlined,
              ),
            ),
            _DayCycleRow(
              label: _dayLabel(day, now),
              dateLabel: _dateLabel(day),
              onPrev: () => setState(() => _dayOffset--),
              onNext: () => setState(() => _dayOffset++),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (List<ScheduledDose> doses) => _Timeline(
                  doses: doses,
                  // The "now" line only belongs on the day that actually
                  // contains the current moment.
                  now: _dayOffset == 0 ? now : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `‹ Yesterday` / `Tomorrow ›` chips around the displayed day's label.
class _DayCycleRow extends StatelessWidget {
  const _DayCycleRow({
    required this.label,
    required this.dateLabel,
    required this.onPrev,
    required this.onNext,
  });

  final String label;
  final String dateLabel;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: <Widget>[
          _DayChip(
            buttonKey: MedScheduleScreen.prevDayKey,
            text: 'Yesterday',
            leading: true,
            onPressed: onPrev,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  key: MedScheduleScreen.dayLabelKey,
                  style: textTheme.titleLarge?.copyWith(
                    color: careblazersColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dateLabel,
                  style: textTheme.bodyMedium?.copyWith(
                    color: careblazersColors.primarySoft,
                  ),
                ),
              ],
            ),
          ),
          _DayChip(
            buttonKey: MedScheduleScreen.nextDayKey,
            text: 'Tomorrow',
            leading: false,
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.buttonKey,
    required this.text,
    required this.leading,
    required this.onPressed,
  });

  final Key buttonKey;
  final String text;

  /// When true the `‹` chevron renders before the word ("‹ Yesterday");
  /// otherwise after it ("Tomorrow ›").
  final bool leading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final TextStyle wordStyle = (textTheme.labelLarge ?? const TextStyle())
        .copyWith(color: careblazersColors.primary);
    final TextStyle chevronStyle =
        wordStyle.copyWith(color: careblazersColors.link);
    final Widget word = Text(text, style: wordStyle);
    final Widget chevron = Text(leading ? '‹' : '›', style: chevronStyle);

    return Semantics(
      button: true,
      label: leading ? 'Show the previous day' : 'Show the next day',
      child: TextButton(
        key: buttonKey,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: careblazersColors.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: leading
              ? <Widget>[chevron, const SizedBox(width: 4), word]
              : <Widget>[word, const SizedBox(width: 4), chevron],
        ),
      ),
    );
  }
}

/// The scrollable 24-hour timeline. Hour gridlines + left-gutter labels
/// fill a fixed-height stack; dose markers are absolutely positioned at
/// their scheduled time.
class _Timeline extends StatefulWidget {
  const _Timeline({required this.doses, required this.now});

  final List<ScheduledDose> doses;

  /// The current wall-clock moment when the displayed day is today, else
  /// null (no "now" line on other days).
  final DateTime? now;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  late final ScrollController _controller;

  /// Open scrolled to 6 AM — the typical first-dose hour — so the morning
  /// routine is on screen without a scroll.
  static const int _initialHour = 6;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(
      initialScrollOffset: _initialHour * MedScheduleScreen.hourHeight,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const double totalHeight = 24 * MedScheduleScreen.hourHeight;

    final List<Widget> layers = <Widget>[
      // Hour gridlines + gutter labels, one per hour mark (0..24).
      for (int hour = 0; hour <= 24; hour++)
        Positioned(
          top: hour * MedScheduleScreen.hourHeight,
          left: 0,
          right: 0,
          child: _HourMark(hour: hour),
        ),
      // Dose markers, anchored with their top edge at the scheduled time.
      for (final ScheduledDose dose in widget.doses)
        Positioned(
          top: MedScheduleScreen.offsetForTime(dose.scheduledFor),
          left: MedScheduleScreen.gutterWidth,
          right: 12,
          child: _DoseMarker(
            key: MedScheduleScreen.markerKey(
                dose.medication.id, dose.scheduledFor),
            dose: dose,
            now: widget.now,
          ),
        ),
      if (widget.now != null)
        Positioned(
          top: MedScheduleScreen.offsetForTime(widget.now!),
          left: 0,
          right: 0,
          child: const _NowLine(),
        ),
    ];

    return Stack(
      children: <Widget>[
        SingleChildScrollView(
          key: MedScheduleScreen.timelineKey,
          controller: _controller,
          child: SizedBox(
            height: totalHeight,
            child: Stack(children: layers),
          ),
        ),
        if (widget.doses.isEmpty) const _EmptyOverlay(),
      ],
    );
  }
}

class _HourMark extends StatelessWidget {
  const _HourMark({required this.hour});

  final int hour;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: MedScheduleScreen.gutterWidth,
          child: Padding(
            // Nudge the label up so it straddles the gridline it labels.
            padding: const EdgeInsets.only(right: 8, top: 0),
            child: Text(
              _hourLabel(hour),
              textAlign: TextAlign.right,
              style: textTheme.bodyMedium?.copyWith(
                color: careblazersColors.primarySoft,
                fontSize: 12,
              ),
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            margin: const EdgeInsets.only(top: 8),
            color: careblazersColors.primary.withValues(alpha: 0.08),
          ),
        ),
      ],
    );
  }
}

/// One dose marker — status dot + medication name + strength + the
/// one-word status string, on a warm card.
class _DoseMarker extends StatelessWidget {
  const _DoseMarker({super.key, required this.dose, required this.now});

  final ScheduledDose dose;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Medication med = dose.medication;
    final _MarkerState state = _resolveMarker(dose, now);
    final Color statusColor = _markerColor(state);
    final String statusLabel = _markerLabel(state);
    final String clock = _formatClock(dose.scheduledFor);

    return Semantics(
      container: true,
      label: '$clock, ${med.name}, ${med.dosage}. $statusLabel.',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: Material(
            color: careblazersColors.surfaceWarm,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text: med.name,
                            style: textTheme.bodyLarge?.copyWith(
                              color: careblazersColors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          TextSpan(
                            text: '  ${med.dosage}',
                            style: textTheme.bodyMedium?.copyWith(
                              color: careblazersColors.text,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    statusLabel,
                    style: textTheme.bodyMedium?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
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

class _NowLine extends StatelessWidget {
  const _NowLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      key: MedScheduleScreen.nowLineKey,
      children: <Widget>[
        const SizedBox(width: MedScheduleScreen.gutterWidth - 8),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: careblazersColors.cta,
            shape: BoxShape.circle,
          ),
        ),
        Expanded(
          child: Container(height: 2, color: careblazersColors.cta),
        ),
      ],
    );
  }
}

class _EmptyOverlay extends StatelessWidget {
  const _EmptyOverlay();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return IgnorePointer(
      child: Center(
        child: Container(
          key: MedScheduleScreen.emptyKey,
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: careblazersColors.background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: careblazersColors.primary.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            'No doses scheduled for this day.',
            textAlign: TextAlign.center,
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
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
          "We couldn't load the schedule.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status resolution — mirrors the Home "Medications Today" card so the same
// dose reads with the same dot color on both surfaces.
// ---------------------------------------------------------------------------

/// The mutually exclusive states a marker can be in. [taken] / [due] /
/// [missed] are the three named statuses from the phase spec; [skipped]
/// (a deliberate hold) renders muted, like the Home card.
enum _MarkerState { taken, due, missed, skipped }

_MarkerState _resolveMarker(ScheduledDose dose, DateTime? now) {
  final DoseLog? log = dose.log;
  if (log != null) {
    switch (log.status) {
      case DoseStatus.taken:
      case DoseStatus.late:
        return _MarkerState.taken;
      case DoseStatus.skipped:
        return _MarkerState.skipped;
      case DoseStatus.missed:
        return _MarkerState.missed;
    }
  }
  // No log yet: a dose whose time has passed (only meaningful on a day
  // with a "now" reference) reads as missed; otherwise it's still due.
  if (now != null && now.isAfter(dose.scheduledFor)) {
    return _MarkerState.missed;
  }
  return _MarkerState.due;
}

Color _markerColor(_MarkerState state) {
  switch (state) {
    case _MarkerState.taken:
      return MedicationsTodayCard.takenColor;
    case _MarkerState.due:
      return MedicationsTodayCard.dueSoonColor;
    case _MarkerState.missed:
      return MedicationsTodayCard.overdueColor;
    case _MarkerState.skipped:
      return careblazersColors.primarySoft;
  }
}

String _markerLabel(_MarkerState state) {
  switch (state) {
    case _MarkerState.taken:
      return 'Taken';
    case _MarkerState.due:
      return 'Due';
    case _MarkerState.missed:
      return 'Missed';
    case _MarkerState.skipped:
      return 'Skipped';
  }
}

/// The status string a marker shows for [dose] at [now]. Exposed for unit
/// tests of the taken / due / missed resolution.
@visibleForTesting
String medScheduleMarkerStatus(ScheduledDose dose, DateTime? now) =>
    _markerLabel(_resolveMarker(dose, now));

/// The status-dot color a marker paints for [dose] at [now]. Exposed so
/// tests can assert the teal / amber / coral mapping.
@visibleForTesting
Color medScheduleMarkerColor(ScheduledDose dose, DateTime? now) =>
    _markerColor(_resolveMarker(dose, now));

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

const List<String> _monthsShort = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const List<String> _weekdaysShort = <String>[
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
];

/// "Today" / "Yesterday" / "Tomorrow" for the three nearest days,
/// otherwise the weekday name ("Saturday").
String _dayLabel(DateTime day, DateTime now) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  final int delta = day.difference(today).inDays;
  if (delta == 0) return 'Today';
  if (delta == -1) return 'Yesterday';
  if (delta == 1) return 'Tomorrow';
  return _weekdayLong(day.weekday);
}

/// "Sat, May 30" — the calendar date under the relative label.
String _dateLabel(DateTime day) =>
    '${_weekdaysShort[day.weekday - 1]}, '
    '${_monthsShort[day.month - 1]} ${day.day}';

String _weekdayLong(int weekday) {
  const List<String> names = <String>[
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday',
  ];
  return names[weekday - 1];
}

/// Left-gutter label for an hour mark: "12 AM", "6 AM", "12 PM", "11 PM".
/// The 24th mark (end of day) reuses the midnight label.
String _hourLabel(int hour) {
  final int h = hour % 24;
  final int display = h % 12 == 0 ? 12 : h % 12;
  final String suffix = h < 12 ? 'AM' : 'PM';
  return '$display $suffix';
}

/// 12-hour clock — "8:00 AM", "9:05 PM". Mirrors the dose-log screen's
/// formatter so the medication surfaces read identically.
String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}
