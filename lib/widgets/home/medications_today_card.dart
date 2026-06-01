import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/medication.dart';
import '../../routing/router.dart';
// The card reads the existing dose-log providers rather than minting its
// own — `dosesTodayProvider` already expands every active schedule onto
// today and joins the matching log, and `doseLogClockProvider` is the
// override-able wall clock both this card and the dose-log screen sample
// "now" from so day-selection and status comparison always agree.
import '../../screens/medication/dose_log_screen.dart'
    show dosesTodayProvider, doseLogClockProvider;
import '../../services/medication_repository.dart';
import '../../theme.dart';

/// How far ahead an un-given dose still counts as "due soon" (amber)
/// before its scheduled time passes and it tips into "overdue" (coral).
const Duration _dueSoonWindow = Duration(hours: 2);

/// The "Medications Today" dashboard card — the third row of the Home
/// "Today" scroll (BUILD_SPEC.md §5.18, Phase 14.9).
///
/// Watches [dosesTodayProvider] (every dose scheduled between today's
/// local midnights, joined with its [DoseLog] if the caregiver has acted)
/// and renders:
///
///   - a **header** — "Medications Today" + an `X of Y` count, where X is
///     the doses already given (a [DoseStatus.taken] or [DoseStatus.late]
///     log) and Y is every scheduled dose today;
///   - one **row per dose** — a status dot ([takenColor] teal when given,
///     [dueSoonColor] amber when due within [_dueSoonWindow],
///     [overdueColor] coral once overdue), the drug name + strength, and a
///     trailing scheduled time over a one-word status string.
///
/// The whole card is one tap target: it pushes `/medications/today`
/// ([CareblazersRoutes.medicationDoseLog]) — the full dose-log checklist —
/// onto the root navigator, the same way [EmergencyCardPin] opens the
/// Emergency Card.
///
/// State surfaces:
///   - **loading** — a skeleton (placeholder count + three shimmer rows)
///     while the provider resolves;
///   - **empty** — "No medications today." when nothing is scheduled;
///   - **error** — a single muted line; the home dashboard never throws a
///     red box at a caregiver mid-crisis.
class MedicationsTodayCard extends ConsumerWidget {
  const MedicationsTodayCard({super.key});

  /// Tap target + test/golden handle for the whole card.
  static const Key cardKey = Key('home-medications-today-card');

  /// The `X of Y` header count.
  static const Key countKey = Key('home-medications-today-count');

  /// The "No medications today." empty body.
  static const Key emptyKey = Key('home-medications-today-empty');

  /// The loading skeleton body.
  static const Key skeletonKey = Key('home-medications-today-skeleton');

  /// The populated dose list.
  static const Key listKey = Key('home-medications-today-list');

  /// Stable per-row key derived from the (medicationId, scheduledFor)
  /// pair — schedule id alone collides when one med has two doses today.
  static Key rowKey(String medicationId, DateTime scheduledFor) =>
      Key('home-medications-today-row-$medicationId-'
          '${scheduledFor.millisecondsSinceEpoch}');

  // Status-dot hues (Phase 14.9). These are semantic status indicators,
  // distinct from the 10 §3.1 brand tokens, chosen to read at a glance:
  // teal "given", amber "coming up", coral "needs attention". A dose with
  // no active status — scheduled more than [_dueSoonWindow] out, or a
  // deliberate skip — falls back to the muted brand `primarySoft`.
  static const Color takenColor = Color(0xFF1F8A70); // teal
  static const Color dueSoonColor = Color(0xFFE0A33E); // amber
  static const Color overdueColor = Color(0xFFE5573F); // coral

  static const double _radius = 16;

