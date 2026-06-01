import 'package:flutter/material.dart';
// `Provider` in [models/appointment.dart] collides with riverpod's own
// `Provider` class — `hide` keeps the model name resolvable here without
// aliasing every callsite, the same way the appointment screens do.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/appointment.dart';
// The card reuses the appointment repository seam every other appointment
// surface reads through, and the same override-able wall clock the list
// screen samples its "Today / Tomorrow" subtitles from — so the card's
// today-vs-future status dot and the list screen always agree on "now".
import '../../screens/appointment/appointment_list_screen.dart'
    show appointmentListClockProvider;
import '../../services/appointment_repository.dart';
import '../../theme.dart';

part 'next_appointment_card.g.dart';

/// An [Appointment] paired with its already-resolved [Provider] — the
/// soonest upcoming visit the Home "Next Appointment" card renders
/// (Phase 14.10). [provider] is null when the appointment's
/// [Appointment.providerId] points at a row that has since been deleted;
/// the card paints a soft "Provider on file" fallback rather than
/// crashing, mirroring the list screen's defensive handling.
@immutable
class NextAppointmentItem {
  const NextAppointmentItem({required this.appointment, this.provider});

  final Appointment appointment;
  final Provider? provider;
}

/// The soonest *upcoming* appointment, or null when none is on the books
/// (Phase 14.10). "Upcoming" here is the §5.18 predicate the Home card
/// wants — `status != canceled` AND `startsAt` strictly after the clock
/// sample — which is broader than the list screen's "Upcoming" section
/// (a completed visit somehow still in the future would surface here).
///
/// [appointmentRepositoryBackendProvider] returns every appointment
/// ascending by `startsAt`, so the first row that clears the predicate is
/// the soonest — no sort needed. The provider name is resolved in a
/// single batch read rather than one query per candidate. Tests override
/// the repository with an in-memory instance and [appointmentListClockProvider]
/// with a fixed clock so the future resolves deterministically.
@Riverpod(keepAlive: false)
Future<NextAppointmentItem?> nextAppointment(Ref ref) async {
  final AppointmentRepository repo =
      ref.watch(appointmentRepositoryBackendProvider);
  final DateTime now = ref.watch(appointmentListClockProvider)();

  final List<Appointment> all = await repo.listAppointments();
  final Appointment? soonest = pickNextAppointment(all, now);
  if (soonest == null) return null;

  final List<Provider> providers = await repo.listProviders();
  Provider? provider;
  for (final Provider p in providers) {
    if (p.id == soonest.providerId) {
      provider = p;
      break;
    }
  }
  return NextAppointmentItem(appointment: soonest, provider: provider);
}

/// The soonest appointment in [all] that is still ahead of [now] and not
/// canceled, or null if there is none. [all] is expected ascending by
/// `startsAt` (as [AppointmentRepository.listAppointments] returns it),
/// so the first match is the soonest; the scan stays correct on an
/// unsorted list too by keeping the earliest qualifying row. Pure so the
/// `status != canceled && startsAt > now` predicate is unit-testable
/// without a widget tree or a database.
@visibleForTesting
Appointment? pickNextAppointment(List<Appointment> all, DateTime now) {
  Appointment? soonest;
  for (final Appointment a in all) {
    if (a.status == AppointmentStatus.canceled) continue;
    if (!a.startsAt.isAfter(now)) continue;
    if (soonest == null || a.startsAt.isBefore(soonest.startsAt)) {
      soonest = a;
    }
  }
  return soonest;
}

/// The "Next Appointment" dashboard card — the fourth row of the Home
/// "Today" scroll (BUILD_SPEC.md §5.18, Phase 14.10).
///
/// Watches [nextAppointmentProvider] and renders the soonest upcoming
/// visit as a single row:
///   - a **status dot** — coral ([todayColor]) when the visit is today,
///     navy ([futureColor]) when it is on a later day;
///   - the **provider name** + **specialty** (the provider's role —
///     "Doctor", "Neurologist", "Social worker"; blank for an "other"
///     role), the **formatted time** ("Today, 2:30 PM" / "Tomorrow, …" /
///     "Jun 15, …"), and the **driver name** when one is assigned.
///
/// The whole card is one tap target: it pushes `/appointments/:id` — the
/// appointment detail screen — onto the root navigator, the same way the
/// list screen's cards do.
///
/// State surfaces match [MedicationsTodayCard]:
///   - **loading** — a single shimmer row while the future resolves;
///   - **empty** — "No upcoming appointments." when nothing qualifies;
///   - **error** — one muted line; Home never throws a red box at a
///     caregiver mid-crisis.
class NextAppointmentCard extends ConsumerWidget {
  const NextAppointmentCard({super.key});

  /// Tap target + test/golden handle for the whole card.
  static const Key cardKey = Key('home-next-appointment-card');

  /// The "No upcoming appointments." empty body.
  static const Key emptyKey = Key('home-next-appointment-empty');

  /// The loading skeleton body.
  static const Key skeletonKey = Key('home-next-appointment-skeleton');

  /// The populated appointment row.
  static const Key rowKey = Key('home-next-appointment-row');

  /// The status dot — tests read its color to assert today vs future.
  static const Key dotKey = Key('home-next-appointment-dot');

  /// The optional driver line.
  static const Key driverKey = Key('home-next-appointment-driver');

  // Status-dot hues (Phase 14.10): coral draws the eye to a visit
  // happening today; a future visit reads calmly in brand navy. The
  // coral matches the medications card's "needs attention" coral so the
  // two dashboard cards share one visual language.
  static const Color todayColor = Color(0xFFE5573F); // coral

