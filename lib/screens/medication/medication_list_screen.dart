import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/medication.dart';
import '../../models/medication_draft.dart';
import '../../providers/active_patient_provider.dart';
import '../../providers/link_launcher_provider.dart';
import '../../providers/patient_timeline_provider.dart';
import '../../services/medication_repository.dart';
import '../../services/medication_supply.dart';
import '../../theme.dart';
import '../../widgets/form/format.dart';
import '../../widgets/path_header.dart';
import 'prescription_scan_flow.dart';

part 'medication_list_screen.g.dart';

/// One row in the medication list — a [Medication] joined with the
/// windows it's attached to and its trailing 7-day adherence score.
@immutable
class MedicationListItem {
  const MedicationListItem({
    required this.medication,
    required this.windows,
    required this.adherenceLast7Days,
    required this.hasScoreableHistory,
  });

  final Medication medication;

  /// Windows the medication is taken in, sorted by anchor time
  /// (as-needed last). Empty when the med has no entries — surfaced as
  /// "No window yet" in the UI so a half-set-up med stays visible.
  final List<DoseWindow> windows;

  final double adherenceLast7Days;
  final bool hasScoreableHistory;
}

/// Async list of medications enriched with each med's windows + a
/// trailing 7-day adherence rate.
@Riverpod(keepAlive: false)
Future<List<MedicationListItem>> medicationList(Ref ref) async {
  final MedicationRepository repo =
      ref.watch(medicationRepositoryBackendProvider);
  final String patientId = await ref.watch(activePatientIdProvider.future);
  final List<Medication> meds = await repo.listMedications();
  final List<DoseWindow> allWindows =
      await repo.windowsForPatient(patientId);
  final Map<String, DoseWindow> windowsById = <String, DoseWindow>{
    for (final DoseWindow w in allWindows) w.id: w,
  };

  final List<MedicationListItem> out = <MedicationListItem>[];
  for (final Medication m in meds) {
    final List<MedicationWindowEntry> entries =
        await repo.entriesForMedication(m.id);
    final List<DoseWindow> windows = <DoseWindow>[
      for (final MedicationWindowEntry e in entries)
        if (windowsById[e.windowId] != null) windowsById[e.windowId]!,
    ];
    windows.sort((DoseWindow a, DoseWindow b) {
      // Anchor-time ascending; as-needed last.
      if (a.isAsNeeded && !b.isAsNeeded) return 1;
      if (!a.isAsNeeded && b.isAsNeeded) return -1;
      if (a.isAsNeeded && b.isAsNeeded) return 0;
      final int am = a.anchorTime!.hour * 60 + a.anchorTime!.minute;
      final int bm = b.anchorTime!.hour * 60 + b.anchorTime!.minute;
      return am.compareTo(bm);
    });
    final double rate = await repo.adherenceRate(
      forMedication: m.id,
      window: const Duration(days: 7),
      patientId: patientId,
    );
    final List<DoseLog> logs = await repo.logsFor(m.id);
    final bool hasScoreable = logs.any((DoseLog l) =>
        l.status == DoseStatus.taken ||
        l.status == DoseStatus.late ||
        l.status == DoseStatus.missed);
    out.add(MedicationListItem(
      medication: m,
      windows: windows,
      adherenceLast7Days: rate,
      hasScoreableHistory: hasScoreable,
    ));
  }
  return out;
}

/// Wall clock the list screen samples. Overridable so widget tests
/// stay stable across host time.
@Riverpod(keepAlive: true)
DateTime Function() medicationListClock(Ref ref) => DateTime.now;

/// Medication list screen at `/medications`.
///
/// Flat alphabetical list of medications. Each row shows the name,
/// dosage, the windows it's taken in ("Morning · Bedtime"), and a 7-day
/// adherence chip. Tap → edit; long-press → soft-delete. The FAB pushes
/// the add-medication form, which carries a multi-window chip picker.
class MedicationListScreen extends ConsumerWidget {
  const MedicationListScreen({super.key});

