import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/medication.dart';
import '../../services/medication_repository.dart';
import '../../theme.dart';

part 'medication_list_screen.g.dart';

/// One row in the medication list — a [Medication] joined with the next
/// scheduled dose and the trailing 7-day adherence score (TASKS.md Phase
/// 12.3).
///
/// [nextDose] is null when the medication has no upcoming dose in the
/// next 30 days (paused schedule, as-needed only, or no schedule yet).
/// [adherenceLast7Days] is `1.0` when no scoreable doses exist in the
/// trailing window — same fallback as
/// [MedicationRepository.adherenceRate], so the list chip renders "—"
/// without a special-case branch.
@immutable
class MedicationListItem {
  const MedicationListItem({
    required this.medication,
    required this.nextDose,
    required this.adherenceLast7Days,
    required this.hasScoreableHistory,
  });

  final Medication medication;
  final DateTime? nextDose;
  final double adherenceLast7Days;

  /// True iff the trailing 7-day window had at least one taken/late/missed
  /// dose. Lets the chip distinguish "100% — perfect" from "no data yet"
  /// (both return 1.0 from `adherenceRate` per its contract).
  final bool hasScoreableHistory;
}

/// Async list of medications enriched with each med's next upcoming dose
/// and its trailing 7-day adherence rate (TASKS.md Phase 12.3).
///
/// Watched by [MedicationListScreen]. Tests override
/// [medicationRepositoryBackendProvider] with an in-memory drift-backed
/// [MedicationRepository] so the future resolves synchronously inside
/// the test harness. The form (Phase 12.3) invalidates this provider
/// after a successful insert so the list reflects the new med.
@Riverpod(keepAlive: false)
Future<List<MedicationListItem>> medicationList(Ref ref) async {
  final MedicationRepository repo =
      ref.watch(medicationRepositoryBackendProvider);
  final List<Medication> meds = await repo.listMedications();

  // Walk upcoming doses once; the first occurrence per med id is the
  // "next" dose (the repository returns them ascending by scheduledFor).
  final List<ScheduledDose> upcoming =
      await repo.upcomingDoses(within: const Duration(days: 30));
  final Map<String, DateTime> nextByMed = <String, DateTime>{};
  for (final ScheduledDose d in upcoming) {
    nextByMed.putIfAbsent(d.medication.id, () => d.scheduledFor);
  }

  final List<MedicationListItem> out = <MedicationListItem>[];
  for (final Medication m in meds) {
    final double rate = await repo.adherenceRate(
      forMedication: m.id,
      window: const Duration(days: 7),
    );
    final List<DoseLog> logs = await repo.logsFor(m.id);
    final bool hasScoreable = logs.any((DoseLog l) =>
        l.status == DoseStatus.taken ||
        l.status == DoseStatus.late ||
        l.status == DoseStatus.missed);
    out.add(MedicationListItem(
      medication: m,
      nextDose: nextByMed[m.id],
      adherenceLast7Days: rate,
      hasScoreableHistory: hasScoreable,
    ));
  }
  return out;
}

/// Wall clock the list screen samples when formatting "Today / Tomorrow"
/// next-dose subtitles. Overridable so widget tests and goldens stay
/// stable across host time.
@Riverpod(keepAlive: true)
DateTime Function() medicationListClock(Ref ref) => DateTime.now;

/// Medication list screen at `/medications` (TASKS.md Phase 12.3).
///
/// Two states:
///   - Empty: a soft headline + a single salmon "Add a medication" CTA.
///   - Populated: one tile per medication showing the name, dosage, the
///     next scheduled dose, and a 7-day adherence chip. The salmon FAB
///     in the lower-right pushes the add-med form.
///
/// The screen never reaches into the database directly — it reads
/// through [medicationListProvider] and the form (Phase 12.3) writes
/// through [medicationRepositoryProvider], same indirection the other
/// repository-backed surfaces use.
class MedicationListScreen extends ConsumerWidget {
  const MedicationListScreen({super.key});

  static const Key listKey = Key('medication-list-list');
  static const Key emptyStateKey = Key('medication-list-empty');
  static const Key emptyCtaKey = Key('medication-list-empty-cta');
  static const Key fabKey = Key('medication-list-fab');
  static const Key crisisActionKey = Key('medication-list-crisis-action');

  /// Stable per-tile key derived from the medication id. Tests tap by
  /// id rather than by visible name so a copy edit doesn't break them.
  static Key tileKey(String medicationId) =>
      Key('medication-list-tile-$medicationId');

  /// Stable per-tile key for the adherence chip — tests assert the
  /// percentage label without having to scope through the tile.
  static Key adherenceChipKey(String medicationId) =>
      Key('medication-list-adherence-$medicationId');

