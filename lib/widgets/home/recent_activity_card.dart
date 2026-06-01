import 'package:flutter/material.dart';
// `Provider` in [models/appointment.dart] collides with riverpod's own
// `Provider` class — `hide` keeps the model name resolvable here without
// aliasing every callsite, the same way the appointment card + screens do.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/appointment.dart';
import '../../models/journal_entry.dart';
import '../../models/medication.dart';
import '../../providers/home_clock_provider.dart';
import '../../providers/journal_entries_provider.dart';
// The card reads each source through the same seam its owning surface
// reads through — the journal stream, the dose-log "today" provider, and
// the appointment repository — rather than minting parallel queries. That
// keeps "what the dashboard shows" and "what the detail screen shows" in
// lock-step.
import '../../screens/medication/dose_log_screen.dart' show dosesTodayProvider;
import '../../services/appointment_repository.dart';
import '../../services/medication_repository.dart' show ScheduledDose;
import '../../theme.dart';

part 'recent_activity_card.g.dart';

/// How many rows the Recent Activity card surfaces (BUILD_SPEC.md §5.18,
/// Phase 14.11). The latest three events across every source, merged.
const int recentActivityLimit = 3;

/// Which surface a [RecentActivityItem] came from. Drives the leading dot
/// color (BUILD_SPEC.md §5.18: plum=journal, teal=dose, coral=appointment,
/// navy=team) and is the discriminator the ordering tests assert against.
///
/// [team] is reserved for the care-team handoff feed that joins this card
/// when Phase 14.32 lands; nothing emits a [team] item in v1, but the
/// origin + its navy dot are wired now so the later phase only has to add
/// a source, not re-touch the rendering.
enum RecentActivityOrigin { journal, dose, appointment, team }

/// One row in the merged Recent Activity feed (Phase 14.11).
///
/// Sources map their own row shape onto this single shape so the merge +
/// sort + top-[recentActivityLimit] truncation is one pure operation
/// regardless of how many sources feed it. [createdAt] is the timeline
/// position the feed sorts by, descending; [route] is the location a tap
/// pushes to reach the source detail.
@immutable
class RecentActivityItem {
  const RecentActivityItem({
    required this.id,
    required this.origin,
    required this.summary,
    required this.createdAt,
    required this.route,
  });

  /// Source-prefixed so ids stay unique once several sources merge (a
  /// journal entry + an appointment could otherwise collide on a bare id).
  final String id;
  final RecentActivityOrigin origin;
  final String summary;
  final DateTime createdAt;

  /// The location [RecentActivityCard] pushes when the row is tapped.
  final String route;
}

/// The merged Recent Activity feed for the Home dashboard (Phase 14.11).
///
/// Aggregates the newest [recentActivityLimit] events across the journal,
/// the dose log, and appointments (care-team handoffs join when Phase
/// 14.32 ships), each mapped to a [RecentActivityItem] and sorted by
/// `createdAt` descending.
///
/// Watches [journalEntriesProvider] via `.future` so a decoder auto-log
/// or a wizard journal entry flows into the feed without an explicit
/// invalidate; the dose-log + appointment reads re-run when the card
/// rebuilds, matching the next-appointment card's plain-future cadence.
@Riverpod(keepAlive: false)
Future<List<RecentActivityItem>> recentActivity(Ref ref) async {
  final List<JournalEntry> entries =
      await ref.watch(journalEntriesProvider.future);
  final List<ScheduledDose> doses = await ref.watch(dosesTodayProvider.future);
  final AppointmentRepository repo =
      ref.watch(appointmentRepositoryBackendProvider);
  final List<Appointment> appointments = await repo.listAppointments();
  final List<Provider> providers = await repo.listProviders();

  final Map<String, Provider> providerById = <String, Provider>{
    for (final Provider p in providers) p.id: p,
  };

  final List<RecentActivityItem> items = <RecentActivityItem>[
    for (final JournalEntry e in entries) journalActivityItem(e),
    // Only doses the caregiver has acted on are "activity" — an upcoming,
    // unlogged dose belongs to the Medications Today card, not here.
    for (final ScheduledDose d in doses)
      if (d.log != null) doseActivityItem(d),
    for (final Appointment a in appointments)
      appointmentActivityItem(a, providerById[a.providerId]),
  ];

  return mergeRecentActivity(items);
}

/// Sort [items] by [RecentActivityItem.createdAt] descending and keep the
/// first [limit]. The card's whole contract — "latest N across every
/// source" — collapses to this one pure step, so an out-of-order
/// insertion in any single source still surfaces the right top rows.
/// Exposed for the mixed-source ordering-invariant test.
@visibleForTesting
List<RecentActivityItem> mergeRecentActivity(
  Iterable<RecentActivityItem> items, {
  int limit = recentActivityLimit,
}) {
  final List<RecentActivityItem> sorted = items.toList()
    ..sort((RecentActivityItem a, RecentActivityItem b) =>
        b.createdAt.compareTo(a.createdAt));
  return List<RecentActivityItem>.unmodifiable(sorted.take(limit));
}

