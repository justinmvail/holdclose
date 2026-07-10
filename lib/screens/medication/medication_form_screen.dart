import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/medication.dart';
import '../../providers/active_patient_provider.dart';
import '../../providers/notifications_provider.dart';
import '../../providers/patient_timeline_provider.dart'
    show invalidatePatientTimeline, patientTimelineEventsProvider;
import '../../services/medication_repository.dart';
import '../../services/notification_scheduler.dart';
import '../../theme.dart';
import '../../widgets/form/form_error_view.dart';
import '../../widgets/form/format.dart';
import '../../widgets/form/id_factory.dart';
import '../../widgets/form/labelled_field.dart';
import '../../widgets/form_validation.dart';
import '../../widgets/path_header.dart';
import '../../widgets/weekday_picker.dart';
import 'dose_window_list_screen.dart';
import 'medication_list_screen.dart';

part 'medication_form_screen.g.dart';

/// Mint a new id for the medication / schedule pair the form inserts.
/// Overridable for tests + the demo tour so id sequences are
/// deterministic.
typedef MedicationIdFactory = String Function();

String _defaultMedicationIdFactory() => mintId('');

/// ID factory the form screen uses. Tests override this with a
/// monotonic counter so the medication-id and schedule-id pair is
/// stable across runs.
@Riverpod(keepAlive: true)
MedicationIdFactory medicationFormIdFactory(Ref ref) =>
    _defaultMedicationIdFactory;

/// Wall clock the form samples when stamping a default schedule's
/// `startsOn` field. Override for stable widget-test assertions.
@Riverpod(keepAlive: true)
DateTime Function() medicationFormClock(Ref ref) => DateTime.now;

/// Async loader for the edit path (TASKS.md Phase 15.6) — hydrates the
/// form with the saved [Medication] when an id is supplied. Returns null
/// for the add path. Mirrors `appointmentFormHydrationProvider`.
@Riverpod(keepAlive: false)
Future<Medication?> medicationFormHydration(
  Ref ref,
  String? medicationId,
) async {
  if (medicationId == null) return null;
  final MedicationRepository repo =
      ref.watch(medicationRepositoryBackendProvider);
  return repo.getMedication(medicationId);
}

/// Add/edit medication form (TASKS.md Phase 12.3 + 15.6) at
/// `/medications/new` and `/medications/:id/edit`.
///
/// Fields:
///   - Name (required) — free text.
///   - Dosage (required) — free text, the caregiver types what's on the
///     bottle ("10 mg", "1 tablet", "5 mL"). See [Medication.dosage]'s
///     docstring for why this is verbatim rather than structured.
///   - Route — dropdown of [MedicationRoute] (oral / topical / injection
///     / other). Defaults to oral.
///   - Prescriber (optional) — free text.
///   - Notes (optional) — multi-line free text.
///
/// The add path inserts the [Medication] row + a default daily-at-8AM
/// [DoseSchedule] starting today. The schedule edit surface (a later
/// phase) takes over from there; the form intentionally doesn't expose
/// the schedule UI so the add-med tap stays one screen + one button.
///
/// The edit path ([medicationId] non-null) hydrates the fields from the
/// saved row, updates the same medication id on submit, and leaves the
/// existing schedule(s) untouched so the dose timeline is preserved.
class MedicationFormScreen extends ConsumerStatefulWidget {
  const MedicationFormScreen({super.key, this.medicationId});

  /// Non-null on the edit path; null on the add path.
  final String? medicationId;

  bool get isEdit => medicationId != null;

  static const Key formKey = Key('medication-form');
  static const Key nameFieldKey = Key('medication-form-name');
  static const Key dosageFieldKey = Key('medication-form-dosage');
  static const Key dosageUnitDropdownKey =
      Key('medication-form-dosage-unit');
  static const Key routeDropdownKey = Key('medication-form-route');
  static const Key prescriberFieldKey = Key('medication-form-prescriber');
  static const Key notesFieldKey = Key('medication-form-notes');
  static const Key rxNumberFieldKey = Key('medication-form-rxnumber');
  static const Key quantityFieldKey = Key('medication-form-quantity');
  static const Key refillsFieldKey = Key('medication-form-refills');
  static const Key pharmacyNameFieldKey = Key('medication-form-pharmacy-name');
  static const Key pharmacyPhoneFieldKey =
      Key('medication-form-pharmacy-phone');
  static const Key dateFilledFieldKey = Key('medication-form-date-filled');
  static const Key discardAfterFieldKey = Key('medication-form-discard-after');
  static const Key submitButtonKey = Key('medication-form-submit');
  static const Key deleteUndoSnackBarKey =
      Key('medication-form-delete-undo-snackbar');
  static const Key endDateFieldKey = Key('medication-form-end-date');
  static const Key endDateClearKey = Key('medication-form-end-date-clear');
  static const Key deleteButtonKey = Key('medication-form-delete');
  /// Add-mode picker for which window the new medication joins. Kept
  /// for parity with the legacy `timesFieldKey` so existing widget
  /// tests can land on a stable handle.
  static const Key windowDropdownKey = Key('medication-form-window');

