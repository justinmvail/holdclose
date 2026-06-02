import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/medication.dart';
import '../../providers/notifications_provider.dart';
import '../../services/medication_repository.dart';
import '../../services/notification_scheduler.dart';
import '../../theme.dart';
import 'medication_list_screen.dart';

part 'medication_form_screen.g.dart';

/// Mint a new id for the medication / schedule pair the form inserts.
/// Overridable for tests + the demo tour so id sequences are
/// deterministic.
typedef MedicationIdFactory = String Function();

String _defaultMedicationIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return '$ms-$rand';
}

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
  static const Key routeDropdownKey = Key('medication-form-route');
  static const Key prescriberFieldKey = Key('medication-form-prescriber');
  static const Key notesFieldKey = Key('medication-form-notes');
  static const Key submitButtonKey = Key('medication-form-submit');

  @override
  ConsumerState<MedicationFormScreen> createState() =>
      _MedicationFormScreenState();
}

class _MedicationFormScreenState extends ConsumerState<MedicationFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _dosage = TextEditingController();
  final TextEditingController _prescriber = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  MedicationRoute _route = MedicationRoute.oral;
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
    _dosage.text = med.dosage;
    _prescriber.text = med.prescriber ?? '';
    _notes.text = med.notes ?? '';
    _route = med.route;
  }

  @override
  void dispose() {
    _name.dispose();
    _dosage.dispose();
    _prescriber.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) return;
    setState(() => _submitting = true);

    final MedicationRepository repo =
        ref.read(medicationRepositoryBackendProvider);
    final MedicationIdFactory mint = ref.read(medicationFormIdFactoryProvider);
    final DateTime now = ref.read(medicationFormClockProvider)();

    final bool editing = widget.isEdit;
    final String medicationId = widget.medicationId ?? 'med-${mint()}';

    final String prescriber = _prescriber.text.trim();
    final String notes = _notes.text.trim();
    final Medication medication = Medication(
      id: medicationId,
      name: _name.text.trim(),
      dosage: _dosage.text.trim(),
      route: _route,
      prescriber: prescriber.isEmpty ? null : prescriber,
      notes: notes.isEmpty ? null : notes,
    );

    // BUILD_SPEC.md Phase 12.8 — capture refs BEFORE any await so a
    // widget-unmount mid-submit doesn't trigger "ref read after
    // dispose" assertions. The scheduler is keepAlive: true so the
    // container holds the instance.
    final NotificationsProvider notifications = ref.read(notificationsProvider);
    final NotificationScheduler scheduler =
        ref.read(notificationSchedulerProvider);

    await repo.upsertMedication(medication);
    // Add path mints a default daily-8AM schedule alongside the new
    // medication; edit path leaves the existing schedule(s) alone so the
    // dose timeline survives a name/dosage change.
    if (!editing) {
      final DoseSchedule defaultSchedule = DoseSchedule(
        id: 'sched-${mint()}',
        medicationId: medicationId,
        frequencyKind: FrequencyKind.daily,
        timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
        daysOfWeek: const <int>{},
        startsOn: DateTime(now.year, now.month, now.day),
      );
      await repo.upsertSchedule(defaultSchedule);
    }
    ref.invalidate(medicationListProvider);

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
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medications');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme textTheme = theme.textTheme;
    final AsyncValue<Medication?> hydration =
        ref.watch(medicationFormHydrationProvider(widget.medicationId));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEdit ? 'Edit medication' : 'Add medication'),
      ),
      body: SafeArea(
        child: hydration.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (Medication? med) {
            _hydrateFromMedication(med);
            return Form(
              key: _formKey,
              child: ListView(
                key: MedicationFormScreen.formKey,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: <Widget>[
                  _LabelledField(
                    label: 'Name',
                    child: TextFormField(
                      key: MedicationFormScreen.nameFieldKey,
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Donepezil',
                      ),
                      validator: (String? v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Name is required.';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  _LabelledField(
                    label: 'Dosage',
                    child: TextFormField(
                      key: MedicationFormScreen.dosageFieldKey,
                      controller: _dosage,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'e.g. 10 mg',
                      ),
                      validator: (String? v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Dosage is required.';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  _LabelledField(
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
                  _LabelledField(
                    label: 'Prescriber (optional)',
                    child: TextFormField(
                      key: MedicationFormScreen.prescriberFieldKey,
                      controller: _prescriber,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Dr. Kim',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _LabelledField(
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
                  if (!widget.isEdit) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      "We'll start with a daily-at-8AM schedule you can "
                      'adjust from the medication card.',
                      style: textTheme.bodyMedium?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
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
                        backgroundColor: careblazersColors.cta,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        _submitting
                            ? 'Saving…'
                            : (widget.isEdit
                                ? 'Save changes'
                                : 'Save medication'),
                        style:
                            textTheme.labelLarge?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
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
          "We couldn't load this medication.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _LabelledField extends StatelessWidget {
  const _LabelledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
