import 'dart:convert';

import 'package:flutter/material.dart';
// `Provider` in [models/appointment.dart] collides with riverpod's own
// `Provider` class — `hide` keeps the model name resolvable here without
// aliasing every callsite, the same way the sibling dashboard cards do.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/appointment.dart';
import '../../models/journal_entry.dart';
import '../../models/medication.dart';
import '../../providers/home_clock_provider.dart';
import '../../providers/journal_entries_provider.dart';
import '../../providers/llm_provider.dart';
// The card reads each source through the same seam its owning surface
// reads through — the journal stream, the dose-log "today" provider, and
// the appointment repository — so "what the recap mentions" and "what the
// rest of the dashboard shows" stay in lock-step.
import '../../screens/medication/dose_log_screen.dart' show dosesTodayProvider;
import '../../services/appointment_repository.dart';
import '../../services/medication_repository.dart' show ScheduledDose;
import '../../theme.dart';

part 'catch_me_up_card.g.dart';

/// How far back the "catch me up" recap looks (Phase 14.12). The task's
/// 24-hour window, also passed to [LLMProvider.generateActivitySummary]
/// as `lastNHours`.
const int catchMeUpWindowHours = 24;

/// How long a generated summary stays fresh in shared_preferences (Phase
/// 14.12). Reopening Home inside this window returns the stored copy
/// rather than burning a generation per open.
const Duration catchMeUpCacheTtl = Duration(minutes: 30);

/// Prefix for the shared_preferences cache key. The full key is
/// `home.catch_me_up.${date.yyyyMMdd}.${hashOfEvents}` — the date scopes
/// the cache to a calendar day and the event hash busts it the moment
/// the underlying activity changes.
const String catchMeUpCachePrefix = 'home.catch_me_up';

/// The last [catchMeUpWindowHours] of activity, flattened to the narrow
/// [ActivityEvent] shape [CatchMeUp] feeds the LLM (Phase 14.12).
///
/// Aggregates the same three sources Recent Activity reads — the journal
/// stream, today's logged doses, and appointments — keeping only events
/// at or after the 24-hour cutoff, then sorts ascending by [occurredAt]
/// so the hash the card derives is stable across reopens. Care-team
/// handoffs ([ActivityEventKind.handoff]) join when Phase 14.32 ships;
/// none exist in v1.
@Riverpod(keepAlive: false)
Future<List<ActivityEvent>> catchMeUpEvents(Ref ref) async {
  final DateTime now = ref.watch(homeClockProvider)();
  final DateTime cutoff =
      now.subtract(const Duration(hours: catchMeUpWindowHours));

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

  final List<ActivityEvent> events = <ActivityEvent>[
    for (final JournalEntry e in entries)
      if (!e.createdAt.isBefore(cutoff))
        ActivityEvent(
          kind: ActivityEventKind.journal,
          summary: _journalSummary(e),
          occurredAt: e.createdAt,
        ),
    for (final ScheduledDose d in doses)
      if (d.log != null)
        if (!(d.log!.takenAt ?? d.log!.scheduledFor).isBefore(cutoff))
          ActivityEvent(
            kind: ActivityEventKind.dose,
            summary: _doseSummary(d),
            occurredAt: d.log!.takenAt ?? d.log!.scheduledFor,
          ),
    for (final Appointment a in appointments)
      if (!a.startsAt.isBefore(cutoff))
        ActivityEvent(
          kind: ActivityEventKind.appointment,
          summary: _appointmentSummary(providerById[a.providerId]),
          occurredAt: a.startsAt,
        ),
  ];

  events.sort((ActivityEvent a, ActivityEvent b) =>
      a.occurredAt.compareTo(b.occurredAt));
  return List<ActivityEvent>.unmodifiable(events);
}

/// One-line recap of a journal entry — the caregiver's own situation text,
/// or a plain "Journal note" when the entry has none. Mirrors the Recent
/// Activity row title so the recap and the feed name the same event the
/// same way.
String _journalSummary(JournalEntry entry) {
  final String? situation = entry.situationText?.trim();
  if (situation != null && situation.isNotEmpty) return situation;
  return 'Journal note';
}

