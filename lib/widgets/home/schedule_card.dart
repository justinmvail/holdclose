import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/appointment.dart';
import '../../models/care_event.dart';
import '../../providers/home_clock_provider.dart';
import '../../providers/patient_timeline_provider.dart';
import '../../services/appointment_repository.dart';
import '../../theme.dart';
import '../form/format.dart';
import '../schedule_grouping.dart';

/// Completed-status of every appointment, keyed by id — so the schedule can
/// render + toggle a "done" checkbox without the read-only [CareEvent]
/// projection having to carry it (fb_1781099457246946). autoDispose so it
/// refetches when invalidated after a toggle.
final scheduleAppointmentStatusProvider =
    FutureProvider.autoDispose<Map<String, AppointmentStatus>>((Ref ref) async {
  // Defensive: a checkbox decoration must never crash the schedule render.
  // If the appointment store is unreachable (e.g. a golden/test environment
  // with no DB), fall back to "no statuses" — the rows just show unchecked.
  try {
    final List<Appointment> appts =
        await ref.watch(appointmentRepositoryProvider).listAppointments();
    return <String, AppointmentStatus>{
      for (final Appointment a in appts) a.id: a.status,
    };
  } catch (_) {
    return const <String, AppointmentStatus>{};
  }
});

/// Flip an appointment between completed and upcoming, persist it, and
/// refresh the schedule's status + the timeline so the checkbox + any
/// dependent UI update. Defensive: a missing appointment is a no-op.
Future<void> _toggleAppointmentDone(WidgetRef ref, String appointmentId) async {
  final AppointmentRepository repo = ref.read(appointmentRepositoryProvider);
  final Appointment? appt = await repo.getAppointment(appointmentId);
  if (appt == null) return;
  final AppointmentStatus next = appt.status == AppointmentStatus.completed
      ? AppointmentStatus.upcoming
      : AppointmentStatus.completed;
  await repo.upsertAppointment(appt.copyWith(status: next));
  ref.invalidate(scheduleAppointmentStatusProvider);
  ref.invalidate(patientTimelineEventsProvider);
}

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

  /// First-run empty-state CTAs.
  static const Key emptyAddMedKey = Key('home-schedule-empty-add-med');
  static const Key emptyScanKey = Key('home-schedule-empty-scan');
  static const Key emptyAskCoachKey = Key('home-schedule-empty-ask-coach');
  static Key rowKey(String eventId) => Key('home-schedule-row-$eventId');
  static Key doneCheckboxKey(String eventId) =>
      Key('home-schedule-done-$eventId');

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

    // Which appointments are marked done (for the checkable bullet). Empty
    // while loading — the row just shows an unchecked box until it lands.
    final Map<String, AppointmentStatus> apptStatus =
        ref.watch(scheduleAppointmentStatusProvider).asData?.value ??
            const <String, AppointmentStatus>{};
    final Set<String> doneApptIds = <String>{
      for (final MapEntry<String, AppointmentStatus> e in apptStatus.entries)
        if (e.value == AppointmentStatus.completed) e.key,
    };
    void toggleAppt(String id) => unawaited(_toggleAppointmentDone(ref, id));

    final Widget body = async.when(
      loading: () => const _Skeleton(),
      error: (Object _, StackTrace __) =>
          const _Message(text: "We couldn't load your schedule."),
      data: (List<CareEvent> events) {
        final _Buckets b = _bucket(events, now);
        if (b.isEmpty) {
          return const _EmptyState();
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
                doneApptIds: doneApptIds,
                onToggleAppt: toggleAppt,
              ),
            if (b.tomorrow.isNotEmpty) ...<Widget>[
              if (b.today.isNotEmpty) const SizedBox(height: 12),
              _Section(
                key: tomorrowSectionKey,
                label: 'Tomorrow',
                events: b.tomorrow,
                maxRows: _maxRowsPerSection,
                now: now,
                doneApptIds: doneApptIds,
                onToggleAppt: toggleAppt,
              ),
            ],
          ],
        );
      },
    );

    return Material(
      color: context.hc.surfaceWarm,
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
            style: tt.titleLarge?.copyWith(color: context.hc.primary),
          ),
        ),
        TextButton(
          key: ScheduleCard.viewCalendarKey,
          onPressed: onTapCalendar,
          style: TextButton.styleFrom(
            foregroundColor: context.hc.link,
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
    required this.doneApptIds,
    required this.onToggleAppt,
  });

  final String label;
  final List<CareEvent> events;
  final int maxRows;
  final DateTime now;

  /// Ids of appointments currently marked done (drives the checkbox).
  final Set<String> doneApptIds;

  /// Toggle an appointment's done state by id.
  final void Function(String appointmentId) onToggleAppt;

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
            color: context.hc.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: tt.titleMedium?.copyWith(
              color: context.hc.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final ScheduleRow r in rows)
          r is DoseGroupRow
              ? _GroupedRow(model: r.group, now: now)
              : _Row(
                  event: (r as EventRow).event,
                  now: now,
                  doneApptIds: doneApptIds,
                  onToggleAppt: onToggleAppt,
                ),
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
            color: context.hc.link,
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
    final String time = formatClock12h(model.start);
    final Color baseText = past
        ? context.hc.text.withValues(alpha: 0.55)
        : context.hc.text;
    final Color labelColor = past
        ? context.hc.primary.withValues(alpha: 0.55)
        : context.hc.primary;
    final Color timeColor = past
        ? context.hc.primarySoft.withValues(alpha: 0.55)
        : context.hc.primarySoft;
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
              // Flush-left time — the window header reads like every other
              // parent row (fb_1781138746662030); only its child doses below
              // indent.
              Expanded(
                child: Text.rich(
                  label == null
                      ? TextSpan(
                          text: time,
                          style: tt.bodyMedium?.copyWith(
                            color: timeColor,
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : TextSpan(
                          children: <InlineSpan>[
                            // TIME first, then the window name
                            // ("8:00 AM · Morning Medication") so the dose
                            // group matches every other row
                            // (fb_1781099457246946).
                            TextSpan(
                              text: time,
                              style: tt.bodyMedium?.copyWith(
                                color: timeColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(
                              // "Medication" appended to the window name so a
                              // dose group reads unambiguously as meds among
                              // the appointments + other events the schedule
                              // mixes in — "Morning Medication" not "Morning".
                              text: '  ·  $label Medication',
                              style: tt.bodyMedium?.copyWith(
                                color: labelColor,
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
                  color: context.hc.primarySoft,
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Each medication on its own row, INDENTED so its mark sits under the
          // window's time column (not out to the left of it). Earlier the mark
          // sat at the far-left margin, left of every row's time, so the
          // children read as out-dented — "the indentation is reversed"
          // (fb_1781132307652198). Nesting them past the time slot makes the
          // doses read as children of the window header.
          // Checkmark = logged dose, hollow circle = still pending.
          for (final ({String name, bool taken}) m in model.meds)
            Padding(
              padding: const EdgeInsets.only(
                  left: _leadingSlot, top: 2, bottom: 2),
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
    final Color takenColor = context.hc.success;
    final Color pendingColor = context.hc.primarySoft;
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

/// Width of the leading "mark done" slot — a checkbox on completable rows,
/// an equal-width blank on the rest, so every row's time stays aligned.
const double _leadingSlot = 30;

class _Row extends StatelessWidget {
  const _Row({
    required this.event,
    required this.now,
    required this.doneApptIds,
    required this.onToggleAppt,
  });

  final CareEvent event;
  final DateTime now;
  final Set<String> doneApptIds;
  final void Function(String appointmentId) onToggleAppt;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final bool past = event.start.isBefore(now);
    final String time = formatClock12h(event.start);
    final String? route = event.detailRoute;
    final VoidCallback? onTap = route == null
        ? null
        : () => GoRouter.of(context).push(route);
    // TIME first, then title ("8:00 AM · Dr Smith"), no leading kind-dot — so
    // every schedule entry reads identically (fb_1781045816196914 /
    // fb_1781099457246946).
    final Color labelColor = past
        ? context.hc.primary.withValues(alpha: 0.55)
        : context.hc.primary;
    final Color timeColor = past
        ? context.hc.primarySoft.withValues(alpha: 0.55)
        : context.hc.primarySoft;

    // Only items with a real "done" state are checkable — appointments here
    // (doses live in their own grouped rows). The check-off control rides on
    // the RIGHT now (fb_1781138746662030: "times need to remove the indent —
    // only bullets should indent"), so every parent row's TIME is flush-left;
    // only a window's child doses indent under it.
    final String? apptId = event.kind == CareEventKind.appointment
        ? event.externalRef
        : null;

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
                        text: time,
                        style: tt.bodyMedium?.copyWith(
                          color: timeColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(
                        text: '  ·  ${event.title}',
                        style: tt.bodyMedium?.copyWith(
                          color: labelColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (apptId != null) ...<Widget>[
                const SizedBox(width: 8),
                _DoneCheckbox(
                  key: ScheduleCard.doneCheckboxKey(event.id),
                  done: doneApptIds.contains(apptId),
                  dimmed: past,
                  onTap: () => onToggleAppt(apptId),
                ),
              ],
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: context.hc.primarySoft,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable "mark as done" bullet — a hollow circle that fills to a check.
/// Its own tap target so it doesn't trigger the row's navigation.
class _DoneCheckbox extends StatelessWidget {
  const _DoneCheckbox({
    super.key,
    required this.done,
    required this.onTap,
    this.dimmed = false,
  });

  final bool done;
  final VoidCallback onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final Color c = done ? context.hc.success : context.hc.primarySoft;
    return InkResponse(
      onTap: onTap,
      radius: 20,
      child: Icon(
        done ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 22,
        color: dimmed ? c.withValues(alpha: 0.55) : c,
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
        color: context.hc.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// First-run empty state for the schedule card. A bare "No upcoming items."
/// left a new caregiver with nothing to do; this instead points them at the
/// three fastest ways to fill the schedule — add a medication by hand, scan a
/// prescription, or ask the coach — mirroring the instructive med-list /
/// journal empty states.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Column(
      key: ScheduleCard.emptyKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          "Nothing scheduled yet.",
          style: tt.bodyLarge?.copyWith(
            color: context.hc.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          "Add what your loved one takes and their appointments, and today's "
          "plan shows up here. Here's a quick start:",
          style: tt.bodyMedium?.copyWith(color: context.hc.text),
        ),
        const SizedBox(height: 16),
        _EmptyCta(
          buttonKey: ScheduleCard.emptyAddMedKey,
          icon: Icons.add,
          label: 'Add a medication',
          onTap: () => GoRouter.of(context).push('/medications/new'),
        ),
        const SizedBox(height: 8),
        _EmptyCta(
          buttonKey: ScheduleCard.emptyScanKey,
          icon: Icons.document_scanner_outlined,
          label: 'Scan a prescription',
          filled: false,
          onTap: () => GoRouter.of(context).push('/scan'),
        ),
        const SizedBox(height: 8),
        _EmptyCta(
          buttonKey: ScheduleCard.emptyAskCoachKey,
          icon: Icons.chat_bubble_outline,
          label: 'Ask the coach',
          filled: false,
          onTap: () => GoRouter.of(context).push('/chat'),
        ),
      ],
    );
  }
}

/// One full-width action in the first-run empty state — a filled brand CTA
/// for the primary path, outlined for the alternatives. Foreground reads
/// `colorScheme.onSecondary` so the filled variant stays legible in both
/// palettes (WCAG-AA); the outlined variants carry navy label text.
class _EmptyCta extends StatelessWidget {
  const _EmptyCta({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = true,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    if (filled) {
      final Color onFilled = Theme.of(context).colorScheme.onSecondary;
      return Semantics(
        button: true,
        label: label,
        child: ElevatedButton.icon(
          key: buttonKey,
          onPressed: onTap,
          icon: Icon(icon, color: onFilled),
          label: Text(label),
          style: ElevatedButton.styleFrom(
            backgroundColor: context.hc.ctaFilled,
            foregroundColor: onFilled,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      label: label,
      child: OutlinedButton.icon(
        key: buttonKey,
        onPressed: onTap,
        icon: Icon(icon, color: context.hc.primary),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: context.hc.primary,
          side: BorderSide(color: context.hc.primarySoft),
          minimumSize: const Size.fromHeight(48),
        ),
      ),
    );
  }
}

/// The load-error message for the schedule card. (The empty state is its
/// own instructive [_EmptyState] — this only carries the error branch's
/// short line now.)
class _Message extends StatelessWidget {
  const _Message({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: tt.bodyLarge?.copyWith(color: context.hc.text),
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