  static const Key listKey = Key('medication-list-list');
  static const Key emptyStateKey = Key('medication-list-empty');
  static const Key emptyCtaKey = Key('medication-list-empty-cta');
  static const Key fabKey = Key('medication-list-fab');
  static const Key scanButtonKey = Key('medication-list-scan');

  /// The delete-confirmation dialog (a long-press on a med card).
  static const Key deleteDialogKey = Key('medication-list-delete-dialog');
  static const Key deleteConfirmKey = Key('medication-list-delete-confirm');
  static const Key deleteCancelKey = Key('medication-list-delete-cancel');
  static const Key deleteUndoSnackBarKey =
      Key('medication-list-delete-undo-snackbar');

  static Key tileKey(String medicationId) =>
      Key('medication-list-tile-$medicationId');
  static Key windowsKey(String medicationId) =>
      Key('medication-list-windows-$medicationId');
  static Key deleteIconKey(String medicationId) =>
      Key('medication-list-delete-$medicationId');
  static Key supplyKey(String medicationId) =>
      Key('medication-list-supply-$medicationId');
  static Key callPharmacyKey(String medicationId) =>
      Key('medication-list-call-$medicationId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<MedicationListItem>> async =
        ref.watch(medicationListProvider);

    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PathHeader(
                breadcrumbs: const <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Medications'),
                ],
                title: 'Medications',
                backLabel: 'Back to Care',
                leadingIcon: Icons.medication_outlined,
                // Per-screen actions — scan a prescription (AI photo →
                // human-approved import) and open the dose-window manager
                // (rename / re-anchor / delete windows without the form
                // picker).
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      key: MedicationListScreen.scanButtonKey,
                      tooltip: 'Scan a prescription',
                      iconSize: 24,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      visualDensity: VisualDensity.compact,
                      color: context.hc.primary,
                      icon: const Icon(Icons.document_scanner_outlined),
                      onPressed: () => _scanPrescription(context, ref),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      tooltip: 'Manage time windows',
                      iconSize: 24,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      visualDensity: VisualDensity.compact,
                      color: context.hc.primary,
                      icon: const Icon(Icons.schedule_outlined),
                      onPressed: () => context.push('/medications/windows'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) =>
                    _ErrorView(message: '$e'),
                data: (List<MedicationListItem> items) {
                  if (items.isEmpty) return const _EmptyState();
                  return _PopulatedList(items: items);
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: async.maybeWhen(
        data: (List<MedicationListItem> items) {
          if (items.isEmpty) return null;
          return FloatingActionButton.extended(
            key: MedicationListScreen.fabKey,
            heroTag: 'medications-add-fab',
            backgroundColor: context.hc.ctaFilled,
            foregroundColor: Theme.of(context).colorScheme.onSecondary,
            onPressed: () => context.push('/medications/new'),
            icon: const Icon(Icons.add),
            label: const Text('Add medication'),
          );
        },
        orElse: () => null,
      ),
    );
  }

  /// Scan a prescription: pick a photo, extract a [MedicationDraft] via
  /// the AI scanner, then open the review screen for human approval.
  /// Every path is guarded — a cancelled pick or an unreadable image
  /// still lands the caregiver on the (blank) review screen for manual
  /// entry, and nothing is saved without their explicit tap.
  Future<void> _scanPrescription(BuildContext context, WidgetRef ref) async {
    final MedicationDraft? draft = await capturePrescriptionDraft(context, ref);
    // null → the caregiver cancelled. Otherwise open the review screen even
    // on an empty read: the scan just saves typing, and they can still enter
    // the medication by hand.
    if (draft == null || !context.mounted) return;
    unawaited(context.push('/medications/scan/review', extra: draft));
  }
}

class _PopulatedList extends StatelessWidget {
  const _PopulatedList({required this.items});
  final List<MedicationListItem> items;
  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key: MedicationListScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (BuildContext context, int i) =>
          _MedicationCard(item: items[i]),
    );
  }
}