/// One-line recap of an acted-on dose — "Gave Donepezil 10 mg", "Skipped
/// …", "Missed …" depending on the logged status. [dose.log] is expected
/// non-null (the aggregator filters unlogged doses out).
String _doseSummary(ScheduledDose dose) {
  final Medication med = dose.medication;
  final String verb = switch (dose.log?.status) {
    DoseStatus.skipped => 'Skipped',
    DoseStatus.missed => 'Missed',
    _ => 'Gave',
  };
  return '$verb ${med.name} ${med.dosage}';
}

/// One-line recap of an appointment, with a soft fallback when the
/// provider row is missing (deleted, or not yet resolved).
String _appointmentSummary(Provider? provider) =>
    'Appointment with ${provider?.name ?? 'your provider'}';

/// The Home "catch me up" summary (Phase 14.12).
///
/// On [build] it resolves the last-24h [catchMeUpEvents], then:
///   - returns an empty string when nothing happened (the card hides);
///   - returns the cached copy when shared_preferences holds a summary
///     for this event set that is younger than [catchMeUpCacheTtl];
///   - otherwise streams a fresh summary from [llmProvider], caches it,
///     and returns the whole paragraph.
///
/// [regenerate] forces a fresh generation past the cache for the refresh
/// affordance. Cache reads/writes go through shared_preferences keyed by
/// the calendar day + an event hash so the same activity reopens to the
/// same copy without re-invoking the provider.
@Riverpod(keepAlive: false)
class CatchMeUp extends _$CatchMeUp {
  @override
  Future<String> build() async {
    final List<ActivityEvent> events =
        await ref.watch(catchMeUpEventsProvider.future);
    return _resolve(events: events, useCache: true);
  }

  /// Force a fresh summary past the 30-minute cache (the card's refresh
  /// action). Surfaces a loading state while the new paragraph streams,
  /// then overwrites the cached copy.
  Future<void> regenerate() async {
    final List<ActivityEvent> events =
        await ref.read(catchMeUpEventsProvider.future);
    state = const AsyncValue<String>.loading();
    state = await AsyncValue.guard(
      () => _resolve(events: events, useCache: false),
    );
  }

  Future<String> _resolve({
    required List<ActivityEvent> events,
    required bool useCache,
  }) async {
    // Nothing to recap — the card renders nothing, and we never touch
    // prefs or the provider.
    if (events.isEmpty) return '';

    final DateTime now = ref.read(homeClockProvider)();
    final String key = catchMeUpCacheKey(now, catchMeUpEventsHash(events));
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    if (useCache) {
      final String? cached = _readFreshCache(prefs, key, now);
      if (cached != null) return cached;
    }

    final LLMProvider llm = ref.read(llmProvider);
    final StringBuffer buffer = StringBuffer();
    await for (final String accumulated in llm.generateActivitySummary(
      lastNHours: catchMeUpWindowHours,
      events: events,
    )) {
      buffer
        ..clear()
        ..write(accumulated);
    }
    final String summary = buffer.toString().trim();
    await _writeCache(prefs, key, summary, now);
    return summary;
  }

