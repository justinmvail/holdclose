import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../l10n/app_localizations.dart';
import '../../models/patient.dart';
import '../../providers/active_patient_provider.dart';
import '../../providers/patient_configured_provider.dart';
import '../../providers/storage_provider.dart';
import '../../services/sync_service.dart';
import '../../theme.dart';
import '../../widgets/form/format.dart';
import '../../widgets/form/id_factory.dart';
import '../../widgets/form_validation.dart';

part 'loved_one_setup_screen.g.dart';

/// Mint a new id for the [Patient] the wizard creates. Overridable for
/// tests + the demo tour so the id is deterministic — same `'<prefix>-
/// <ms>-<rand>'` shape as the health-log / appointment / medication form
/// id factories (and the `demo-patient-mary` seed shape).
typedef PatientIdFactory = String Function();

String _defaultPatientIdFactory() => mintId('patient');

/// ID factory the setup wizard uses. Tests override this with a fixed
/// value so the persisted patient id is stable across runs.
@Riverpod(keepAlive: true)
PatientIdFactory patientSetupIdFactory(Ref ref) => _defaultPatientIdFactory;

/// New-user onboarding wizard at `/setup` (BUILD_SPEC.md §5.9 + §9.1).
///
/// The first-run flow is welcome carousel → sign-in → **this screen**.
/// A real (non-demo) install lands here with no [Patient] on file; the
/// router redirect (`holdcloseRedirect`) holds the caregiver here
/// until they save one, then lets them through to Home. In `DEMO_MODE`
/// the seeded Mary means the gate is already satisfied, so this screen
/// is skipped.
///
/// Deliberately short + warm for a tired caregiver: it collects the
/// ESSENTIALS only — their person's name (the one required field), age,
/// diagnosis, and allergies. Everything else the [Patient] model needs is
/// defaulted sensibly (no medications, diagnosed "today", no calms /
/// escalates notes yet, empty primary caregiver / POA, advance directive
/// "not on file") and can be filled in later from the Emergency Card.
/// Nothing here diagnoses or prescribes — the diagnosis field is just
/// what the caregiver was told.
class LovedOneSetupScreen extends ConsumerStatefulWidget {
  const LovedOneSetupScreen({super.key, this.isAdd = false});

  /// `false` (default) — the first-run onboarding gate: saving the very
  /// first loved one flips [PatientConfigured] and lets the router
  /// through to Home.
  ///
  /// `true` — reused from the "Loved ones" manager to ADD another loved
  /// one (multi-patient, Issue #6): saving appends a patient, makes them
  /// the active one, and pops back to the manager instead of gating /
  /// resetting the navigation stack. Same form, two entry points.
  final bool isAdd;

  static const Key formKey = Key('loved-one-setup-form');
  static const Key nameFieldKey = Key('loved-one-setup-name');
  static const Key ageFieldKey = Key('loved-one-setup-age');
  static const Key dobFieldKey = Key('loved-one-setup-dob');
  static const Key dobClearKey = Key('loved-one-setup-dob-clear');
  static const Key diagnosisFieldKey = Key('loved-one-setup-diagnosis');
  static const Key allergiesFieldKey = Key('loved-one-setup-allergies');
  static const Key saveButtonKey = Key('loved-one-setup-save');

  /// Cancel/close affordance — shown ONLY in ADD mode (`isAdd: true`) so a
  /// caregiver who opened "add another loved one" from the Loved ones
  /// manager (or hit it by accident) can back out. The first-run onboarding
  /// gate (`isAdd: false`) deliberately has NO escape — the caregiver must
  /// create their first person before reaching the app — so this is absent
  /// there. (fb 2026-06-14: an accidental tap trapped a tester with no exit.)
  static const Key cancelButtonKey = Key('loved-one-setup-cancel');

  @override
  ConsumerState<LovedOneSetupScreen> createState() =>
      _LovedOneSetupScreenState();
}

