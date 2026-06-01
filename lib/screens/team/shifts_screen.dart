import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/care_shift.dart';
import '../../models/caregiver.dart';
import '../../providers/care_shifts_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'shifts_screen.g.dart';

/// Mints the unique id a new shift needs. Overridable for tests + the demo
/// tour so the minted ids are deterministic; same shape as the task /
/// invite / appointment id factories.
typedef ShiftIdFactory = String Function();

String _defaultShiftIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'shift-$ms-$rand';
}

/// Id factory the schedule sheet uses. Tests override this with a monotonic
/// counter so the minted ids are stable across runs.
@Riverpod(keepAlive: true)
ShiftIdFactory shiftIdFactory(Ref ref) => _defaultShiftIdFactory;

/// Per-caregiver band colors for the coverage bar (TASKS.md Phase 14.31).
/// Assigned by the caregiver's index in the week's roster so a caregiver
/// keeps one color across all seven days. Drawn from the brand tokens
/// (BUILD_SPEC.md §3.1) — the most visually distinct ones first.
final List<Color> _bandPalette = <Color>[
  careblazersColors.link,
  careblazersColors.success,
  careblazersColors.cta,
  careblazersColors.accentDeep,
  careblazersColors.primary,
  careblazersColors.primarySoft,
];

/// Care Team → Shifts at `/team/shifts` (TASKS.md Phase 14.31, BUILD_SPEC.md
/// §5.14).
///
/// A [PathHeader] (`Home › Care Team › Shifts`, back to Care Team) over a
/// 7-day strip starting today. Each day row lays the day's shifts onto a
/// 24-hour bar — a colored band per covering caregiver, red striped bands
/// where nobody's on — and captions it with the caregiver count and the
/// uncovered spans ("3 caregivers · 2h uncovered: 6am–8am"). The header FAB
/// opens a schedule sheet (caregiver picker + start + end + notes).
///
/// The strip comes from [shiftWeekProvider]; the screen watches it and
/// routes new shifts through the [CareShifts] notifier.
class ShiftsScreen extends ConsumerWidget {
  const ShiftsScreen({super.key});

  static const Key fabKey = Key('shifts-fab');
  static const Key listKey = Key('shifts-list');
  static const Key emptyStateKey = Key('shifts-empty');

  /// Stable per-day keys derived from the day index in the strip so tests
  /// + goldens target a node rather than a copy string.
  static Key dayRowKey(int dayIndex) => Key('shifts-day-$dayIndex');
  static Key barKey(int dayIndex) => Key('shifts-bar-$dayIndex');
  static Key captionKey(int dayIndex) => Key('shifts-caption-$dayIndex');

  // Schedule-shift sheet.
  static const Key scheduleSheetKey = Key('shifts-schedule-sheet');
  static const Key startButtonKey = Key('shifts-schedule-start');
  static const Key endButtonKey = Key('shifts-schedule-end');
  static const Key notesFieldKey = Key('shifts-schedule-notes');
  static const Key saveButtonKey = Key('shifts-schedule-save');
  static const Key caregiverErrorKey = Key('shifts-schedule-caregiver-error');
  static const Key timeErrorKey = Key('shifts-schedule-time-error');
  static Key caregiverOptionKey(String caregiverId) =>
      Key('shifts-schedule-caregiver-$caregiverId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DayCoverage>> async = ref.watch(shiftWeekProvider);
    final Map<String, Caregiver> caregivers = _caregiversById(ref);

    return Scaffold(
      backgroundColor: careblazersColors.background,
      floatingActionButton:
          _AddShiftFab(onPressed: () => _openScheduleSheet(context)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care Team', route: '/team'),
                  PathHeaderCrumb(label: 'Shifts'),
                ],
                title: 'Shifts',
                backLabel: 'Back to Care Team',
                leadingIcon: Icons.access_time_outlined,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (List<DayCoverage> days) => _WeekStrip(
                  days: days,
                  bandColors: _bandColorsFor(days),
                  caregivers: caregivers,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Resolve the roster into an id→caregiver map for band names. Falls back
  /// to an empty map while the roster is still loading (or in goldens that
  /// don't override it) — the bar then labels bands generically.
  Map<String, Caregiver> _caregiversById(WidgetRef ref) {
    final List<Caregiver> list =
        ref.watch(schedulableCaregiversProvider).asData?.value ??
            const <Caregiver>[];
    return <String, Caregiver>{for (final Caregiver c in list) c.id: c};
  }

  /// Assign each caregiver appearing anywhere in the week a stable band
  /// color, ordered by id so the mapping is deterministic across rebuilds.
  Map<String, Color> _bandColorsFor(List<DayCoverage> days) {
    final Set<String> ids = <String>{
      for (final DayCoverage d in days)
        for (final CareShift s in d.shifts) s.caregiverId,
    };
    final List<String> sorted = ids.toList()..sort();
    return <String, Color>{
      for (int i = 0; i < sorted.length; i++)
        sorted[i]: _bandPalette[i % _bandPalette.length],
    };
  }

  Future<void> _openScheduleSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: careblazersColors.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) => const _ScheduleShiftSheet(),
    );
  }
}

