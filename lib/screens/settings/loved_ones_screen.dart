import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/patient.dart';
import '../../providers/active_patient_provider.dart';
import '../../providers/patient_configured_provider.dart';
import '../../providers/storage_provider.dart';
import '../../screens/medication/dose_window_list_screen.dart'
    show doseWindowListProvider;
import '../../screens/medication/medication_list_screen.dart'
    show medicationListProvider;
import '../../theme.dart';
import '../../widgets/form/form_error_view.dart';
import '../../widgets/path_header.dart';

part 'loved_ones_screen.g.dart';

/// Everything the "Loved ones" manager renders, bundled so the screen
/// consumes a single [AsyncValue] (multi-patient, Issue #6).
@immutable
class LovedOnesView {
  const LovedOnesView({required this.patients, required this.activeId});

  /// Every loved one on file, name-sorted (the storage layer sorts).
  final List<Patient> patients;

  /// The id [StorageProvider.getPatient] currently resolves to — the row
  /// the whole app is centred on. Used to flag the active row.
  final String? activeId;

  bool get isEmpty => patients.isEmpty;
}

/// Bundles the loved-ones roster + the active id for [LovedOnesScreen].
///
/// `keepAlive: false` so it re-resolves each time the manager opens; the
/// switch / add handlers invalidate it explicitly so the active flag
/// updates in place. Reads through [storageProvider] directly (not the
/// `activePatient*` providers) so the list + the active marker come from
/// one consistent snapshot.
@riverpod
Future<LovedOnesView> lovedOnesView(Ref ref) async {
  final StorageProvider storage = ref.watch(storageProvider);
  final List<Patient> patients = await storage.listPatients();
  // The id the app is centred on — the explicitly-chosen active id when
  // set, else the resolved (first/sole) patient so a row is always
  // flagged when at least one loved one is on file.
  final String? explicit = await storage.getActivePatientId();
  final String? resolved = explicit ?? (await storage.getPatient())?.id;
  return LovedOnesView(patients: patients, activeId: resolved);
}

/// Switch the active loved one to [patientId] and refresh every surface
/// that reads the active patient (the active-patient providers + the
/// medication / dose-window lists that query by patient) so the whole app
/// re-centres without a relaunch (multi-patient, Issue #6).
Future<void> switchActivePatient(WidgetRef ref, String patientId) async {
  await ref.read(storageProvider).setActivePatientId(patientId);
  ref.invalidate(activePatientProvider);
  ref.invalidate(activePatientIdProvider);
  ref.invalidate(lovedOnesViewProvider);
  ref.invalidate(medicationListProvider);
  ref.invalidate(doseWindowListProvider);
  // The setup gate re-reads storage; a patient is still on file so it
  // stays true (this keeps `patientConfiguredProvider` consistent if a
  // switch ever races a redirect evaluation).
  await ref.read(patientConfiguredProvider.notifier).reload();
}

/// "Loved ones" manager at `/loved-ones` (multi-patient, Issue #6).
///
/// Reached from Settings → "Loved ones". Lists every loved one on file
/// with the active one flagged, lets the caregiver switch the active
/// person with a tap, and offers "Add a loved one" → the
/// [LovedOneSetupScreen] in add mode. Mirrors the Care Circle roster's
/// list + PathHeader pattern so it reads consistently with the rest of
/// the app, and lives off the Home surface so the Home golden is
/// untouched.
class LovedOnesScreen extends ConsumerWidget {
  const LovedOnesScreen({super.key});

  static const Key listKey = Key('loved-ones-list');
  static const Key addButtonKey = Key('loved-ones-add');
  static const Key emptyStateKey = Key('loved-ones-empty');

  /// Stable per-row keys derived from the patient id so tests target a
  /// node rather than a copy string.
  static Key rowKey(String patientId) => Key('loved-ones-row-$patientId');
  static Key activeBadgeKey(String patientId) =>
      Key('loved-ones-active-$patientId');

  static const String addRoute = '/loved-ones/add';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LovedOnesView> async = ref.watch(lovedOnesViewProvider);
    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Settings', route: '/settings'),
                  PathHeaderCrumb(label: 'Loved ones'),
                ],
                title: 'Loved ones',
                backLabel: 'Back to Settings',
                leadingIcon: Icons.people_alt_outlined,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => FormErrorView(
                    message: "We couldn't load your loved ones.\n$e"),
                data: (LovedOnesView view) => _Body(view: view),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.view});

  final LovedOnesView view;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: LovedOnesScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        if (view.isEmpty)
          const _EmptyState()
        else
          for (final Patient patient in view.patients)
            _PatientRow(
              patient: patient,
              isActive: patient.id == view.activeId,
            ),
        const SizedBox(height: 12),
        const _AddButton(),
      ],
    );
  }
}

class _PatientRow extends ConsumerWidget {
  const _PatientRow({required this.patient, required this.isActive});

  final Patient patient;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String subtitle = _subtitle(patient);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        selected: isActive,
        label: '${patient.name}.'
            '${isActive ? ' Currently active.' : ' Tap to make active.'}',
        child: Material(
          color: context.hc.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: LovedOnesScreen.rowKey(patient.id),
            borderRadius: BorderRadius.circular(16),
            onTap: isActive
                ? null
                : () => switchActivePatient(ref, patient.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 24,
                    backgroundColor:
                        context.hc.primarySoft.withValues(alpha: 0.14),
                    child: Text(
                      _initials(patient.name),
                      style: textTheme.titleLarge?.copyWith(
                        color: context.hc.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          patient.name,
                          style: textTheme.bodyLarge?.copyWith(
                            color: context.hc.primary,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: textTheme.bodyMedium?.copyWith(
                              color: context.hc.primarySoft,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (isActive)
                    _ActiveBadge(patientId: patient.id)
                  else
                    Icon(
                      Icons.radio_button_unchecked,
                      color: context.hc.primarySoft,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "78 · Alzheimer's disease" — age + diagnosis when present, trimmed
  /// of empty halves so a sparse profile reads clean.
  String _subtitle(Patient p) {
    final List<String> parts = <String>[
      if (p.age > 0) '${p.age}',
      if (p.diagnosis.trim().isNotEmpty) p.diagnosis.trim(),
    ];
    return parts.join(' · ');
  }
}

class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: LovedOnesScreen.activeBadgeKey(patientId),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: context.hc.cta.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: context.hc.cta),
      ),
      child: Text(
        'Active',
        style: textTheme.bodyMedium?.copyWith(
          color: context.hc.cta,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Add a loved one. Opens the setup form.',
      child: ElevatedButton.icon(
        key: LovedOnesScreen.addButtonKey,
        onPressed: () => context.push(LovedOnesScreen.addRoute),
        icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
        label: Text(
          'Add a loved one',
          style: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: context.hc.ctaFilled,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
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
      key: LovedOnesScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(8, 24, 8, 24),
      child: Text(
        "No loved ones on file yet. Add the person you're caring for to "
        'get started.',
        style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
      ),
    );
  }
}
/// Up to two uppercase initials from [name]; `?` for an empty name.
String _initials(String name) {
  final List<String> parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((String p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}