  @override
  ConsumerState<MedicationFormScreen> createState() =>
      _MedicationFormScreenState();
}

/// The selectable dosage units. Default is [mg] — the overwhelming
/// majority of caregiving prescriptions are milligram doses (per
/// caregiver request: "default to mg but units should be selectable").
/// Ordered roughly by frequency of use in the target population.
const List<String> _dosageUnits = <String>[
  'mg',
  'mcg',
  'g',
  'mL',
  'tablet',
  'capsule',
  'drop',
  'puff',
  'patch',
  'unit',
];

const String _defaultDosageUnit = 'mg';

/// Parse a free-text dosage like "10 mg" into `(amount: '10', unit:
/// 'mg')`. Splits on the last whitespace; if the trailing token matches
/// a known unit in [_dosageUnits], it becomes the unit and the rest
/// becomes the amount. Otherwise the whole string is the amount and
/// the unit falls back to [_defaultDosageUnit] — keeps edit-mode safe
/// against legacy values like "1 tablet" or "5 mL" the user typed
/// before the dropdown existed.
({String amount, String unit}) parseDosage(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return (amount: '', unit: _defaultDosageUnit);
  }
  final int lastSpace = trimmed.lastIndexOf(RegExp(r'\s+'));
  if (lastSpace <= 0) {
    return (amount: trimmed, unit: _defaultDosageUnit);
  }
  final String maybeUnit = trimmed.substring(lastSpace).trim();
  if (_dosageUnits.contains(maybeUnit)) {
    return (
      amount: trimmed.substring(0, lastSpace).trim(),
      unit: maybeUnit,
    );
  }
  return (amount: trimmed, unit: _defaultDosageUnit);
}