  /// Read the cached summary at [key] if it is still inside
  /// [catchMeUpCacheTtl] of [now]. Returns null on a miss, a malformed
  /// payload, or an expired stamp — every one of which means "regenerate".
  static String? _readFreshCache(
    SharedPreferences prefs,
    String key,
    DateTime now,
  ) {
    final String? raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final Map<String, dynamic> map =
          json.decode(raw) as Map<String, dynamic>;
      final DateTime generatedAt =
          DateTime.parse(map['generatedAt'] as String);
      if (now.difference(generatedAt).abs() > catchMeUpCacheTtl) return null;
      return map['summary'] as String;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeCache(
    SharedPreferences prefs,
    String key,
    String summary,
    DateTime now,
  ) async {
    await prefs.setString(
      key,
      json.encode(<String, String>{
        'summary': summary,
        'generatedAt': now.toIso8601String(),
      }),
    );
  }
}

/// Stable fingerprint of [events] for the cache key (Phase 14.12).
///
/// Joins each event's [ActivityEvent.cacheToken] and runs it through a
/// 32-bit FNV-1a hash. Deliberately *not* `Object.hashAll` — Dart's
/// string `hashCode` is salted per isolate run, so it would change across
/// app launches and never hit the cache. FNV-1a is content-stable.
String catchMeUpEventsHash(List<ActivityEvent> events) {
  final String canonical =
      events.map((ActivityEvent e) => e.cacheToken).join('');
  return _fnv1a32Hex(canonical);
}

/// The shared_preferences key for [now]'s calendar day + the event
/// [hash]: `home.catch_me_up.${yyyyMMdd}.${hash}`.
String catchMeUpCacheKey(DateTime now, String hash) =>
    '$catchMeUpCachePrefix.${_yyyyMMdd(now)}.$hash';

String _yyyyMMdd(DateTime d) {
  final String y = d.year.toString().padLeft(4, '0');
  final String m = d.month.toString().padLeft(2, '0');
  final String day = d.day.toString().padLeft(2, '0');
  return '$y$m$day';
}

String _fnv1a32Hex(String s) {
  int hash = 0x811c9dc5;
  for (final int c in s.codeUnits) {
    hash ^= c;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// The "Catch me up" dashboard card — an optional row above Recent
/// Activity on the Home "Today" scroll (BUILD_SPEC.md §5.18, Phase
/// 14.12).
///
/// Watches [catchMeUpProvider] and renders the streamed single-paragraph
/// recap of the last 24 hours with a refresh action. When nothing has
/// happened the card paints nothing — it is genuinely optional, so an
/// empty day doesn't leave a hollow card on the dashboard.
///
/// State surfaces match the sibling cards:
///   - **loading** — shimmer text lines while the recap streams;
///   - **empty** — the card collapses to nothing;
///   - **error** — one muted line; Home never throws a red box at a
///     caregiver mid-crisis.
class CatchMeUpCard extends ConsumerWidget {
  const CatchMeUpCard({super.key});

  /// Test/golden handle for the whole card.
  static const Key cardKey = Key('home-catch-me-up-card');

  /// The streamed/loaded recap paragraph.
  static const Key summaryKey = Key('home-catch-me-up-summary');

  /// The loading skeleton body.
  static const Key skeletonKey = Key('home-catch-me-up-skeleton');

  /// The refresh affordance.
  static const Key refreshKey = Key('home-catch-me-up-refresh');

  static const double _radius = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<String> async = ref.watch(catchMeUpProvider);

    // An empty recap means "nothing to catch up on" — collapse the card
    // entirely rather than leaving a hollow shell on the dashboard.
    if (async.asData?.value.isEmpty ?? false) {
      return const SizedBox.shrink();
    }

    final Widget body = async.when(
      loading: () => const _SkeletonBody(),
      error: (Object _, StackTrace __) => const _MessageBody(
        message: "We couldn't put together your recap just now.",
      ),
      data: (String summary) => _SummaryBody(summary: summary),
    );

    final bool canRefresh = !async.isLoading;

    // The card owns the gap below it (the Home scroll places it with no
    // trailing spacer) so a hidden card on a quiet day collapses to zero
    // height — the dashboard reads identically to having no card at all.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: context.cb.surfaceWarm,
        borderRadius: BorderRadius.circular(_radius),
        child: Padding(
          key: cardKey,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Header(
                onRefresh: canRefresh
                    ? () => ref.read(catchMeUpProvider.notifier).regenerate()
                    : null,
              ),
              const SizedBox(height: 12),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onRefresh});

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(
            'Catch me up',
            style: textTheme.titleLarge?.copyWith(
              color: context.cb.primary,
            ),
          ),
        ),
        IconButton(
          key: CatchMeUpCard.refreshKey,
          icon: const Icon(Icons.refresh),
          iconSize: 22,
          color: context.cb.primary,
          tooltip: 'Refresh recap',
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

class _SummaryBody extends StatelessWidget {
  const _SummaryBody({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      summary,
      key: CatchMeUpCard.summaryKey,
      style: textTheme.bodyLarge?.copyWith(
        color: context.cb.text,
        height: 1.4,
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
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        message,
        style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
      ),
    );
  }
}

class _SkeletonBody extends StatelessWidget {
  const _SkeletonBody();

  @override
  Widget build(BuildContext context) {
    return const Column(
      key: CatchMeUpCard.skeletonKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _SkeletonBlock(widthFactor: 1, height: 14),
        SizedBox(height: 8),
        _SkeletonBlock(widthFactor: 1, height: 14),
        SizedBox(height: 8),
        _SkeletonBlock(widthFactor: 0.6, height: 14),
      ],
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({required this.widthFactor, required this.height});

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          // A faint tint of the brand navy reads as a placeholder against
          // the warm-white card without introducing an off-palette grey.
          color: context.cb.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}