/// Map a journal entry onto a feed row. Wizard-authored entries show the
/// caregiver's own situation text; decoder auto-logs show the behavior
/// label, mirroring how the journal list builds its row title. Pure so
/// the summary + route mapping is unit-testable without a widget tree.
@visibleForTesting
RecentActivityItem journalActivityItem(JournalEntry entry) {
  return RecentActivityItem(
    id: 'journal-${entry.id}',
    origin: RecentActivityOrigin.journal,
    summary: recentActivityJournalSummary(entry),
    createdAt: entry.createdAt,
    route: '/journal/${entry.id}',
  );
}

/// Map an acted-on dose onto a feed row. [dose.log] is expected non-null
/// (the aggregator filters unlogged doses out); the timestamp is when the
/// caregiver acted ([DoseLog.takenAt]) falling back to the scheduled time
/// for a logged skip/miss that never stamped a [takenAt]. Pure.
@visibleForTesting
RecentActivityItem doseActivityItem(ScheduledDose dose) {
  final DoseLog log = dose.log!;
  return RecentActivityItem(
    id: 'dose-${dose.medication.id}-'
        '${dose.scheduledFor.millisecondsSinceEpoch}',
    origin: RecentActivityOrigin.dose,
    summary: recentActivityDoseSummary(dose),
    createdAt: log.takenAt ?? log.scheduledFor,
    route: '/medications/today',
  );
}

/// Map an appointment onto a feed row.
///
/// TODO(decision): the [Appointment] model carries no created/modified
/// timestamp, so there is no faithful "changed at" to sort by — the
/// task's "appointment changes" can't be tracked without a schema field
/// (deferred; out of scope for this card). [startsAt] stands in as the
/// timeline position, and [formatRelativeTime] renders a future visit as
/// "in 2 days" so an upcoming appointment still reads sensibly here.
@visibleForTesting
RecentActivityItem appointmentActivityItem(
  Appointment appointment,
  Provider? provider,
) {
  return RecentActivityItem(
    id: 'appointment-${appointment.id}',
    origin: RecentActivityOrigin.appointment,
    summary: recentActivityAppointmentSummary(provider),
    createdAt: appointment.startsAt,
    route: '/appointments/${appointment.id}',
  );
}

/// Short feed summary for a journal entry — the caregiver's situation
/// text for a wizard entry, the behavior label for a decoder auto-log.
@visibleForTesting
String recentActivityJournalSummary(JournalEntry entry) {
  if (entry.wizardKind) {
    final String? situation = entry.situationText?.trim();
    if (situation != null && situation.isNotEmpty) return situation;
    return 'Journal note';
  }
  return entry.behavior.label;
}

/// Short feed summary for an acted-on dose — "Gave Donepezil 10 mg",
/// "Skipped …", "Missed …" depending on the logged status.
@visibleForTesting
String recentActivityDoseSummary(ScheduledDose dose) {
  final Medication med = dose.medication;
  final String verb = switch (dose.log?.status) {
    DoseStatus.skipped => 'Skipped',
    DoseStatus.missed => 'Missed',
    _ => 'Gave',
  };
  return '$verb ${med.name} ${med.dosage}';
}

/// Short feed summary for an appointment — "Appointment with Dr. Ortega",
/// or a soft fallback when the provider row is missing (deleted, or not
/// yet resolved).
@visibleForTesting
String recentActivityAppointmentSummary(Provider? provider) {
  final String name = provider?.name ?? 'your provider';
  return 'Appointment with $name';
}

/// The "Recent Activity" dashboard card — the fifth row of the Home
/// "Today" scroll (BUILD_SPEC.md §5.18, Phase 14.11).
///
/// Watches [recentActivityProvider] and renders the latest
/// [recentActivityLimit] events across the journal, dose log, and
/// appointments (care-team handoffs join in Phase 14.32). Each row is its
/// own tap target — unlike the single-destination Medications / Next
/// Appointment cards — because the rows route to different sources:
///   - an **origin-color dot** (plum=journal, teal=dose, coral=
///     appointment, navy=team);
///   - a one-line **summary**;
///   - a trailing **relative time** ("20 min ago").
///
/// Tapping a row pushes that event's source detail.
///
/// State surfaces match the sibling dashboard cards:
///   - **loading** — three shimmer rows while the feed resolves;
///   - **empty** — "No recent activity yet." when nothing has happened;
///   - **error** — one muted line; Home never throws a red box at a
///     caregiver mid-crisis.
class RecentActivityCard extends ConsumerWidget {
  const RecentActivityCard({super.key});

  /// Test/golden handle for the whole card.
  static const Key cardKey = Key('home-recent-activity-card');

  /// The "No recent activity yet." empty body.
  static const Key emptyKey = Key('home-recent-activity-empty');

  /// The loading skeleton body.
  static const Key skeletonKey = Key('home-recent-activity-skeleton');

  /// The populated row list.
  static const Key listKey = Key('home-recent-activity-list');

  /// Stable per-row key — the source-prefixed [RecentActivityItem.id].
  static Key rowKey(String itemId) => Key('home-recent-activity-row-$itemId');

