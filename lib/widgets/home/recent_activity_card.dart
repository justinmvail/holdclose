import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/care_event.dart';
import '../../providers/home_clock_provider.dart';
import '../../providers/patient_timeline_provider.dart';
import '../../theme.dart';

part 'recent_activity_card.g.dart';

/// How many rows the Recent Activity card surfaces (BUILD_SPEC.md §5.18,
/// Phase 14.11). The latest three events across every source, merged.
const int recentActivityLimit = 3;

/// The kinds the Home Recent Activity card surfaces today (BUILD_SPEC.md
/// §5.18). Acted-on doses, journal entries, and appointments. Forecast
/// (unlogged) doses live on the Medications Today card; health-log
/// entries + team-scoped kinds are filtered out for parity with the
/// pre-unified behaviour. Promoting one is a one-line change here.
const Set<CareEventKind> recentActivityKinds = <CareEventKind>{
  CareEventKind.journalEntry,
  CareEventKind.doseLogged,
  CareEventKind.appointment,
};

/// The merged Recent Activity feed for the Home dashboard (Phase 14.11).
///
/// Reads the chronologically-ordered patient-scoped events from
/// [patientTimelineEventsProvider] — the single source of truth for the
/// "what's happening with this patient" merge — filters to the kinds
/// the dashboard counts as "activity", and returns the newest
/// [recentActivityLimit] of them in descending order.
///
/// The card no longer has its own per-source aggregator; every consumer
/// of the patient timeline (this card + Med Schedule + any future Today
/// view) reads the same provider and gets the same merge guarantees.
/// Rich row text ("Gave Donepezil 10 mg", "Appointment with Dr. Ortega",
/// a wizard journal's situation text) is baked into [CareEvent.subtitle]
/// by the projection helpers in [patientTimelineEventsProvider], so this
/// provider is now a thin filter + take.
@Riverpod(keepAlive: false)
Future<List<CareEvent>> recentActivity(Ref ref) async {
  final List<CareEvent> events =
      await ref.watch(patientTimelineEventsProvider.future);
  final List<CareEvent> filtered = <CareEvent>[
    for (final CareEvent e in events)
      if (recentActivityKinds.contains(e.kind)) e,
  ];
  // Timeline is ascending by start; reverse to get newest-first, then
  // cap at the dashboard's limit.
  final List<CareEvent> topDesc = filtered.reversed
      .take(recentActivityLimit)
      .toList(growable: false);
  return List<CareEvent>.unmodifiable(topDesc);
}