class _AddShiftFab extends StatelessWidget {
  const _AddShiftFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Schedule a shift. Open the new-shift form.',
      child: FloatingActionButton.extended(
        key: ShiftsScreen.fabKey,
        onPressed: onPressed,
        backgroundColor: careblazersColors.cta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Schedule shift',
          style: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

/// The scrollable 7-day strip — one row per day, today first.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.days,
    required this.bandColors,
    required this.caregivers,
  });

  final List<DayCoverage> days;
  final Map<String, Color> bandColors;
  final Map<String, Caregiver> caregivers;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) {
      return const _EmptyState();
    }
    return ListView(
      key: ShiftsScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: <Widget>[
        for (int i = 0; i < days.length; i++)
          _DayRow(
            dayIndex: i,
            coverage: days[i],
            isToday: i == 0,
            bandColors: bandColors,
            caregivers: caregivers,
          ),
      ],
    );
  }
}

/// One day: a label row, the 24-hour coverage bar, and the summary caption.
class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.dayIndex,
    required this.coverage,
    required this.isToday,
    required this.bandColors,
    required this.caregivers,
  });

  final int dayIndex;
  final DayCoverage coverage;
  final bool isToday;
  final Map<String, Color> bandColors;
  final Map<String, Caregiver> caregivers;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color labelColor =
        isToday ? careblazersColors.cta : careblazersColors.primary;
    return Padding(
      key: ShiftsScreen.dayRowKey(dayIndex),
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                _dayLabel(coverage.day, isToday: isToday),
                style: textTheme.bodyLarge?.copyWith(
                  color: labelColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _CoverageBar(
            key: ShiftsScreen.barKey(dayIndex),
            coverage: coverage,
            bandColors: bandColors,
            caregivers: caregivers,
          ),
          const SizedBox(height: 6),
          Text(
            _caption(coverage),
            key: ShiftsScreen.captionKey(dayIndex),
            style: textTheme.bodyMedium?.copyWith(
              color: coverage.isFullyCovered || coverage.shifts.isEmpty
                  ? careblazersColors.text
                  : careblazersColors.accentDeep,
            ),
          ),
        ],
      ),
    );
  }
}

/// The 24-hour bar: a warm base track, red striped bands over the gaps, and
/// a colored band per covering caregiver positioned by clock time.
class _CoverageBar extends StatelessWidget {
  const _CoverageBar({
    super.key,
    required this.coverage,
    required this.bandColors,
    required this.caregivers,
  });

  final DayCoverage coverage;
  final Map<String, Color> bandColors;
  final Map<String, Caregiver> caregivers;