class _MedicationFormScreenState extends ConsumerState<MedicationFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _dosage = TextEditingController();
  final TextEditingController _prescriber = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  // Prescription-label details (optional; populated by the AI scan or by
  // hand). Round-tripped so a scanned med's refills/pharmacy are editable.
  final TextEditingController _rxNumber = TextEditingController();
  final TextEditingController _quantity = TextEditingController();
  final TextEditingController _refills = TextEditingController();
  final TextEditingController _pharmacyName = TextEditingController();
  final TextEditingController _pharmacyPhone = TextEditingController();
  final TextEditingController _dateFilled = TextEditingController();
  final TextEditingController _discardAfter = TextEditingController();
  String _dosageUnit = _defaultDosageUnit;
  MedicationRoute _route = MedicationRoute.oral;
  /// Optional end date — when set, the medication disappears from the
  /// active list once this date passes (handled by the repository).
  DateTime? _endsAt;
  /// Windows the medication is given in (multi-select chip picker).
  /// Starts empty — the caregiver adds chips via the "+ Add time"
  /// sheet, picking existing windows or creating new ones. Edit mode
  /// hydrates from the existing entries so the chips match disk.
  Set<String> _selectedWindowIds = <String>{};

  /// Entry-id by window-id captured on edit-mode hydrate so we can
  /// diff the chip set on submit (delete removed entries; insert new
  /// ones). The full entry is also cached in [_entryByWindowId] so an
  /// edit preserves each entry's `startsOn` / `endsOn` while updating
  /// its days.
  Map<String, String> _entryIdByWindowId = <String, String>{};

  /// Full existing entries by window-id (edit hydrate) — lets submit
  /// re-persist an entry with the chosen days without losing its date
  /// bounds.
  Map<String, MedicationWindowEntry> _entryByWindowId =
      <String, MedicationWindowEntry>{};

  /// The weekdays this medication is taken on (1 = Mon … 7 = Sun),
  /// applied to every dose window the med belongs to. Defaults to all
  /// seven ("every day"); a subset (e.g. Mon/Wed/Fri) persists as the
  /// entry `daysOfWeek` the dose forecast already honours.
  Set<int> _daysOfWeek = const <int>{1, 2, 3, 4, 5, 6, 7};
  bool _hydrated = false;
  bool _submitting = false;

  /// Copy the saved medication into the controllers once, on the edit
  /// path. Runs from the hydration provider's `data` callback (the same
  /// shape `AppointmentFormScreen` uses) so the fields are populated
  /// before the first frame the caregiver sees.
  void _hydrateFromMedication(Medication? med) {
    if (_hydrated) return;
    _hydrated = true;
    if (med == null) return;
    _name.text = med.name;
    final ({String amount, String unit}) parsed = parseDosage(med.dosage);
    _dosage.text = parsed.amount;
    _dosageUnit = parsed.unit;
    _prescriber.text = med.prescriber ?? '';
    _notes.text = med.notes ?? '';
    _rxNumber.text = med.rxNumber ?? '';
    _quantity.text = med.quantity ?? '';
    _refills.text = med.refills ?? '';
    _pharmacyName.text = med.pharmacyName ?? '';
    _pharmacyPhone.text = med.pharmacyPhone ?? '';
    _dateFilled.text = med.dateFilled ?? '';
    _discardAfter.text = med.discardAfter ?? '';
    _route = med.route;
    _endsAt = med.endsAt;
    // Edit path: pull the existing entries so the chip set reflects
    // what's currently on disk. Synchronous-looking call queued onto
    // a microtask so the build pass doesn't reach for `setState`
    // before the framework finishes the first frame.
    if (widget.isEdit && widget.medicationId != null) {
      _hydrateEntries(widget.medicationId!);
    }
  }

  Future<void> _confirmAndDelete(BuildContext context) async {
    final String? id = widget.medicationId;
    if (id == null) return;
    // Capture the messenger + provider container before the dialog await —
    // both the app-root ScaffoldMessenger and the ProviderContainer survive
    // this screen's disposal, so the Undo SnackBar (shown on the medication
    // list we return to) can refresh the list without touching `context` or
    // `this.ref` across the async gap.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ProviderContainer container =
        ProviderScope.containerOf(context, listen: false);
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete medication?'),
        content: Text(
          "${_name.text.trim()} will stop appearing on the schedule. "
          "You'll have a moment to undo this.",
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final MedicationRepository repo =
        ref.read(medicationRepositoryBackendProvider);
    // Snapshot the live row (pre-delete, `deletedAt == null`) so Undo can
    // re-upsert it and clear the tombstone — a real recovery affordance for
    // the "you can undo this" promise.
    final Medication? snapshot = await repo.getMedication(id);
    await repo.softDeleteMedication(id);
    ref.invalidate(medicationListProvider);
    invalidatePatientTimeline(ref);
    if (!mounted) return;
    if (context.mounted && context.canPop()) {
      context.pop();
    } else if (context.mounted) {
      context.go('/medications');
    }
    if (snapshot != null) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          key: MedicationFormScreen.deleteUndoSnackBarKey,
          content: Text('${snapshot.name} deleted.'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              await repo.upsertMedication(snapshot);
              // Refresh the list + dashboard timeline via the container
              // (this screen is gone, so `ref` is off-limits).
              container.invalidate(medicationListProvider);
              container.invalidate(patientTimelineEventsProvider);
            },
          ),
        ),
      );
    }
  }

  Future<void> _hydrateEntries(String medicationId) async {
    final MedicationRepository repo =
        ref.read(medicationRepositoryBackendProvider);
    final List<MedicationWindowEntry> entries =
        await repo.entriesForMedication(medicationId);
    if (!mounted) return;
    setState(() {
      _selectedWindowIds = <String>{
        for (final MedicationWindowEntry e in entries) e.windowId,
      };
      _entryIdByWindowId = <String, String>{
        for (final MedicationWindowEntry e in entries) e.windowId: e.id,
      };
      _entryByWindowId = <String, MedicationWindowEntry>{
        for (final MedicationWindowEntry e in entries) e.windowId: e,
      };
      // Reflect the persisted days. Entries store an empty set for
      // "every day"; surface that as all seven chips selected. A med
      // with mixed per-entry days (not reachable from this form) takes
      // the first entry's set.
      final MedicationWindowEntry? first =
          entries.isEmpty ? null : entries.first;
      if (first != null) {
        _daysOfWeek = first.daysOfWeek.isEmpty
            ? const <int>{1, 2, 3, 4, 5, 6, 7}
            : first.daysOfWeek;
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _dosage.dispose();
    _prescriber.dispose();
    _notes.dispose();
    _rxNumber.dispose();
    _quantity.dispose();
    _refills.dispose();
    _pharmacyName.dispose();
    _pharmacyPhone.dispose();
    _dateFilled.dispose();
    _discardAfter.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    // Validate on press, then scroll to the first empty/invalid field so a
    // failed save points the caregiver at exactly what to fix.
    if (!validateAndScrollToFirstError(_formKey)) return;
    setState(() => _submitting = true);

    // Wrap the drift writes in try/catch/finally (mirrors the chat screen's
    // proven `finally` re-enable). A failed local save — the team's own
    // "database is locked" bug is the canonical case — must NOT strand the
    // caregiver on a spinning, permanently-dimmed Save with a full form of
    // just-entered data: the `finally` re-enables Save, the `catch` keeps
    // every field populated and shows a recoverable snackbar to retry.
    try {
    final MedicationRepository repo =
        ref.read(medicationRepositoryBackendProvider);
    final MedicationIdFactory mint = ref.read(medicationFormIdFactoryProvider);
    final DateTime now = ref.read(medicationFormClockProvider)();

    final String medicationId = widget.medicationId ?? 'med-${mint()}';

    final String prescriber = _prescriber.text.trim();
    final String notes = _notes.text.trim();
    final String amount = _dosage.text.trim();
    String? clean(TextEditingController c) {
      final String t = c.text.trim();
      return t.isEmpty ? null : t;
    }

    final Medication medication = Medication(
      id: medicationId,
      name: _name.text.trim(),
      // Compose "<amount> <unit>" so the persisted free-text dosage
      // string stays human-readable ("10 mg", "1 tablet") and the
      // doctor-visit PDF + dose-log subtitles read the same as before.
      dosage: amount.isEmpty ? '' : '$amount $_dosageUnit',
      route: _route,
      prescriber: prescriber.isEmpty ? null : prescriber,
      notes: notes.isEmpty ? null : notes,
      rxNumber: clean(_rxNumber),
      quantity: clean(_quantity),
      refills: clean(_refills),
      pharmacyName: clean(_pharmacyName),
      pharmacyPhone: clean(_pharmacyPhone),
      dateFilled: clean(_dateFilled),
      discardAfter: clean(_discardAfter),
      endsAt: _endsAt,
    );

    // BUILD_SPEC.md Phase 12.8 — capture refs BEFORE any await so a
    // widget-unmount mid-submit doesn't trigger "ref read after
    // dispose" assertions. The scheduler is keepAlive: true so the
    // container holds the instance.
    final NotificationsProvider notifications = ref.read(notificationsProvider);
    final NotificationScheduler scheduler =
        ref.read(notificationSchedulerProvider);

    await repo.upsertMedication(medication);
    // Diff the chip set against the persisted entries:
    //   * Delete entries whose window was un-chipped.
    //   * Insert one fresh entry per newly-chipped window.
    //   * Leave untouched entries alone so any custom daysOfWeek /
    //     endsOn the caregiver set on a window survive a name/dosage
    //     edit.
    final Set<String> existing = _entryIdByWindowId.keys.toSet();
    final Set<String> toDelete = existing.difference(_selectedWindowIds);
    for (final String windowId in toDelete) {
      final String? entryId = _entryIdByWindowId[windowId];
      if (entryId != null) await repo.deleteEntry(entryId);
    }
    // Normalise the day set: all seven selected → empty (= "every day",
    // the forecast's convention), otherwise the chosen subset.
    final Set<int> days =
        _daysOfWeek.length >= 7 ? const <int>{} : _daysOfWeek;
    // Upsert every selected window with the chosen days. Existing entries
    // re-persist under their own id (keeping startsOn/endsOn); new ones
    // get a fresh id + today's start.
    for (final String windowId in _selectedWindowIds) {
      final MedicationWindowEntry? prior = _entryByWindowId[windowId];
      await repo.upsertEntry(MedicationWindowEntry(
        id: prior?.id ?? 'entry-${mint()}',
        medicationId: medicationId,
        windowId: windowId,
        daysOfWeek: days,
        startsOn: prior?.startsOn ?? DateTime(now.year, now.month, now.day),
        endsOn: prior?.endsOn,
      ));
    }
    ref.invalidate(medicationListProvider);
    // Home dashboard cards (Medications Today, Recent Activity, Catch
    // Me Up) cache today's doses + the timeline merger at watch time
    // and don't see the new medication's first dose otherwise. See
    // [invalidatePatientTimeline]'s docstring.
    invalidatePatientTimeline(ref);

    // Permission ask on first med add, then schedule dose reminders.
    // Re-asking is idempotent on both platforms, but we only prompt
    // when the cached state is still notDetermined so the caregiver
    // isn't re-pestered.
    final NotificationPermission current =
        await notifications.currentPermission();
    if (current == NotificationPermission.notDetermined) {
      await notifications.requestPermission();
    }
    await scheduler.rescheduleForMedication(medicationId);

    if (!mounted) return;
    // Confirmation on the destination — the app-level ScaffoldMessenger
    // survives the pop, matching the delete flow's "Metformin removed."
    // toast so a distracted caregiver knows the save landed (UIUX_REVIEW).
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Medication saved.'),
          duration: Duration(seconds: 2),
        ),
      );
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medications');
    }
    } catch (_) {
      // Keep the form populated so nothing entered is lost; surface a
      // recoverable error instead of a dead, spinning button.
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text("Couldn't save right now — try again."),
            duration: Duration(seconds: 3),
          ),
        );
    } finally {
      // Always re-enable Save — on success (before we navigate) AND on an
      // errored write — so the button never stays stuck disabled.
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme textTheme = theme.textTheme;
    final AsyncValue<Medication?> hydration =
        ref.watch(medicationFormHydrationProvider(widget.medicationId));
    // Existing medication names (lower-cased), minus the one being edited,
    // so the Name field can reject a duplicate (alpha bug report:
    // "Multiple medications with same name allowed").
    final Set<String> existingNamesLower = <String>{
      for (final MedicationListItem item
          in ref.watch(medicationListProvider).asData?.value ??
              const <MedicationListItem>[])
        if (item.medication.id != widget.medicationId)
          item.medication.name.trim().toLowerCase(),
    };
    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        // The PathHeader sits OUTSIDE the hydration `.when()` so the
        // breadcrumb back affordance is present on EVERY branch —
        // including the loading and error states (alpha bug
        // fb_1780932762335231: those branches were swipe-only with no
        // header).
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  const PathHeaderCrumb(label: 'Home', route: '/'),
                  const PathHeaderCrumb(
                    label: 'Care',
                    route: '/medical',
                  ),
                  const PathHeaderCrumb(
                    label: 'Medications',
                    route: '/medications',
                  ),
                  PathHeaderCrumb(
                    label: widget.isEdit
                        ? 'Edit medication'
                        : 'Add medication',
                  ),
                ],
                title: widget.isEdit ? 'Edit medication' : 'Add medication',
                backLabel: 'Back to Medications',
                leadingIcon: Icons.medication_outlined,
              ),
            ),
            Expanded(
              child: hydration.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => FormErrorView(
                    message: "We couldn't load this medication.\n$e"),
                data: (Medication? med) {
                  _hydrateFromMedication(med);
                  return Form(
                    key: _formKey,
                    // Column + Expanded(ListView) + pinned Save button. The
                    // form fields scroll independently of the Save action so
                    // a long med (notes + many windows) can't push the
                    // submit affordance below the fold.
                    child: Column(
                      children: <Widget>[
                        Expanded(
                          child: ListView(
                            key: MedicationFormScreen.formKey,
                            padding:
                                const EdgeInsets.fromLTRB(20, 16, 20, 16),
                            children: <Widget>[
                  const SizedBox(height: 4),
                  LabelledField(
                    label: 'Name',
                    child: TextFormField(
                      key: MedicationFormScreen.nameFieldKey,
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      // Auto-capitalize each word as the caregiver
                      // types so "donepezil 10 mg" lands on disk as
                      // "Donepezil 10 mg" without manual editing.
                      // Keyboard hint + a hard formatter make it
                      // stick on physical keyboards too.
                      textCapitalization: TextCapitalization.words,
                      inputFormatters: <TextInputFormatter>[
                        TitleCaseTextFormatter(),
                      ],
                      decoration: const InputDecoration(
                        hintText: 'e.g. Donepezil',
                      ),
                      validator: (String? v) {
                        final String name = v?.trim() ?? '';
                        if (name.isEmpty) {
                          return 'Name is required.';
                        }
                        if (existingNamesLower.contains(name.toLowerCase())) {
                          return 'You already have a medication named '
                              '"$name". Edit that one, or use a more '
                              'specific name.';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Dosage',
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            key: MedicationFormScreen.dosageFieldKey,
                            controller: _dosage,
                            textInputAction: TextInputAction.next,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'e.g. 10',
                            ),
                            validator: (String? v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'Dosage is required.';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 1,
                          child: DropdownButtonFormField<String>(
                            key: MedicationFormScreen.dosageUnitDropdownKey,
                            initialValue: _dosageUnit,
                            isExpanded: true,
                            items: <DropdownMenuItem<String>>[
                              for (final String unit in _dosageUnits)
                                DropdownMenuItem<String>(
                                  value: unit,
                                  child: Text(
                                    unit,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (String? next) {
                              if (next == null) return;
                              setState(() => _dosageUnit = next);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Route',
                    child: DropdownButtonFormField<MedicationRoute>(
                      key: MedicationFormScreen.routeDropdownKey,
                      initialValue: _route,
                      isExpanded: true,
                      items: const <DropdownMenuItem<MedicationRoute>>[
                        DropdownMenuItem<MedicationRoute>(
                          value: MedicationRoute.oral,
                          child: Text(
                            'Oral (by mouth)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem<MedicationRoute>(
                          value: MedicationRoute.topical,
                          child: Text(
                            'Topical (patch / cream)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem<MedicationRoute>(
                          value: MedicationRoute.injection,
                          child: Text(
                            'Injection',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem<MedicationRoute>(
                          value: MedicationRoute.other,
                          child: Text(
                            'Other',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: (MedicationRoute? next) {
                        if (next == null) return;
                        setState(() => _route = next);
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Prescriber (optional)',
                    child: TextFormField(
                      key: MedicationFormScreen.prescriberFieldKey,
                      controller: _prescriber,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.words,
                      inputFormatters: <TextInputFormatter>[
                        TitleCaseTextFormatter(),
                      ],
                      decoration: const InputDecoration(
                        hintText: 'e.g. Dr. Kim',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Notes (optional)',
                    child: TextFormField(
                      key: MedicationFormScreen.notesFieldKey,
                      controller: _notes,
                      maxLines: 4,
                      minLines: 2,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Take with food. Watch for drowsiness.',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Prescription details (optional)',
                    style: textTheme.titleSmall?.copyWith(
                      color: context.hc.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  LabelledField(
                    label: 'Rx number',
                    child: TextFormField(
                      key: MedicationFormScreen.rxNumberFieldKey,
                      controller: _rxNumber,
                      decoration:
                          const InputDecoration(hintText: 'e.g. 1687749'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Quantity',
                    child: TextFormField(
                      key: MedicationFormScreen.quantityFieldKey,
                      controller: _quantity,
                      decoration: const InputDecoration(hintText: 'e.g. 180'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Refills remaining',
                    child: TextFormField(
                      key: MedicationFormScreen.refillsFieldKey,
                      controller: _refills,
                      decoration: const InputDecoration(hintText: 'e.g. 3'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Pharmacy',
                    child: TextFormField(
                      key: MedicationFormScreen.pharmacyNameFieldKey,
                      controller: _pharmacyName,
                      textCapitalization: TextCapitalization.words,
                      decoration:
                          const InputDecoration(hintText: 'e.g. CVS Pharmacy'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Pharmacy phone',
                    child: TextFormField(
                      key: MedicationFormScreen.pharmacyPhoneFieldKey,
                      controller: _pharmacyPhone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                          hintText: 'e.g. 843-767-4500'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Date filled',
                    child: TextFormField(
                      key: MedicationFormScreen.dateFilledFieldKey,
                      controller: _dateFilled,
                      decoration:
                          const InputDecoration(hintText: 'e.g. 12/3/21'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Discard after',
                    child: TextFormField(
                      key: MedicationFormScreen.discardAfterFieldKey,
                      controller: _discardAfter,
                      decoration:
                          const InputDecoration(hintText: 'e.g. 12/3/22'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Times',
                    child: _WindowChipPicker(
                      fieldKey:
                          MedicationFormScreen.windowDropdownKey,
                      selected: _selectedWindowIds,
                      onChanged: (Set<String> next) => setState(
                          () => _selectedWindowIds = next),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap a chip to add or remove the time window. '
                    '"+ Add time" opens existing time windows or lets you '
                    'create a new one.',
                    style: textTheme.bodyMedium?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Days',
                    child: WeekdayPicker(
                      selected: _daysOfWeek,
                      onChanged: (Set<int> next) =>
                          setState(() => _daysOfWeek = next),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Leave every day selected for a daily medication, or '
                    'pick specific days (e.g. Mon/Wed/Fri) for an '
                    'every-other-day or weekly schedule.',
                    style: textTheme.bodyMedium?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'End date (optional)',
                    child: _EndDatePicker(
                      fieldKey: MedicationFormScreen.endDateFieldKey,
                      clearKey: MedicationFormScreen.endDateClearKey,
                      value: _endsAt,
                      onChanged: (DateTime? next) =>
                          setState(() => _endsAt = next),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Set an end date for short courses (antibiotics, '
                    'taper plans). The medication automatically drops '
                    'off the active list when this date passes.',
                    style: textTheme.bodyMedium?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                      ],
                    ),
                  ),
                  // Pinned at the bottom — out of the scroll view so it
                  // can't disappear off-screen.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Semantics(
                          button: true,
                          label: widget.isEdit
                              ? 'Save changes to this medication.'
                              : 'Save this medication.',
                          child: ElevatedButton(
                            key: MedicationFormScreen.submitButtonKey,
                            onPressed: _submitting ? null : _submit,
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                              backgroundColor: context.hc.ctaFilled,
                              foregroundColor:
                                  theme.colorScheme.onSecondary,
                            ),
                            child: Text(
                              _submitting
                                  ? 'Saving…'
                                  : (widget.isEdit
                                      ? 'Save changes'
                                      : 'Save medication'),
                              style: textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.onSecondary),
                            ),
                          ),
                        ),
                        if (widget.isEdit) ...<Widget>[
                          const SizedBox(height: 8),
                          TextButton.icon(
                            key: MedicationFormScreen.deleteButtonKey,
                            onPressed: _submitting
                                ? null
                                : () => _confirmAndDelete(context),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Delete medication'),
                            style: TextButton.styleFrom(
                              foregroundColor: context.hc.text
                                  .withValues(alpha: 0.65),
                              minimumSize: const Size.fromHeight(44),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Times-of-day picker for the medication form (add mode only).
///
/// Renders the current [times] as a wrap of [InputChip]s. Tapping a chip
/// opens the platform time picker pre-filled to the chip's value; tapping
/// the chip's `X` removes it. The "Add time" trailing button appends a
/// Multi-window chip picker for the medication form (v14 "windows-as-
/// times" UX). Each selected window renders as a [FilterChip] showing
/// the window label and its anchor time ("Morning · 8:00 AM"); the
/// "+ Add time" chip opens a bottom sheet of the patient's other
/// windows + a "Create new window" affordance. Tapping an existing
/// chip toggles it off.
class _WindowChipPicker extends ConsumerWidget {
  const _WindowChipPicker({
    required this.fieldKey,
    required this.selected,
    required this.onChanged,
  });

  final Key fieldKey;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DoseWindow>> async =
        ref.watch(doseWindowListProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (Object e, StackTrace _) =>
          Text("Couldn't load windows: $e"),
      data: (List<DoseWindow> windows) {
        final Map<String, DoseWindow> byId = <String, DoseWindow>{
          for (final DoseWindow w in windows) w.id: w,
        };
        final List<DoseWindow> selectedList = <DoseWindow>[
          for (final String id in selected)
            if (byId[id] != null) byId[id]!,
        ]..sort(_byAnchorThenAsNeeded);
        // Chips first (a Wrap of the selected windows), then the
        // "Add time" button BELOW them — left-aligned under the list,
        // not trailing to the right (alpha bug report
        // fb_1780933462488395). The Column keeps the affordance
        // discoverable as the chip list grows.
        return Column(
          key: fieldKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (selectedList.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  for (final DoseWindow w in selectedList)
                    InputChip(
                      label: Text(_windowLabel(context, w)),
                      onDeleted: () {
                        final Set<String> next = <String>{...selected}
                          ..remove(w.id);
                        onChanged(next);
                      },
                    ),
                ],
              ),
            if (selectedList.isNotEmpty) const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Add time'),
                onPressed: () => _openAddSheet(context, ref, windows),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openAddSheet(BuildContext context, WidgetRef ref,
      List<DoseWindow> windows) async {
    final List<DoseWindow> available = windows
        .where((DoseWindow w) => !selected.contains(w.id))
        .toList()
      ..sort(_byAnchorThenAsNeeded);
    final _PickedWindow? picked = await showModalBottomSheet<_PickedWindow>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => _AddWindowSheet(
        available: available,
      ),
    );
    if (picked == null) return;
    if (!context.mounted) return;
    if (picked.createWithLabel != null) {
      // "Create new window" path. Reject the label early if another
      // window already uses it (case-insensitive) so a caregiver
      // doesn't end up with two "Morning"s on disk.
      final String label = picked.createWithLabel!;
      final String lower = label.toLowerCase();
      if (windows.any((DoseWindow w) => w.label.toLowerCase() == lower)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text("\"$label\" is already a time window name.")),
        );
        return;
      }
      // Capture refs BEFORE the next await (same rule as the submit
      // path's note above) so a widget-unmount while the time picker is
      // up doesn't trip "ref read after dispose".
      final MedicationRepository repo =
          ref.read(medicationRepositoryBackendProvider);
      final Future<String> patientIdFuture =
          ref.read(activePatientIdProvider.future);
      // Sheet closed with the new label; pop the system time picker
      // before minting the DoseWindow.
      final TimeOfDay? time = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 8, minute: 0),
      );
      if (time == null) return;
      final String patientId = await patientIdFuture;
      final List<DoseWindow> existing =
          await repo.windowsForPatient(patientId);
      final int nextSort = existing.isEmpty
          ? 0
          : (existing.map((DoseWindow w) => w.sortOrder).reduce(
                  (int a, int b) => a > b ? a : b) +
              1);
      final DoseWindow window = DoseWindow(
        id: 'window-${DateTime.now().millisecondsSinceEpoch}',
        patientId: patientId,
        label: label,
        anchorTime: time,
        sortOrder: nextSort,
      );
      await repo.upsertWindow(window);
      // The picker + repo writes above may outlive this chip row; only
      // touch ref/onChanged when the row is still mounted.
      if (!context.mounted) return;
      ref.invalidate(doseWindowListProvider);
      onChanged(<String>{...selected, window.id});
    } else if (picked.existingId != null) {
      onChanged(<String>{...selected, picked.existingId!});
    }
  }

  static int _byAnchorThenAsNeeded(DoseWindow a, DoseWindow b) {
    if (a.isAsNeeded && !b.isAsNeeded) return 1;
    if (!a.isAsNeeded && b.isAsNeeded) return -1;
    if (a.isAsNeeded && b.isAsNeeded) return 0;
    final int am = a.anchorTime!.hour * 60 + a.anchorTime!.minute;
    final int bm = b.anchorTime!.hour * 60 + b.anchorTime!.minute;
    return am.compareTo(bm);
  }

  static String _windowLabel(BuildContext context, DoseWindow w) {
    if (w.isAsNeeded) return w.label;
    final String time = MaterialLocalizations.of(context).formatTimeOfDay(
      w.anchorTime!,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '${w.label} · $time';
  }
}

/// What the [_AddWindowSheet] returns — either an existing window id
/// to add, or a label to mint a new window with. Time is picked via
/// the system [showTimePicker] after the sheet dismisses.
@immutable
class _PickedWindow {
  const _PickedWindow.existing(String id)
      : existingId = id,
        createWithLabel = null;
  const _PickedWindow.create(String label)
      : existingId = null,
        createWithLabel = label;

  final String? existingId;
  final String? createWithLabel;
}

class _AddWindowSheet extends StatefulWidget {
  const _AddWindowSheet({required this.available});
  final List<DoseWindow> available;

  @override
  State<_AddWindowSheet> createState() => _AddWindowSheetState();
}

class _AddWindowSheetState extends State<_AddWindowSheet> {
  final TextEditingController _newLabel = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _newLabel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Add a time',
                style: tt.titleLarge?.copyWith(
                  color: context.hc.primary,
                ),
              ),
              const SizedBox(height: 8),
              if (widget.available.isEmpty)
                Text(
                  'No other time windows on file. Create a new one below.',
                  style: tt.bodyMedium?.copyWith(
                    color: context.hc.primarySoft,
                  ),
                )
              else ...<Widget>[
                Text(
                  'Pick an existing time',
                  style: tt.titleSmall?.copyWith(
                    color: context.hc.primarySoft,
                  ),
                ),
                const SizedBox(height: 4),
                for (final DoseWindow w in widget.available)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(w.label),
                    subtitle: Text(
                      w.isAsNeeded
                          ? 'As needed'
                          : MaterialLocalizations.of(context).formatTimeOfDay(
                              w.anchorTime!,
                              alwaysUse24HourFormat:
                                  MediaQuery.alwaysUse24HourFormatOf(context),
                            ),
                    ),
                    onTap: () => Navigator.of(context)
                        .pop(_PickedWindow.existing(w.id)),
                  ),
              ],
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),
              Text(
                'Or create a new time window',
                style: tt.titleSmall?.copyWith(
                  color: context.hc.primarySoft,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _newLabel,
                // Capitalise each word so "mid-morning" lands as
                // "Mid-morning" on disk — parity with the dose-window
                // form's name field.
                textCapitalization: TextCapitalization.words,
                inputFormatters: <TextInputFormatter>[
                  TitleCaseTextFormatter(),
                ],
                decoration: const InputDecoration(
                  labelText: 'Time window name',
                  hintText: 'e.g. Mid-morning',
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _creating
                    ? null
                    : () {
                        final String label =
                            capitalizeWindowLabel(_newLabel.text.trim());
                        if (label.isEmpty) return;
                        setState(() => _creating = true);
                        Navigator.of(context)
                            .pop(_PickedWindow.create(label));
                      },
                icon: const Icon(Icons.add),
                label: const Text('Pick a time for this time window'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.hc.ctaFilled,
                  foregroundColor: Theme.of(context).colorScheme.onSecondary,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// Optional end-date picker. Tap the field to open a Material date
/// picker (defaults to today + 7 days when nothing is set). The "Clear"
/// affordance lives at the trailing edge so a misset date doesn't
/// leave a lingering tombstone the caregiver has to manually reset.
class _EndDatePicker extends StatelessWidget {
  const _EndDatePicker({
    required this.fieldKey,
    required this.clearKey,
    required this.value,
    required this.onChanged,
  });

  final Key fieldKey;
  final Key clearKey;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  Future<void> _pick(BuildContext context) async {
    final DateTime initial = value ??
        DateTime.now().add(const Duration(days: 7));
    final DateTime firstDate =
        DateTime.now().subtract(const Duration(days: 365));
    final DateTime lastDate =
        DateTime.now().add(const Duration(days: 365 * 5));
    final DateTime? next = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (next == null) return;
    onChanged(DateTime(next.year, next.month, next.day));
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final String label = value == null
        ? 'No end date'
        : formatMonthDayYear(value!);
    return InkWell(
      key: fieldKey,
      onTap: () => _pick(context),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'End date',
          suffixIcon: value == null
              ? const Icon(Icons.event_outlined)
              : IconButton(
                  key: clearKey,
                  tooltip: 'Clear end date',
                  icon: const Icon(Icons.close),
                  onPressed: () => onChanged(null),
                ),
        ),
        child: Text(
          label,
          style: tt.bodyLarge,
        ),
      ),
    );
  }
}

/// Title-case a free-text input as the user types.
///
/// Capitalises the first letter of every whitespace-delimited token —
/// "donepezil 10 mg" becomes "Donepezil 10 Mg". Side-stepping each
/// token's interior preserves any all-caps acronym the caregiver
/// already typed (`DM`, `IV`) and keeps subsequent letters they fix
/// alone, so the formatter never fights an explicit edit.
class TitleCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String text = newValue.text;
    if (text.isEmpty) return newValue;
    final StringBuffer out = StringBuffer();
    bool atWordStart = true;
    for (int i = 0; i < text.length; i++) {
      final String ch = text[i];
      if (ch == ' ' || ch == '\t' || ch == '\n') {
        out.write(ch);
        atWordStart = true;
        continue;
      }
      if (atWordStart) {
        out.write(ch.toUpperCase());
        atWordStart = false;
      } else {
        out.write(ch);
      }
    }
    final String formatted = out.toString();
    if (formatted == text) return newValue;
    return TextEditingValue(
      text: formatted,
      selection: newValue.selection,
      composing: newValue.composing,
    );
  }
}