  static const double _radius = 16;

  void _open(BuildContext context, String appointmentId) {
    context.push('/appointments/$appointmentId');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<NextAppointmentItem?> async =
        ref.watch(nextAppointmentProvider);
    final DateTime now = ref.watch(appointmentListClockProvider)();

    final (Widget body, NextAppointmentItem? item) = async.when(
      loading: () => (const _SkeletonRow(), null),
      error: (Object _, StackTrace __) => (
        const _MessageBody(
          message: "We couldn't load your next appointment.",
        ),
        null,
      ),
      data: (NextAppointmentItem? data) {
        if (data == null) {
          return (
            const _MessageBody(message: 'No upcoming appointments.'),
            null,
          );
        }
        return (_AppointmentRow(item: data, now: now), data);
      },
    );

    return Material(
      color: careblazersColors.surfaceWarm,
      borderRadius: BorderRadius.circular(_radius),
      child: InkWell(
        key: cardKey,
        // Only tappable once an appointment has resolved — an empty or
        // still-loading card has nothing to open.
        onTap: item == null
            ? null
            : () => _open(context, item.appointment.id),
        borderRadius: BorderRadius.circular(_radius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const _Header(),
              const SizedBox(height: 12),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

/// The specialty line for [provider] — its role rendered as a label, or
/// an empty string when the role is [ProviderRole.other] (free-text
/// specialty lives in the provider notes, not a structured field) or the
/// provider is missing. Mirrors `pdf_exporter._providerLine`'s role
/// wording so the doctor-visit packet and the Home card read identically.
@visibleForTesting
String specialtyLabel(Provider? provider) {
  if (provider == null) return '';
  switch (provider.role) {
    case ProviderRole.doctor:
      return 'Doctor';
    case ProviderRole.neurologist:
      return 'Neurologist';
    case ProviderRole.socialWorker:
      return 'Social worker';
    case ProviderRole.other:
      return '';
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      'Next Appointment',
      style: textTheme.titleLarge?.copyWith(
        color: careblazersColors.primary,
      ),
    );
  }
}

class _AppointmentRow extends StatelessWidget {
  const _AppointmentRow({required this.item, required this.now});

  final NextAppointmentItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Appointment appt = item.appointment;
    final String providerName = item.provider?.name ?? 'Provider on file';
    final String specialty = specialtyLabel(item.provider);
    final bool isToday = _isSameDay(appt.startsAt, now);
    final Color dotColor =
        isToday ? NextAppointmentCard.todayColor : careblazersColors.primary;
    final String when = _formatWhen(appt.startsAt, now);
    final String? driver = appt.driverName;

    // One spoken sentence in section order for VoiceOver, then the
    // visual row excluded from semantics so it isn't re-read piecemeal.
    final String semanticLabel = <String>[
      providerName,
      if (specialty.isNotEmpty) specialty,
      when,
      if (driver != null && driver.isNotEmpty) 'Driver $driver',
    ].join('. ');

    return Semantics(
      container: true,
      button: true,
      label: '$semanticLabel. Double-tap to open.',
      child: ExcludeSemantics(
        child: Row(
          key: NextAppointmentCard.rowKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              // Nudge the dot down onto the first text line's baseline.
              padding: const EdgeInsets.only(top: 6),
              child: _StatusDot(color: dotColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(
                          text: providerName,
                          style: textTheme.bodyLarge?.copyWith(
                            color: careblazersColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (specialty.isNotEmpty)
                          TextSpan(
                            text: '  $specialty',
                            style: textTheme.bodyMedium?.copyWith(
                              color: careblazersColors.primarySoft,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    when,
                    style: textTheme.bodyMedium?.copyWith(
                      color: careblazersColors.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (driver != null && driver.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Row(
                      key: NextAppointmentCard.driverKey,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.directions_car_outlined,
                          size: 16,
                          color: careblazersColors.primarySoft,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Driver: $driver',
                            style: textTheme.bodyMedium?.copyWith(
                              color: careblazersColors.primarySoft,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
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
      key: NextAppointmentCard.dotKey,
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
      key: NextAppointmentCard.emptyKey,
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        message,
        style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
      ),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      key: NextAppointmentCard.skeletonKey,
      children: <Widget>[
        _SkeletonBlock(width: 12, height: 12, radius: 6),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _SkeletonBlock(width: 180, height: 16, radius: 6),
              SizedBox(height: 6),
              _SkeletonBlock(width: 96, height: 12, radius: 6),
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

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

const List<String> _monthsShort = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}

/// "Today, 2:30 PM" / "Tomorrow, 2:30 PM" / "Jun 15, 2:30 PM" — mirrors
/// the appointment list screen's formatter so the two surfaces read the
/// same. Exposed for unit tests of the Today / Tomorrow / fallback paths.
@visibleForTesting
String formatAppointmentWhen(DateTime at, DateTime now) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime tomorrow = today.add(const Duration(days: 1));
  final DateTime atDay = DateTime(at.year, at.month, at.day);
  final String clock = _formatClock(at);
  if (atDay == today) return 'Today, $clock';
  if (atDay == tomorrow) return 'Tomorrow, $clock';
  final String month = _monthsShort[at.month - 1];
  return '$month ${at.day}, $clock';
}

String _formatWhen(DateTime at, DateTime now) => formatAppointmentWhen(at, now);
