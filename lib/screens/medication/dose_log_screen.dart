import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/medication.dart';
import '../../services/medication_repository.dart';
import '../../theme.dart';

part 'dose_log_screen.g.dart';

/// Wall clock the dose-log screen consults for "today" + "right now"
/// stamps on caregiver-initiated log writes (TASKS.md Phase 12.4).
///
/// Overridable for widget + golden tests so the date the screen queries
/// stays pinned across hosts (the medication-list screen overrides its
/// own `medicationListClockProvider` for the same reason).
@Riverpod(keepAlive: true)
DateTime Function() doseLogClock(Ref ref) => DateTime.now;

/// Mint a [DoseLog.id] when the caregiver checks a previously-unlogged
/// dose off. Overridable for tests so the id sequence is monotonic and
/// dose-log rows compare equal across runs.
typedef DoseLogIdFactory = String Function();

String _defaultDoseLogIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'log-$ms-$rand';
}

@Riverpod(keepAlive: true)
DoseLogIdFactory doseLogIdFactory(Ref ref) => _defaultDoseLogIdFactory;

/// Today's doses, expanded from every active schedule + joined with the
/// matching [DoseLog] (when one exists), sorted chronologically.
///
/// Watched by [DoseLogScreen]. The repository call is keyed on the
/// local-calendar day of [doseLogClockProvider]'s current sample so the
/// screen never falls off "today" mid-session — a fresh invalidate
/// after a mutation re-runs against the same day.
@riverpod
Future<List<ScheduledDose>> dosesToday(Ref ref) async {
  final MedicationRepository repo =
      ref.watch(medicationRepositoryBackendProvider);
  final DateTime now = ref.watch(doseLogClockProvider)();
  return repo.dosesByDay(now);
}

/// Cutoff in minutes past a dose's scheduled time after which "Mark
/// taken" records a [DoseStatus.late] instead of [DoseStatus.taken]. A
/// fixed 30 minutes matches the typical "took it within a half hour" UX
/// affordance — anything past that is medically late enough to
/// distinguish in the adherence-rate display (TASKS.md Phase 12.2).
const int _lateThresholdMinutes = 30;

/// Returns the [DoseStatus] a fresh "Mark taken" tap should record at
/// [now] for a dose scheduled at [scheduledFor]. Used by both the
/// per-row CTA and the bulk-action handler.
DoseStatus markTakenStatusFor(DateTime scheduledFor, DateTime now) {
  final Duration elapsed = now.difference(scheduledFor);
  if (elapsed.inMinutes > _lateThresholdMinutes) return DoseStatus.late;
  return DoseStatus.taken;
}

/// "Today's doses" screen at `/medications/today` (TASKS.md Phase 12.4).
///
/// One chronological row per dose scheduled today. Three row states:
///
///   - **Upcoming / unlogged** — checkbox + "Mark taken" CTA. Tapping
///     either stamps a [DoseLog] (status [DoseStatus.taken] or
///     [DoseStatus.late] depending on [markTakenStatusFor]).
///   - **Logged taken / late** — checkmark icon, a small "Late" badge
///     when the status is [DoseStatus.late]. Tap opens a bottom sheet
///     to change status (taken → late, skipped → taken, etc.) per the
///     phase spec.
///   - **Skipped / missed** — status icon + label. Same bottom sheet
///     on tap.
///
/// A "Mark all before noon taken" button at the top batches the morning
/// rows in one shot — the most common caregiver pattern is "I gave
/// every morning med at once". The button is hidden when no
/// before-noon doses are pending so the UI never invites a no-op tap.
class DoseLogScreen extends ConsumerWidget {
  const DoseLogScreen({super.key});

  static const Key listKey = Key('dose-log-list');
  static const Key emptyStateKey = Key('dose-log-empty');
  static const Key bulkMorningButtonKey = Key('dose-log-bulk-morning');

  /// Stable per-row key derived from the (medicationId, scheduledFor)
  /// pair — schedule id alone collides when one med carries multiple
  /// dose times the same day.
  static Key rowKey(String medicationId, DateTime scheduledFor) =>
      Key('dose-log-row-$medicationId-${scheduledFor.millisecondsSinceEpoch}');

  static Key markTakenButtonKey(
          String medicationId, DateTime scheduledFor) =>
      Key('dose-log-mark-$medicationId-'
          '${scheduledFor.millisecondsSinceEpoch}');

  static Key lateBadgeKey(String medicationId, DateTime scheduledFor) =>
      Key('dose-log-late-$medicationId-'
          '${scheduledFor.millisecondsSinceEpoch}');