class _LovedOneSetupScreenState extends ConsumerState<LovedOneSetupScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _age = TextEditingController();
  final TextEditingController _diagnosis = TextEditingController();
  final TextEditingController _allergies = TextEditingController();

  /// Optional — when picked, the stored age is derived from it (DOB is
  /// what EMS/clinicians expect; the age field stays for quick entry).
  DateTime? _dateOfBirth;

  bool _submitting = false;

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _diagnosis.dispose();
    _allergies.dispose();
    super.dispose();
  }

  /// Split a multiline textarea into trimmed, non-empty lines — the
  /// model stores allergies / calms / escalates as `List<String>`, one
  /// item per line of input.
  List<String> _lines(TextEditingController c) => c.text
      .split('\n')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  Future<void> _pickDateOfBirth() async {
    final DateTime now = DateTime.now();
    // Start the picker from the typed age when there is one — the caregiver
    // often knows "78" before they recall the birth year.
    final int? typedAge = int.tryParse(_age.text.trim());
    final DateTime fallback =
        (typedAge != null && typedAge > 0 && typedAge <= 130)
            ? DateTime(now.year - typedAge, now.month, now.day)
            : now;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _dateOfBirth ?? fallback,
      firstDate: DateTime(now.year - 130, now.month, now.day),
      // A birth date is never in the future.
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateOfBirth = DateTime(picked.year, picked.month, picked.day);
      // Keep the visible age field consistent with the picked date.
      _age.text = ageFromDateOfBirth(picked, now).toString();
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    // Validate on press + scroll to the first invalid field.
    if (!validateAndScrollToFirstError(_formKey)) return;

    setState(() => _submitting = true);

    try {
    final String id = ref.read(patientSetupIdFactoryProvider)();
    // The setup wizard no longer collects a primary caregiver contact;
    // it's left empty here and editable later. POA / advance directive
    // mirror that empty contact by default.
    const Contact primaryCaregiver = Contact(name: '', phone: '');
    final String? ageText = _age.text.trim().isEmpty ? null : _age.text.trim();

    final Patient patient = Patient(
      id: id,
      name: _name.text.trim(),
      // A picked date of birth wins: the stored age is derived from it so
      // the two can never disagree. Otherwise age is optional in the
      // wizard; default to 0 ("not given") when the caregiver leaves it
      // blank. The field validator already rejects non-numeric input, so
      // a non-empty value parses here.
      age: _dateOfBirth != null
          ? ageFromDateOfBirth(_dateOfBirth!, DateTime.now())
          : (ageText == null ? 0 : (int.tryParse(ageText) ?? 0)),
      dateOfBirth: _dateOfBirth,
      diagnosis: _diagnosis.text.trim(),
      // Sensible defaults for the fields the wizard deliberately omits —
      // the caregiver can fill these in later from the Emergency Card.
      diagnosedAt: DateTime.now(),
      medications: const <CrisisMedication>[],
      allergies: _lines(_allergies),
      // Calms / escalates are no longer collected in setup — default to
      // empty lists; they stay on the model and can be filled in later.
      calms: const <String>[],
      escalates: const <String>[],
      primaryCaregiver: primaryCaregiver,
      // POA mirrors the primary caregiver by default — the most common
      // single-caregiver case — and is editable later.
      healthcarePOA: primaryCaregiver,
      advanceDirective: const AdvanceDirectiveStatus(
        onFileAt: 'Not on file',
        dnr: false,
      ),
    );

    await ref.read(storageProvider).upsertPatient(patient);

    // Server-authoritative sync: when this is the FIRST loved one, make
    // them circle-owned by creating a backend circle that owns them.
    // Strictly best-effort + fail-safe and FIRE-AND-FORGET — onboarding
    // navigation must NEVER wait on the network. If the backend is offline
    // or unconfigured this no-ops inside ensureCircleForActivePatient and
    // the app proceeds exactly as it does today (local patient, no circle);
    // bootstrap retries the circle creation on a later launch. We don't do
    // this in ADD mode — a second loved one on the same device isn't a new
    // circle in v1 (the single-circle model owns the active loved one).
    if (!widget.isAdd) {
      try {
        // Intentionally NOT awaited — the patient is already saved
        // locally above; circle creation happens in the background.
        unawaited(
          ref.read(syncControllerProvider).ensureCircleForActivePatient(),
        );
      } catch (_) {
        // Never block onboarding on sync — stay local-only.
      }
    }

    if (widget.isAdd) {
      // ADD mode (from the "Loved ones" manager): make the new loved one
      // active so the whole app re-centres on them, then refresh the
      // active-patient providers + the setup gate (which stays true since
      // a patient is still on file) and pop back to the manager. We do
      // NOT `go('/')` — that would blow away the manager's back stack.
      await ref.read(storageProvider).setActivePatientId(id);
      ref.invalidate(activePatientProvider);
      ref.invalidate(activePatientIdProvider);
      await ref.read(patientConfiguredProvider.notifier).reload();
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/loved-ones');
      }
      return;
    }

    // First-run gate: flip the setup gate so the redirect lets us through
    // to Home — `reload()` re-reads storage (now non-null) and wakes the
    // router's refresh listenable.
    await ref.read(patientConfiguredProvider.notifier).reload();

    if (!mounted) return;
    context.go('/');
    } catch (e) {
      // Never strand the form on "Saving…" — reset so the caregiver can
      // retry, and surface what went wrong instead of a dead button.
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save just now — please try again."),
        ),
      );
    }
  }

  /// Back out of ADD mode without creating a loved one — pop to the Loved
  /// ones manager (or navigate there if this was somehow a root entry).
  /// Only reachable from the ADD-mode close button.
  void _cancelAdd() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/loved-ones');
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: context.hc.background,
      // ADD mode is a pushed modal task off the Loved ones manager — it MUST
      // have a way out. (fb 2026-06-14: a tester hit "add a loved one" by
      // accident and got trapped — no back button, no top bar.) The first-run
      // gate (isAdd false) intentionally keeps NO AppBar / no escape: the
      // caregiver has to create their first person before reaching the app.
      appBar: widget.isAdd
          ? AppBar(
              backgroundColor: context.hc.background,
              foregroundColor: context.hc.primary,
              elevation: 0,
              leading: IconButton(
                key: LovedOneSetupScreen.cancelButtonKey,
                icon: const Icon(Icons.close),
                tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
                onPressed: _submitting ? null : _cancelAdd,
              ),
            )
          : null,
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            key: LovedOneSetupScreen.formKey,
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            children: <Widget>[
              Text(
                l10n.lovedOneSetupTitle,
                style: textTheme.headlineMedium?.copyWith(
                  color: context.hc.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.lovedOneSetupIntro,
                style: textTheme.bodyLarge?.copyWith(
                  color: context.hc.text,
                ),
              ),
              const SizedBox(height: 28),
              _FieldLabel(label: l10n.lovedOneSetupNameLabel),
              const SizedBox(height: 8),
              TextFormField(
                key: LovedOneSetupScreen.nameFieldKey,
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: l10n.lovedOneSetupNameHint,
                ),
                validator: (String? v) {
                  if ((v ?? '').trim().isEmpty) {
                    return l10n.lovedOneSetupNameError;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              _FieldLabel(label: l10n.lovedOneSetupAgeLabel),
              const SizedBox(height: 8),
              TextFormField(
                key: LovedOneSetupScreen.ageFieldKey,
                controller: _age,
                keyboardType: TextInputType.number,
                decoration:
                    InputDecoration(hintText: l10n.lovedOneSetupAgeHint),
                validator: (String? v) {
                  final String t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  final int? parsed = int.tryParse(t);
                  if (parsed == null || parsed < 0 || parsed > 130) {
                    return l10n.lovedOneSetupAgeError;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              _FieldLabel(label: l10n.lovedOneSetupDobLabel),
              const SizedBox(height: 4),
              _Hint(text: l10n.lovedOneSetupDobHint),
              const SizedBox(height: 8),
              // Tap-to-pick date field (same idiom as the medication form's
              // end-date picker): InkWell + InputDecorator with a trailing
              // clear affordance, so a mistapped date is one tap to undo.
              InkWell(
                key: LovedOneSetupScreen.dobFieldKey,
                onTap: _submitting ? null : _pickDateOfBirth,
                child: InputDecorator(
                  decoration: InputDecoration(
                    suffixIcon: _dateOfBirth == null
                        ? const Icon(Icons.event_outlined)
                        : IconButton(
                            key: LovedOneSetupScreen.dobClearKey,
                            tooltip: l10n.lovedOneSetupDobClear,
                            icon: const Icon(Icons.close),
                            onPressed: _submitting
                                ? null
                                : () => setState(() => _dateOfBirth = null),
                          ),
                  ),
                  child: Text(
                    _dateOfBirth == null
                        ? l10n.lovedOneSetupDobNotSet
                        : formatMonthDayYear(_dateOfBirth!),
                    style: textTheme.bodyLarge?.copyWith(
                      color: _dateOfBirth == null
                          ? context.hc.primarySoft
                          : context.hc.text,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _FieldLabel(label: l10n.lovedOneSetupDiagnosisLabel),
              const SizedBox(height: 8),
              TextFormField(
                key: LovedOneSetupScreen.diagnosisFieldKey,
                controller: _diagnosis,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: l10n.lovedOneSetupDiagnosisHint,
                ),
              ),
              const SizedBox(height: 20),
              _FieldLabel(label: l10n.lovedOneSetupAllergiesLabel),
              const SizedBox(height: 4),
              _Hint(text: l10n.lovedOneSetupOnePerLine),
              const SizedBox(height: 8),
              TextFormField(
                key: LovedOneSetupScreen.allergiesFieldKey,
                controller: _allergies,
                maxLines: 3,
                minLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: l10n.lovedOneSetupAllergiesHint,
                ),
              ),
              const SizedBox(height: 32),
              Semantics(
                button: true,
                label: l10n.lovedOneSetupSaveSemantics,
                child: ElevatedButton(
                  key: LovedOneSetupScreen.saveButtonKey,
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    backgroundColor: context.hc.cta,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    _submitting
                        ? l10n.lovedOneSetupSaving
                        : l10n.lovedOneSetupSave,
                    style: textTheme.labelLarge?.copyWith(color: Colors.white),
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

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      label,
      style: textTheme.bodyLarge?.copyWith(
        color: context.hc.primary,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      text,
      style: textTheme.bodyMedium?.copyWith(
        color: context.hc.primarySoft,
      ),
    );
  }
}