  /// Stable per-tile key for the "next dose" subtitle.
  static Key nextDoseKey(String medicationId) =>
      Key('medication-list-next-$medicationId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<MedicationListItem>> async =
        ref.watch(medicationListProvider);
    final DateTime now = ref.watch(medicationListClockProvider)();

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Medications'),
        actions: <Widget>[
          IconButton(
            key: MedicationListScreen.crisisActionKey,
            tooltip: 'Crisis card',
            icon: const Icon(Icons.warning_amber_outlined),
            onPressed: () => GoRouter.of(context).push('/crisis'),
          ),
        ],
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (List<MedicationListItem> items) {
            if (items.isEmpty) return const _EmptyState();
            return _PopulatedList(items: items, now: now);
          },
        ),
      ),
      floatingActionButton: async.maybeWhen(
        data: (List<MedicationListItem> items) {
          if (items.isEmpty) return null;
          return _AddMedFab(
            onPressed: () => context.push('/medications/new'),
          );
        },
        orElse: () => null,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: MedicationListScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.medication_outlined,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'No medications yet.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "Add what your loved one takes — name, dosage, when it's "
            'given. The schedule starts as daily at 8 AM; you can tune '
            'it from the medication card.',
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.text,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'Add a medication. Open the add-medication form.',
            child: ElevatedButton.icon(
              key: MedicationListScreen.emptyCtaKey,
              onPressed: () => context.push('/medications/new'),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                'Add a medication',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: careblazersColors.cta,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PopulatedList extends StatelessWidget {
  const _PopulatedList({required this.items, required this.now});

  final List<MedicationListItem> items;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: MedicationListScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        return _MedicationCard(item: items[index], now: now);
      },
    );
  }
}

class _MedicationCard extends StatelessWidget {
  const _MedicationCard({required this.item, required this.now});

  final MedicationListItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Medication med = item.medication;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        label: '${med.name}, ${med.dosage}. '
            'Adherence ${_adherenceLabel(item)} over the last 7 days.',
        child: Container(
          key: MedicationListScreen.tileKey(med.id),
          decoration: BoxDecoration(
            color: careblazersColors.surfaceWarm,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          med.name,
                          style: textTheme.titleLarge?.copyWith(
                            color: careblazersColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          med.dosage,
                          style: textTheme.bodyLarge?.copyWith(
                            color: careblazersColors.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _AdherenceChip(item: item),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                key: MedicationListScreen.nextDoseKey(med.id),
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  _nextDoseLabel(item.nextDose, now),
                  style: textTheme.bodyMedium?.copyWith(
                    color: careblazersColors.primarySoft,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdherenceChip extends StatelessWidget {
  const _AdherenceChip({required this.item});

  final MedicationListItem item;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color fg = _adherenceColor(item);
    return Container(
      key: MedicationListScreen.adherenceChipKey(item.medication.id),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _adherenceLabel(item),
        style: textTheme.bodyMedium?.copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AddMedFab extends StatelessWidget {
  const _AddMedFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add a medication. Open the add-medication form.',
      child: FloatingActionButton.extended(
        key: MedicationListScreen.fabKey,
        onPressed: onPressed,
        backgroundColor: careblazersColors.cta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Add medication',
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Colors.white),
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
          "We couldn't load the medication list.\n$message",
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

const List<String> _weekdayShort = <String>[
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
];

String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}

/// "Today, 8:00 AM" / "Tomorrow, 8:00 AM" / "Mon, 8:00 AM" / fallback for
/// a paused or as-needed schedule.
String _nextDoseLabel(DateTime? next, DateTime now) {
  if (next == null) return 'No upcoming dose scheduled.';
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime tomorrow = today.add(const Duration(days: 1));
  final DateTime nextDay = DateTime(next.year, next.month, next.day);
  final String clock = _formatClock(next);
  if (nextDay == today) return 'Next: Today, $clock';
  if (nextDay == tomorrow) return 'Next: Tomorrow, $clock';
  return 'Next: ${_weekdayShort[next.weekday - 1]}, $clock';
}

String _adherenceLabel(MedicationListItem item) {
  if (!item.hasScoreableHistory) return '—';
  final int pct = (item.adherenceLast7Days * 100).round();
  return '$pct%';
}

Color _adherenceColor(MedicationListItem item) {
  if (!item.hasScoreableHistory) return careblazersColors.primarySoft;
  final double rate = item.adherenceLast7Days;
  if (rate >= 0.8) return careblazersColors.success;
  if (rate >= 0.5) return careblazersColors.cta;
  return careblazersColors.accentDeep;
}