  static Key statusSheetOptionKey(DoseStatus status) =>
      Key('dose-log-status-${status.name}');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ScheduledDose>> async =
        ref.watch(dosesTodayProvider);

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text("Today's doses"),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (List<ScheduledDose> doses) {
            if (doses.isEmpty) return const _EmptyState();
            return _PopulatedList(doses: doses);
          },
        ),
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
      key: DoseLogScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.check_circle_outline,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'Nothing scheduled today.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "When a medication's schedule lands on today, doses will "
            'appear here as a checklist.',
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PopulatedList extends ConsumerWidget {
  const _PopulatedList({required this.doses});

  final List<ScheduledDose> doses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<ScheduledDose> beforeNoonPending = doses
        .where((ScheduledDose d) =>
            d.scheduledFor.hour < 12 && _isPendingForBulk(d))
        .toList(growable: false);
    final bool showBulk = beforeNoonPending.isNotEmpty;

    return ListView.builder(
      key: DoseLogScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: doses.length + (showBulk ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (showBulk && index == 0) {
          return _BulkMorningButton(
            pendingCount: beforeNoonPending.length,
            onPressed: () =>
                _markMorningTaken(context, ref, beforeNoonPending),
          );
        }
        final int doseIndex = showBulk ? index - 1 : index;
        return _DoseRow(dose: doses[doseIndex]);
      },
    );
  }
}

/// True when the dose hasn't been resolved by the caregiver yet —
/// either no log row at all or one in [DoseStatus.missed]. Taken / late
/// / skipped are explicit caregiver decisions the bulk action shouldn't
/// overwrite.
bool _isPendingForBulk(ScheduledDose dose) {
  final DoseLog? log = dose.log;
  if (log == null) return true;
  return log.status == DoseStatus.missed;
}

Future<void> _markMorningTaken(
  BuildContext context,
  WidgetRef ref,
  List<ScheduledDose> pending,
) async {
  final MedicationRepository repo =
      ref.read(medicationRepositoryBackendProvider);
  final DateTime now = ref.read(doseLogClockProvider)();
  final DoseLogIdFactory mint = ref.read(doseLogIdFactoryProvider);

  for (final ScheduledDose dose in pending) {
    final DoseStatus status =
        markTakenStatusFor(dose.scheduledFor, now);
    final DoseLog log = DoseLog(
      id: dose.log?.id ?? mint(),
      medicationId: dose.medication.id,
      scheduledFor: dose.scheduledFor,
      takenAt: now,
      status: status,
    );
    await repo.upsertDoseLog(log);
  }
  ref.invalidate(dosesTodayProvider);
}

class _BulkMorningButton extends StatelessWidget {
  const _BulkMorningButton({
    required this.pendingCount,
    required this.onPressed,
  });