  static const double _height = 30;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double w = constraints.maxWidth;
          // Map a clock time to an x offset, clamped to the day window.
          double x(DateTime t) {
            final int mins =
                t.difference(coverage.day).inMinutes.clamp(0, 1440);
            return mins / 1440 * w;
          }

          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: careblazersColors.surfaceWarm,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              for (final DayInterval gap in coverage.gaps)
                Positioned(
                  left: x(gap.start),
                  width: x(gap.end) - x(gap.start),
                  top: 0,
                  bottom: 0,
                  child: Semantics(
                    label: 'No coverage '
                        '${_clockLabel(gap.start)} to ${_clockLabel(gap.end)}',
                    child: CustomPaint(painter: _GapStripePainter()),
                  ),
                ),
              for (final CareShift shift in coverage.shifts)
                Positioned(
                  left: x(shift.start),
                  width: x(shift.end) - x(shift.start),
                  top: 3,
                  bottom: 3,
                  child: _Band(
                    color: bandColors[shift.caregiverId] ??
                        careblazersColors.primarySoft,
                    label: _bandSemantics(shift),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _bandSemantics(CareShift shift) {
    final String name = caregivers[shift.caregiverId]?.displayName ?? 'Someone';
    return '$name covering '
        '${_clockLabel(shift.start)} to ${_clockLabel(shift.end)}';
  }
}

/// One caregiver's colored coverage band.
class _Band extends StatelessWidget {
  const _Band({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// Diagonal red stripes over a faint red wash — the "no coverage" treatment
/// for a gap band (BUILD_SPEC.md §5.14). Uses the brand error token rather
/// than a default Material red.
class _GapStripePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final RRect rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(4),
    );
    final Paint wash = Paint()
      ..color = careblazersColors.error.withValues(alpha: 0.10);
    canvas.drawRRect(rrect, wash);

    canvas.save();
    canvas.clipRRect(rrect);
    final Paint stroke = Paint()
      ..color = careblazersColors.error.withValues(alpha: 0.45)
      ..strokeWidth = 2;
    const double step = 7;
    for (double sx = -size.height; sx < size.width; sx += step) {
      canvas.drawLine(
        Offset(sx, size.height),
        Offset(sx + size.height, 0),
        stroke,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GapStripePainter oldDelegate) => false;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: ShiftsScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.access_time_outlined,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            "No shifts scheduled yet. Tap Schedule shift to say who's "
            'covering and when.',
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Schedule-shift sheet
// ---------------------------------------------------------------------------

/// Bottom sheet that schedules a shift (TASKS.md Phase 14.31). Collects a
/// caregiver (required), a start + end time (end must be after start), and
/// an optional handoff note. Save writes through the [CareShifts] notifier
/// — which refreshes the strip — then pops.
class _ScheduleShiftSheet extends ConsumerStatefulWidget {
  const _ScheduleShiftSheet();

  @override
  ConsumerState<_ScheduleShiftSheet> createState() =>
      _ScheduleShiftSheetState();
}

class _ScheduleShiftSheetState extends ConsumerState<_ScheduleShiftSheet> {
  final TextEditingController _notes = TextEditingController();
  String? _caregiverId;
  late DateTime _start;
  late DateTime _end;
  String? _caregiverError;
  String? _timeError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final DateTime now = ref.read(careShiftsClockProvider)();
    // Default to a standard 8-hour day shift on today, on the hour.
    _start = DateTime(now.year, now.month, now.day, 9);
    _end = _start.add(const Duration(hours: 8));
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool isStart}) async {
    final DateTime base = isStart ? _start : _end;
    final DateTime now = ref.read(careShiftsClockProvider)();
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (!mounted) return;
    final DateTime picked = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? base.hour,
      time?.minute ?? base.minute,
    );
    setState(() {
      if (isStart) {
        _start = picked;
        // Keep end after start: if the new start overruns the end, push the
        // end out to preserve the existing shift length (min one hour).
        if (!_end.isAfter(_start)) {
          _end = _start.add(const Duration(hours: 1));
        }
      } else {
        _end = picked;
      }
      _timeError = null;
    });
  }

  Future<void> _save() async {
    if (_submitting) return;
    final String? caregiverId = _caregiverId;
    if (caregiverId == null) {
      setState(() => _caregiverError = "Pick who's covering.");
      return;
    }
    if (!_end.isAfter(_start)) {
      setState(() => _timeError = 'The end time must be after the start time.');
      return;
    }
    setState(() {
      _submitting = true;
      _caregiverError = null;
      _timeError = null;
    });

    final String notes = _notes.text.trim();
    final CareShift shift = CareShift(
      id: ref.read(shiftIdFactoryProvider)(),
      caregiverId: caregiverId,
      start: _start,
      end: _end,
      patientId: careShiftsPatientId,
      notes: notes.isEmpty ? null : notes,
    );
    await ref.read(careShiftsProvider.notifier).addShift(shift);

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AsyncValue<List<Caregiver>> caregivers =
        ref.watch(schedulableCaregiversProvider);

    return Padding(
      key: ShiftsScreen.scheduleSheetKey,
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Schedule a shift',
              style: textTheme.titleLarge?.copyWith(
                color: careblazersColors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "Who's covering",
              style: textTheme.bodyLarge?.copyWith(
                color: careblazersColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            caregivers.when(
              loading: () => const SizedBox.shrink(),
              error: (Object e, StackTrace _) => const SizedBox.shrink(),
              data: (List<Caregiver> list) => list.isEmpty
                  ? Text(
                      'Add caregivers to your Care Circle first.',
                      style: textTheme.bodyMedium
                          ?.copyWith(color: careblazersColors.text),
                    )
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final Caregiver c in list)
                          _CaregiverChoice(
                            key: ShiftsScreen.caregiverOptionKey(c.id),
                            label: c.displayName,
                            selected: _caregiverId == c.id,
                            onTap: () => setState(() => _caregiverId = c.id),
                          ),
                      ],
                    ),
            ),
            if (_caregiverError != null)
              Padding(
                key: ShiftsScreen.caregiverErrorKey,
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _caregiverError!,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: careblazersColors.error),
                ),
              ),
            const SizedBox(height: 20),
            _TimeRow(
              label: 'Starts',
              value: _start,
              buttonKey: ShiftsScreen.startButtonKey,
              onPick: () => _pick(isStart: true),
            ),
            const SizedBox(height: 12),
            _TimeRow(
              label: 'Ends',
              value: _end,
              buttonKey: ShiftsScreen.endButtonKey,
              onPick: () => _pick(isStart: false),
            ),
            if (_timeError != null)
              Padding(
                key: ShiftsScreen.timeErrorKey,
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _timeError!,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: careblazersColors.error),
                ),
              ),
            const SizedBox(height: 20),
            TextField(
              key: ShiftsScreen.notesFieldKey,
              controller: _notes,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Handoff note (optional)',
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              key: ShiftsScreen.saveButtonKey,
              onPressed: _submitting ? null : _save,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: careblazersColors.cta,
                foregroundColor: Colors.white,
              ),
              child: Text(
                _submitting ? 'Saving…' : 'Schedule shift',
                style: textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labeled start/end picker row — the label, then an outlined button that
/// opens the date+time pickers and shows the chosen moment.
class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.value,
    required this.buttonKey,
    required this.onPick,
  });

  final String label;
  final DateTime value;
  final Key buttonKey;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            button: true,
            label: '$label ${_momentLabel(value)}. Change the $label time.',
            child: OutlinedButton.icon(
              key: buttonKey,
              onPressed: onPick,
              icon: Icon(Icons.event_outlined, color: careblazersColors.link),
              label: Text(
                _momentLabel(value),
                style:
                    textTheme.labelLarge?.copyWith(color: careblazersColors.link),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: careblazersColors.primarySoft),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CaregiverChoice extends StatelessWidget {
  const _CaregiverChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color border =
        selected ? careblazersColors.cta : careblazersColors.primarySoft;
    final Color fill = selected
        ? careblazersColors.cta.withValues(alpha: 0.12)
        : Colors.transparent;
    final Color fg = selected ? careblazersColors.cta : careblazersColors.text;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: textTheme.bodyMedium?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
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
          "We couldn't load the shifts.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

const List<String> _weekdaysShort = <String>[
  'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat',
];

const List<String> _monthsShort = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today · Sun Jun 1" for the lead day, "Mon Jun 2" otherwise.
String _dayLabel(DateTime day, {required bool isToday}) {
  final String weekday = _weekdaysShort[day.weekday % 7];
  final String month = _monthsShort[day.month - 1];
  final String date = '$weekday $month ${day.day}';
  return isToday ? 'Today · $date' : date;
}

/// The day's summary caption (TASKS.md Phase 14.31):
/// - no shifts → "No coverage scheduled";
/// - fully covered → "3 caregivers · fully covered";
/// - otherwise → "3 caregivers · 2h uncovered: 6am–8am".
String _caption(DayCoverage coverage) {
  if (coverage.shifts.isEmpty) return 'No coverage scheduled';
  final int count = coverage.caregiverCount;
  final String who = count == 1 ? '1 caregiver' : '$count caregivers';
  if (coverage.isFullyCovered) return '$who · fully covered';
  final String spans = coverage.gaps
      .map((DayInterval g) =>
          '${_clockLabel(g.start)}–${_clockLabel(g.end)}')
      .join(', ');
  return '$who · ${_durationLabel(coverage.uncovered)} uncovered: $spans';
}

/// "6am", "8:30am", "12pm", "12am" — the compact clock label the caption +
/// bar semantics use.
String _clockLabel(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String suffix = t.hour < 12 ? 'am' : 'pm';
  if (t.minute == 0) return '$hour$suffix';
  return '$hour:${t.minute.toString().padLeft(2, '0')}$suffix';
}

/// "2h", "45m", "1h 15m" — the rounded duration shown in the caption.
String _durationLabel(Duration d) {
  final int hours = d.inHours;
  final int minutes = d.inMinutes - hours * 60;
  if (hours > 0 && minutes > 0) return '${hours}h ${minutes}m';
  if (hours > 0) return '${hours}h';
  return '${minutes}m';
}

/// "Jun 1, 9:00 AM" — the full moment shown on a start/end picker button.
String _momentLabel(DateTime t) {
  final String month = _monthsShort[t.month - 1];
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$month ${t.day}, $hour:$minute $suffix';
}