/// The "Recent Activity" dashboard card — the fifth row of the Home
/// "Today" scroll (BUILD_SPEC.md §5.18, Phase 14.11).
///
/// Watches [recentActivityProvider] and renders the latest
/// [recentActivityLimit] events across the journal, dose log, and
/// appointments (care-team handoffs join in Phase 14.32). Each row is
/// its own tap target — unlike the single-destination Medications /
/// Next Appointment cards — because the rows route to different
/// sources:
///   - an **origin-color dot** (plum=journal, teal=dose, coral=
///     appointment, navy=team);
///   - a one-line **summary** ([CareEvent.subtitle] when populated;
///     falls back to [CareEvent.title]);
///   - a trailing **relative time** ("20 min ago").
///
/// Tapping a row pushes that event's [CareEventX.detailRoute].
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

  /// Stable per-row key — the [CareEvent.id] from the unified timeline.
  static Key rowKey(String eventId) => Key('home-recent-activity-row-$eventId');

  /// The origin dot for a row — tests read its color to assert the
  /// per-kind hue.
  static Key dotKey(String eventId) =>
      Key('home-recent-activity-dot-$eventId');

  // Per-kind hues (Phase 14.11). The dose teal + appointment coral
  // match the Medications Today / Next Appointment status dots so the
  // dashboard shares one color language; journal plum is the new hue
  // for this card, and team resolves to brand navy (see
  // [recentActivityKindColor]).
  static const Color journalColor = Color(0xFF7B4B94); // plum
  static const Color doseColor = Color(0xFF1F8A70); // teal
  static const Color appointmentColor = Color(0xFFE5573F); // coral

  static const double _radius = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CareEvent>> async =
        ref.watch(recentActivityProvider);
    final DateTime now = ref.watch(homeClockProvider)();

    final Widget body = async.when(
      loading: () => const _SkeletonBody(),
      error: (Object _, StackTrace __) => const _MessageBody(
        message: "We couldn't load your recent activity.",
      ),
      data: (List<CareEvent> events) {
        if (events.isEmpty) {
          return const _MessageBody(message: 'No recent activity yet.');
        }
        return _ActivityList(events: events, now: now);
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

/// The origin-dot color for [kind] (BUILD_SPEC.md §5.18). Shared by
/// the Recent Activity card and the Schedule card so the two dashboard
/// surfaces use one color language; also lets tests assert the plum /
/// teal / coral / navy mapping without reaching into private state.
Color recentActivityKindColor(CareEventKind kind) {
  switch (kind) {
    case CareEventKind.journalEntry:
      return RecentActivityCard.journalColor;
    case CareEventKind.doseLogged:
    case CareEventKind.doseScheduled:
      return RecentActivityCard.doseColor;
    case CareEventKind.appointment:
      return RecentActivityCard.appointmentColor;
    // Health-log entries + team-scoped kinds aren't surfaced today;
    // resolve to navy so a future promotion of any of them gets a
    // legible hue without re-touching this helper.
    case CareEventKind.healthLogEntry:
    case CareEventKind.carePlanItem:
    case CareEventKind.task:
    case CareEventKind.shift:
    case CareEventKind.note:
      return careblazersColors.primary;
  }
}

/// Best display text for an activity row: the rich pre-formatted
/// subtitle when the projection helper populated it; otherwise the
/// shorter title. Exposed for tests.
@visibleForTesting
String recentActivityRowText(CareEvent event) =>
    (event.subtitle?.isNotEmpty ?? false) ? event.subtitle! : event.title;

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
  const _ActivityList({required this.events, required this.now});

  final List<CareEvent> events;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: RecentActivityCard.listKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < events.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 12),
          _ActivityRow(event: events[i], now: now),
        ],
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.event, required this.now});

  final CareEvent event;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color dotColor = recentActivityKindColor(event.kind);
    final String relative = formatRelativeTime(event.start, now);
    final String text = recentActivityRowText(event);
    final String? route = event.detailRoute;

    return Semantics(
      container: true,
      button: route != null,
      label: '$text. $relative. Double-tap to open.',
      child: ExcludeSemantics(
        child: Material(
          color: careblazersColors.surfaceWarm,
          child: InkWell(
            key: RecentActivityCard.rowKey(event.id),
            onTap: route == null ? null : () => context.push(route),
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
                      dotKey: RecentActivityCard.dotKey(event.id),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      text,
                      style: textTheme.bodyLarge?.copyWith(
                        color: careblazersColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      relative,
                      style: textTheme.bodyMedium?.copyWith(
                        color: careblazersColors.primarySoft,
                        fontWeight: FontWeight.w500,
                      ),
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
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _SkeletonBody extends StatelessWidget {
  const _SkeletonBody();

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: RecentActivityCard.skeletonKey,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < 3; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: careblazersColors.background,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    height: 14,
                    decoration: BoxDecoration(
                      color: careblazersColors.background,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: RecentActivityCard.emptyKey,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: textTheme.bodyMedium?.copyWith(
          color: careblazersColors.primarySoft,
        ),
      ),
    );
  }
}

/// Render a wall-clock anchor as a relative phrase against [now].
/// Future timestamps are framed "in 2 days" / "in 30 min"; past ones,
/// "20 min ago" / "yesterday". Same shape the next-appointment card
/// uses for parity.
@visibleForTesting
String formatRelativeTime(DateTime when, DateTime now) {
  final Duration diff = when.difference(now);
  final bool isFuture = diff.inSeconds > 0;
  final Duration abs = diff.abs();
  String suffix(String phrase) => isFuture ? 'in $phrase' : '$phrase ago';
  if (abs.inMinutes < 1) return 'just now';
  if (abs.inHours < 1) return suffix('${abs.inMinutes} min');
  if (abs.inHours < 24) {
    final int h = abs.inHours;
    return suffix(h == 1 ? '1 hr' : '$h hrs');
  }
  if (abs.inDays < 2) return isFuture ? 'tomorrow' : 'yesterday';
  return suffix('${abs.inDays} days');
}