  void _open(BuildContext context) {
    GoRouter.of(context).pushNamed(CareblazersRoutes.medicationDoseLog);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ScheduledDose>> async =
        ref.watch(dosesTodayProvider);
    final DateTime now = ref.watch(doseLogClockProvider)();

    final (Widget trailing, Widget body) = async.when(
      loading: () => (const _CountSkeleton(), const _SkeletonBody()),
      error: (Object _, StackTrace __) => (
        const SizedBox.shrink(),
        const _MessageBody(
          message: "We couldn't load today's medications.",
        ),
      ),
      data: (List<ScheduledDose> doses) {
        if (doses.isEmpty) {
          return (
            const SizedBox.shrink(),
            const _MessageBody(message: 'No medications today.'),
          );
        }
        final ({int taken, int total}) count = medicationsTodayCount(doses);
        return (
          _CountChip(taken: count.taken, total: count.total),
          _DoseList(doses: doses, now: now),
        );
      },
    );

    return Material(
      color: careblazersColors.surfaceWarm,
      borderRadius: BorderRadius.circular(_radius),
      child: InkWell(
        key: cardKey,
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(_radius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Header(trailing: trailing),
              const SizedBox(height: 12),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

/// (taken, total) for today's [doses]: `taken` counts a dose whose log is
/// [DoseStatus.taken] or [DoseStatus.late] (late is still given); `total`
/// is every scheduled dose. Drives the "X of Y" header count. Pure so the
/// X-of-Y arithmetic is unit-testable without a widget tree.
@visibleForTesting
({int taken, int total}) medicationsTodayCount(List<ScheduledDose> doses) {
  int taken = 0;
  for (final ScheduledDose dose in doses) {
    final DoseLog? log = dose.log;
    if (log != null &&
        (log.status == DoseStatus.taken || log.status == DoseStatus.late)) {
      taken++;
    }
  }
  return (taken: taken, total: doses.length);
}

/// The one-word status string a dose row shows at [now] — "Taken",
/// "Due soon", "Overdue", "Upcoming", "Skipped" or "Missed". Exposed for
/// unit tests of the taken / due / overdue resolution.
@visibleForTesting
String medicationDoseStatusLabel(ScheduledDose dose, DateTime now) =>
    _label(_resolve(dose, now));

/// The status-dot color a dose row paints at [now]. Exposed so tests can
/// assert the teal / amber / coral mapping without reaching into private
/// state.
@visibleForTesting
Color medicationDoseStatusColor(ScheduledDose dose, DateTime now) =>
    _color(_resolve(dose, now));

/// The mutually exclusive states a dose row can be in. Only the first
/// three carry a status-dot hue per §5.18; [upcoming] (more than
/// [_dueSoonWindow] out) and [skipped] (a deliberate hold) render muted.
enum _DoseState { taken, dueSoon, overdue, upcoming, skipped, missed }

_DoseState _resolve(ScheduledDose dose, DateTime now) {
  final DoseLog? log = dose.log;
  if (log != null) {
    switch (log.status) {
      case DoseStatus.taken:
      case DoseStatus.late:
        return _DoseState.taken;
      case DoseStatus.skipped:
        return _DoseState.skipped;
      case DoseStatus.missed:
        return _DoseState.missed;
    }
  }
  if (now.isAfter(dose.scheduledFor)) return _DoseState.overdue;
  if (dose.scheduledFor.difference(now) <= _dueSoonWindow) {
    return _DoseState.dueSoon;
  }
  return _DoseState.upcoming;
}

Color _color(_DoseState state) {
  switch (state) {
    case _DoseState.taken:
      return MedicationsTodayCard.takenColor;
    case _DoseState.dueSoon:
      return MedicationsTodayCard.dueSoonColor;
    case _DoseState.overdue:
    case _DoseState.missed:
      return MedicationsTodayCard.overdueColor;
    case _DoseState.upcoming:
    case _DoseState.skipped:
      return careblazersColors.primarySoft;
  }
}

String _label(_DoseState state) {
  switch (state) {
    case _DoseState.taken:
      return 'Taken';
    case _DoseState.dueSoon:
      return 'Due soon';
    case _DoseState.overdue:
      return 'Overdue';
    case _DoseState.upcoming:
      return 'Upcoming';
    case _DoseState.skipped:
      return 'Skipped';
    case _DoseState.missed:
      return 'Missed';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.trailing});

  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(
            'Medications Today',
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
        ),
        const SizedBox(width: 12),
        trailing,
      ],
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({required this.taken, required this.total});

  final int taken;
  final int total;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: '$taken of $total doses taken today',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: careblazersColors.background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '$taken of $total',
          key: MedicationsTodayCard.countKey,
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primarySoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _DoseList extends StatelessWidget {
  const _DoseList({required this.doses, required this.now});

  final List<ScheduledDose> doses;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: MedicationsTodayCard.listKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < doses.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 12),
          _DoseRow(dose: doses[i], now: now),
        ],
      ],
    );
  }
}

class _DoseRow extends StatelessWidget {
  const _DoseRow({required this.dose, required this.now});

  final ScheduledDose dose;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Medication med = dose.medication;
    final _DoseState state = _resolve(dose, now);
    final Color statusColor = _color(state);
    final String statusLabel = _label(state);
    final String clock = _formatClock(dose.scheduledFor);

    return Semantics(
      container: true,
      label: '${med.name}, ${med.dosage}, at $clock. $statusLabel.',
      child: ExcludeSemantics(
        child: Row(
          key: MedicationsTodayCard.rowKey(med.id, dose.scheduledFor),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            _StatusDot(color: statusColor),
            const SizedBox(width: 12),
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
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  clock,
                  style: textTheme.bodyMedium?.copyWith(
                    color: careblazersColors.primarySoft,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
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
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Empty + error bodies share this single muted line.
class _MessageBody extends StatelessWidget {
  const _MessageBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: MedicationsTodayCard.emptyKey,
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        message,
        style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
      ),
    );
  }
}

class _SkeletonBody extends StatelessWidget {
  const _SkeletonBody();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: MedicationsTodayCard.skeletonKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < 3; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 12),
          const _SkeletonRow(),
        ],
      ],
    );
  }
}

class _CountSkeleton extends StatelessWidget {
  const _CountSkeleton();

  @override
  Widget build(BuildContext context) =>
      const _SkeletonBlock(width: 56, height: 22, radius: 999);
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        _SkeletonBlock(width: 12, height: 12, radius: 6),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _SkeletonBlock(width: 140, height: 16, radius: 6),
              SizedBox(height: 6),
              _SkeletonBlock(width: 72, height: 12, radius: 6),
            ],
          ),
        ),
      ],
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    required this.width,
    required this.height,
    required this.radius,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        // A faint tint of the brand navy reads as a placeholder against
        // the warm-white card without introducing an off-palette grey.
        color: careblazersColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 12-hour clock — "8:00 AM", "9:05 PM". Mirrors the dose-log screen's
/// formatter so the two medication surfaces read identically.
String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}