  /// The origin dot for a row — tests read its color to assert the
  /// per-source hue.
  static Key dotKey(String itemId) => Key('home-recent-activity-dot-$itemId');

  // Origin-dot hues (Phase 14.11). The dose teal + appointment coral match
  // the Medications Today / Next Appointment status dots so the dashboard
  // shares one color language; journal plum is the new hue for this card,
  // and team resolves to brand navy (see [recentActivityOriginColor]).
  static const Color journalColor = Color(0xFF7B4B94); // plum
  static const Color doseColor = Color(0xFF1F8A70); // teal
  static const Color appointmentColor = Color(0xFFE5573F); // coral

  static const double _radius = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<RecentActivityItem>> async =
        ref.watch(recentActivityProvider);
    final DateTime now = ref.watch(homeClockProvider)();

    final Widget body = async.when(
      loading: () => const _SkeletonBody(),
      error: (Object _, StackTrace __) => const _MessageBody(
        message: "We couldn't load your recent activity.",
      ),
      data: (List<RecentActivityItem> items) {
        if (items.isEmpty) {
          return const _MessageBody(message: 'No recent activity yet.');
        }
        return _ActivityList(items: items, now: now);
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
            const _Header(),
            const SizedBox(height: 12),
            body,
          ],
        ),
      ),
    );
  }
}

/// The origin-dot color for [origin] (BUILD_SPEC.md §5.18). Exposed so
/// tests can assert the plum / teal / coral / navy mapping without
/// reaching into private state.
@visibleForTesting
Color recentActivityOriginColor(RecentActivityOrigin origin) {
  switch (origin) {
    case RecentActivityOrigin.journal:
      return RecentActivityCard.journalColor;
    case RecentActivityOrigin.dose:
      return RecentActivityCard.doseColor;
    case RecentActivityOrigin.appointment:
      return RecentActivityCard.appointmentColor;
    case RecentActivityOrigin.team:
      return careblazersColors.primary; // navy
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      'Recent Activity',
      style: textTheme.titleLarge?.copyWith(
        color: careblazersColors.primary,
      ),
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.items, required this.now});

  final List<RecentActivityItem> items;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: RecentActivityCard.listKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < items.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 12),
          _ActivityRow(item: items[i], now: now),
        ],
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item, required this.now});

  final RecentActivityItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color dotColor = recentActivityOriginColor(item.origin);
    final String relative = formatRelativeTime(item.createdAt, now);

    return Semantics(
      container: true,
      button: true,
      label: '${item.summary}. $relative. Double-tap to open.',
      child: ExcludeSemantics(
        child: Material(
          color: careblazersColors.surfaceWarm,
          child: InkWell(
            key: RecentActivityCard.rowKey(item.id),
            onTap: () => context.push(item.route),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    // Nudge the dot down onto the summary's first line.
                    padding: const EdgeInsets.only(top: 6),
                    child: _OriginDot(
                      color: dotColor,
                      dotKey: RecentActivityCard.dotKey(item.id),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.summary,
                      style: textTheme.bodyLarge?.copyWith(
                        color: careblazersColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    relative,
                    style: textTheme.bodyMedium?.copyWith(
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

class _OriginDot extends StatelessWidget {
  const _OriginDot({required this.color, required this.dotKey});

  final Color color;
  final Key dotKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: dotKey,
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
      key: RecentActivityCard.emptyKey,
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
      key: RecentActivityCard.skeletonKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < recentActivityLimit; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 12),
          const _SkeletonRow(),
        ],
      ],
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        _SkeletonBlock(width: 12, height: 12, radius: 6),
        SizedBox(width: 12),
        Expanded(child: _SkeletonBlock(width: 200, height: 16, radius: 6)),
        SizedBox(width: 12),
        _SkeletonBlock(width: 56, height: 12, radius: 6),
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

/// A coarse "20 min ago" / "in 2 days" relative stamp for the feed.
///
/// Buckets the gap between [at] and [now] into minutes, hours, days, then
/// weeks, with anything under a minute reading "just now". A past [at]
/// renders "<n> ago"; a future [at] (an upcoming appointment, since the
/// appointment timeline position is its `startsAt`) renders "in <n>".
/// Pure so the bucket boundaries are unit-testable without a widget tree.
@visibleForTesting
String formatRelativeTime(DateTime at, DateTime now) {
  final int deltaSeconds = now.difference(at).inSeconds;
  final int seconds = deltaSeconds.abs();
  if (seconds < 60) return 'just now';
  final String magnitude = _relativeMagnitude(seconds);
  return deltaSeconds >= 0 ? '$magnitude ago' : 'in $magnitude';
}

String _relativeMagnitude(int seconds) {
  final int minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes min';
  final int hours = minutes ~/ 60;
  if (hours < 24) return hours == 1 ? '1 hr' : '$hours hrs';
  final int days = hours ~/ 24;
  if (days < 7) return days == 1 ? '1 day' : '$days days';
  final int weeks = days ~/ 7;
  return weeks == 1 ? '1 wk' : '$weeks wks';
}