class _MedicationCard extends ConsumerWidget {
  const _MedicationCard({required this.item});
  final MedicationListItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme tt = Theme.of(context).textTheme;
    final Medication med = item.medication;
    final String windowsLabel = _summariseWindows(context, item.windows);
    // Refill runway from the captured label fields + how many scheduled
    // (non-as-needed) doses this med takes per day.
    final MedicationSupply supply = computeMedicationSupply(
      med,
      scheduledDosesPerDay:
          item.windows.where((DoseWindow w) => !w.isAsNeeded).length,
      now: ref.watch(medicationListClockProvider)(),
    );
    final String? pharmacyPhone =
        (med.pharmacyPhone ?? '').trim().isEmpty ? null : med.pharmacyPhone;
    return Semantics(
      button: true,
      label: '${med.name}, ${med.dosage}. '
          '${item.windows.isEmpty ? 'No time window yet' : windowsLabel}.',
      child: GestureDetector(
        onTap: () => context.push('/medications/${med.id}/edit'),
        onLongPress: () => _confirmAndDelete(context, ref, med),
        child: Container(
          key: MedicationListScreen.tileKey(med.id),
          decoration: BoxDecoration(
            color: context.hc.surfaceWarm,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Top row: name on the left, trash icon top-right. Trash
              // sits in its own slot so it can't crowd the title even
              // when the medication name wraps.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        med.name,
                        style: tt.titleLarge?.copyWith(
                          color: context.hc.primary,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: MedicationListScreen.deleteIconKey(med.id),
                    tooltip: 'Delete medication',
                    icon: const Icon(Icons.delete_outline),
                    color: context.hc.primarySoft,
                    onPressed: () => _confirmAndDelete(context, ref, med),
                  ),
                ],
              ),
              if (med.dosage.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 0, top: 2, right: 12),
                  child: Text(
                    med.dosage,
                    style: tt.bodyLarge?.copyWith(
                      color: context.hc.text,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Padding(
                key: MedicationListScreen.windowsKey(med.id),
                padding: const EdgeInsets.only(top: 2, right: 12),
                child: Text(
                  item.windows.isEmpty
                      ? 'No time window yet — tap to add one.'
                      : windowsLabel,
                  style: tt.bodyMedium?.copyWith(
                    color: context.hc.primarySoft,
                  ),
                ),
              ),
              if (supply.status != SupplyStatus.unknown) ...<Widget>[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: _SupplyLine(
                        key: MedicationListScreen.supplyKey(med.id),
                        supply: supply,
                      ),
                    ),
                    if (pharmacyPhone != null)
                      Semantics(
                        button: true,
                        label: 'Call ${med.pharmacyName ?? 'the pharmacy'} '
                            'to refill ${med.name}.',
                        child: TextButton.icon(
                          key: MedicationListScreen.callPharmacyKey(med.id),
                          onPressed: () => ref
                              .read(linkLauncherProvider)
                              .launch(_pharmacyTelUri(pharmacyPhone)),
                          icon: const Icon(Icons.call, size: 18),
                          label: const Text('Call'),
                          style: TextButton.styleFrom(
                            // Darker CTA tone for the label text so salmon-
                            // on-warm-surface clears AA; the icon inherits it.
                            foregroundColor: context.hc.ctaFilled,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _summariseWindows(BuildContext context, List<DoseWindow> windows) {
    return windows
        .map((DoseWindow w) {
          if (w.isAsNeeded) return w.label;
          final String time = MaterialLocalizations.of(context).formatTimeOfDay(
            w.anchorTime!,
            alwaysUse24HourFormat:
                MediaQuery.alwaysUse24HourFormatOf(context),
          );
          return '${w.label} · $time';
        })
        .join(' · ');
  }

  Future<void> _confirmAndDelete(
      BuildContext context, WidgetRef ref, Medication med) async {
    // Capture the messenger + provider container before the dialog await so
    // the Undo SnackBar can be shown + refresh the list without touching
    // `context` or `this.ref` across the async gap (the card may unmount
    // when the last med is deleted and the empty state swaps in).
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ProviderContainer container =
        ProviderScope.containerOf(context, listen: false);
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: MedicationListScreen.deleteDialogKey,
        title: const Text('Remove medication?'),
        content: Text("${med.name} will stop appearing on the schedule. "
            "You'll have a moment to undo this."),
        actions: <Widget>[
          TextButton(
            key: MedicationListScreen.deleteCancelKey,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: MedicationListScreen.deleteConfirmKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final MedicationRepository repo =
        ref.read(medicationRepositoryBackendProvider);
    await repo.softDeleteMedication(med.id);
    ref.invalidate(medicationListProvider);
    invalidatePatientTimeline(ref);
    // Real recovery affordance for the "you can undo this" promise: re-upsert
    // the captured (pre-delete, live) row — it carries `deletedAt == null`,
    // so writing it back clears the tombstone and restores the medication.
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        key: MedicationListScreen.deleteUndoSnackBarKey,
        content: Text('${med.name} removed.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await repo.upsertMedication(med);
            container.invalidate(medicationListProvider);
            container.invalidate(patientTimelineEventsProvider);
          },
        ),
      ),
    );
  }
}

/// Build a dialable `tel:` URI from a free-text pharmacy phone, stripping
/// formatting but keeping a leading `+` for international numbers.
Uri _pharmacyTelUri(String phone) {
  final String digits = phone
      .replaceAll(RegExp(r'[^0-9+]'), '')
      .replaceAll(RegExp(r'(?!^)\+'), '');
  return Uri(scheme: 'tel', path: digits);
}

/// One-line refill-runway summary for a medication card. A calm subtitle
/// when supply is fine; a salmon "Refill soon" / "No refills left" chip when
/// it needs attention. Pure display of [computeMedicationSupply]'s result.
class _SupplyLine extends StatelessWidget {
  const _SupplyLine({super.key, required this.supply});

  final MedicationSupply supply;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;

    // Calm, informational parts (refills left / estimated supply length).
    final List<String> parts = <String>[];
    final int? refills = supply.refillsRemaining;
    if (refills != null && refills > 0) {
      parts.add('$refills refill${refills == 1 ? '' : 's'} left');
    }
    if (supply.daysOfSupply != null) {
      parts.add('≈${supply.daysOfSupply}-day supply');
    }

    if (!supply.needsAttention) {
      if (parts.isEmpty) return const SizedBox.shrink();
      return Text(
        parts.join(' · '),
        style: tt.bodyMedium?.copyWith(color: context.hc.primarySoft),
      );
    }

    // Needs attention → a chip + a short reason.
    final bool out = supply.status == SupplyStatus.outOfRefills;
    final String chipText = out ? 'No refills left' : 'Refill soon';
    final String reason = out
        ? 'Contact the prescriber to renew.'
        : (supply.runOutDate != null
            ? 'Runs out ${formatMonthDayYear(supply.runOutDate!)}.'
            : 'Running low.');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: context.hc.cta.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            chipText,
            style: tt.labelMedium?.copyWith(
              // Darker CTA tone so the chip label clears AA on its tint.
              color: context.hc.ctaFilled,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            reason,
            style: tt.bodyMedium?.copyWith(color: context.hc.text),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
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
            color: context.hc.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'No medications yet.',
            style: tt.headlineMedium?.copyWith(
              color: context.hc.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "Add what your loved one takes — name, dosage, and the time "
            "windows it's given in.",
            style: tt.bodyLarge?.copyWith(color: context.hc.text),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Builder(
            builder: (BuildContext context) {
              final Color onFilled =
                  Theme.of(context).colorScheme.onSecondary;
              return Semantics(
                button: true,
                label: 'Add a medication.',
                child: ElevatedButton.icon(
                  key: MedicationListScreen.emptyCtaKey,
                  onPressed: () => context.push('/medications/new'),
                  icon: Icon(Icons.add, color: onFilled),
                  label: Text(
                    'Add a medication',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: onFilled),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.hc.ctaFilled,
                    foregroundColor: onFilled,
                    minimumSize: const Size.fromHeight(56),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text("Couldn't load medications.\n\n$message"),
      );
}