  final int pendingCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String label = pendingCount == 1
        ? 'Mark the morning dose taken'
        : 'Mark all $pendingCount morning doses taken';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Semantics(
        button: true,
        label: '$label. Marks every dose scheduled before noon as taken.',
        child: OutlinedButton.icon(
          key: DoseLogScreen.bulkMorningButtonKey,
          onPressed: onPressed,
          icon: const Icon(Icons.done_all),
          label: Text(
            label,
            style: textTheme.labelLarge?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            foregroundColor: careblazersColors.primary,
            side: BorderSide(
              color: careblazersColors.primary.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }
}

class _DoseRow extends ConsumerWidget {
  const _DoseRow({required this.dose});

  final ScheduledDose dose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Medication med = dose.medication;
    final DoseLog? log = dose.log;
    final bool logged = log != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        label: _rowSemanticsLabel(dose),
        child: Material(
          color: careblazersColors.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: DoseLogScreen.rowKey(med.id, dose.scheduledFor),
            borderRadius: BorderRadius.circular(16),
            onTap: logged
                ? () => _openStatusSheet(context, ref, dose)
                : () => _markTaken(ref, dose),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  _LeadingIndicator(dose: dose),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            Text(
                              _formatClock(dose.scheduledFor),
                              style: textTheme.bodyMedium?.copyWith(
                                color: careblazersColors.primarySoft,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (logged && log.status == DoseStatus.late)
                              _LateBadge(
                                key: DoseLogScreen.lateBadgeKey(
                                    med.id, dose.scheduledFor),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          med.name,
                          style: textTheme.titleLarge?.copyWith(
                            color: careblazersColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          med.dosage,
                          style: textTheme.bodyMedium?.copyWith(
                            color: careblazersColors.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (!logged)
                    _MarkTakenButton(
                      onPressed: () => _markTaken(ref, dose),
                      buttonKey: DoseLogScreen.markTakenButtonKey(
                          med.id, dose.scheduledFor),
                    )
                  else
                    _StatusTrailing(status: log.status),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _markTaken(WidgetRef ref, ScheduledDose dose) async {
  final MedicationRepository repo =
      ref.read(medicationRepositoryBackendProvider);
  final DateTime now = ref.read(doseLogClockProvider)();
  final DoseLogIdFactory mint = ref.read(doseLogIdFactoryProvider);
  final DoseStatus status = markTakenStatusFor(dose.scheduledFor, now);
  final DoseLog log = DoseLog(
    id: dose.log?.id ?? mint(),
    medicationId: dose.medication.id,
    scheduledFor: dose.scheduledFor,
    takenAt: now,
    status: status,
  );
  await repo.upsertDoseLog(log);
  ref.invalidate(dosesTodayProvider);
}

Future<void> _setStatus(
  WidgetRef ref,
  ScheduledDose dose,
  DoseStatus status,
) async {
  final MedicationRepository repo =
      ref.read(medicationRepositoryBackendProvider);
  final DateTime now = ref.read(doseLogClockProvider)();
  final DoseLogIdFactory mint = ref.read(doseLogIdFactoryProvider);
  final DateTime? takenAt =
      (status == DoseStatus.taken || status == DoseStatus.late) ? now : null;
  final DoseLog log = DoseLog(
    id: dose.log?.id ?? mint(),
    medicationId: dose.medication.id,
    scheduledFor: dose.scheduledFor,
    takenAt: takenAt,
    status: status,
  );
  await repo.upsertDoseLog(log);
  ref.invalidate(dosesTodayProvider);
}

Future<void> _openStatusSheet(
  BuildContext context,
  WidgetRef ref,
  ScheduledDose dose,
) async {
  final DoseStatus? next = await showModalBottomSheet<DoseStatus>(
    context: context,
    builder: (BuildContext sheetContext) => _StatusSheet(dose: dose),
    backgroundColor: careblazersColors.background,
  );
  if (next == null) return;
  await _setStatus(ref, dose, next);
}

class _StatusSheet extends StatelessWidget {
  const _StatusSheet({required this.dose});

  final ScheduledDose dose;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Text(
                'Update ${dose.medication.name}',
                style: textTheme.titleLarge?.copyWith(
                  color: careblazersColors.primary,
                ),
              ),
            ),
            for (final DoseStatus s in DoseStatus.values)
              _StatusOptionTile(
                status: s,
                selected: dose.log?.status == s,
                onTap: () => Navigator.of(context).pop(s),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusOptionTile extends StatelessWidget {
  const _StatusOptionTile({
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final DoseStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return ListTile(
      key: DoseLogScreen.statusSheetOptionKey(status),
      onTap: onTap,
      leading: Icon(
        _iconFor(status),
        color: _colorFor(status),
      ),
      title: Text(
        _labelFor(status),
        style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
      ),
      trailing: selected
          ? Icon(Icons.check, color: careblazersColors.success)
          : null,
    );
  }
}

class _LeadingIndicator extends StatelessWidget {
  const _LeadingIndicator({required this.dose});

  final ScheduledDose dose;

  @override
  Widget build(BuildContext context) {
    final DoseLog? log = dose.log;
    if (log == null) {
      return Icon(
        Icons.check_box_outline_blank,
        color: careblazersColors.primarySoft,
        size: 28,
      );
    }
    return Icon(_iconFor(log.status), color: _colorFor(log.status), size: 28);
  }
}

class _StatusTrailing extends StatelessWidget {
  const _StatusTrailing({required this.status});

  final DoseStatus status;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      _labelFor(status),
      style: textTheme.bodyMedium?.copyWith(
        color: _colorFor(status),
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _MarkTakenButton extends StatelessWidget {
  const _MarkTakenButton({
    required this.onPressed,
    required this.buttonKey,
  });

  final VoidCallback onPressed;
  final Key buttonKey;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Mark taken.',
      child: ElevatedButton(
        key: buttonKey,
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: careblazersColors.cta,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          minimumSize: const Size(0, 44),
        ),
        child: Text(
          'Mark taken',
          style: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

class _LateBadge extends StatelessWidget {
  const _LateBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: careblazersColors.accentDeep.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Late',
        style: textTheme.bodyMedium?.copyWith(
          color: careblazersColors.accentDeep,
          fontWeight: FontWeight.w700,
          fontSize: 12,
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
          "We couldn't load today's doses.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting + label helpers
// ---------------------------------------------------------------------------

String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}

String _labelFor(DoseStatus status) {
  switch (status) {
    case DoseStatus.taken:
      return 'Taken';
    case DoseStatus.late:
      return 'Taken late';
    case DoseStatus.skipped:
      return 'Skipped';
    case DoseStatus.missed:
      return 'Missed';
  }
}

IconData _iconFor(DoseStatus status) {
  switch (status) {
    case DoseStatus.taken:
    case DoseStatus.late:
      return Icons.check_box;
    case DoseStatus.skipped:
      return Icons.remove_circle_outline;
    case DoseStatus.missed:
      return Icons.error_outline;
  }
}

Color _colorFor(DoseStatus status) {
  switch (status) {
    case DoseStatus.taken:
      return careblazersColors.success;
    case DoseStatus.late:
      return careblazersColors.accentDeep;
    case DoseStatus.skipped:
      return careblazersColors.primarySoft;
    case DoseStatus.missed:
      return careblazersColors.error;
  }
}

String _rowSemanticsLabel(ScheduledDose dose) {
  final String clock = _formatClock(dose.scheduledFor);
  final Medication med = dose.medication;
  final DoseLog? log = dose.log;
  if (log == null) {
    return '${med.name}, ${med.dosage} at $clock. Not yet logged. '
        'Double-tap to mark taken.';
  }
  return '${med.name}, ${med.dosage} at $clock. '
      'Status: ${_labelFor(log.status)}. Double-tap to change.';
}
