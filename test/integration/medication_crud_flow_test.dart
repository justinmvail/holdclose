/// Integration coverage for the medication CRUD flow (BUILD_SPEC.md
/// §5.13 Medical hub → Medications tile → the medication list / form),
/// per TASKS.md Phase 15.6.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (in-memory drift, pinned clock, no-op TTS/analytics/
/// notifications) and assert real navigation + drift persistence — never
/// goldens. Three groups, one caregiver flow each:
///   1. **Add** — empty list → "Add a medication" CTA → fill the form →
///      Save → the new row appears in the list and a real drift
///      [Medication] row is written. (The form has no frequency input by
///      design — BUILD_SPEC.md §5.13 defers schedule editing to a later
///      surface — so "frequency" here is the default daily-at-8AM
///      [DoseSchedule] the add path mints alongside the medication.)
///   2. **Edit** — tap an existing row → the form hydrates pre-filled →
///      change the dosage → Save → the list (and the saved drift row)
///      reflect the new dosage. The existing schedule is preserved.
///   3. **Delete** — long-press a row → confirm → the medication is
///      *soft*-deleted (its [Medication.deletedAt] tombstone is set, the
///      row stays on disk) → the list excludes it.
///
/// After each mutation the test opens [DoseLogScreen] and asserts the
/// dose-schedule provider ([dosesTodayProvider], which expands every live
/// medication's schedule onto "today") reflects the change: the added
/// med's 8AM dose appears, the edited med's dose shows the new dosage,
/// and the deleted med's dose is gone.
///
/// The harness pins every clock to [kHarnessClock] (2026-06-01 11:00) but
/// leaves the medication form's own clock + id factory at their random
/// defaults, so each test supplies [_crudOverrides]: a pinned form clock
/// (so the default schedule's `startsOn` is "today") and a monotonic id
/// factory (so the minted medication id is deterministic — `med-id0`).
library;

import 'dart:async';

import 'package:careblazers/models/medication.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/screens/medication/medication_form_screen.dart';
import 'package:careblazers/screens/medication/medication_list_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

/// The medication id the add-form mints under the monotonic id factory
/// (`med-${mint()}` with `mint()` → `id0`).
const String _addedMedId = 'med-id0';

/// The id of the medication tests 2 + 3 seed directly through the repo.
const String _seedMedId = 'crud-med-1';

/// The single scheduled instant on the pinned "today" for a daily-8AM
/// schedule — the dose row both the added and the seeded medication
/// surface on [DoseLogScreen].
final DateTime _eightAmToday = DateTime(2026, 6, 1, 8, 0);

/// Pin the medication form's clock + id factory so the minted medication
/// id and the default schedule's `startsOn` are deterministic. A fresh
/// monotonic counter per call ('id0', 'id1', …): the add path takes
/// `med-id0` for the medication and `sched-id1` for its schedule.
List<Override> _crudOverrides() {
  int counter = 0;
  return <Override>[
    medicationFormClockProvider.overrideWithValue(() => kHarnessClock),
    medicationFormIdFactoryProvider.overrideWithValue(() => 'id${counter++}'),
    medicationListClockProvider.overrideWithValue(() => kHarnessClock),
  ];
}

void main() {
  group('Medication CRUD — add a medication (Phase 15.6)', () {
    testWidgets('empty list → form → Save writes the row + dose appears',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _crudOverrides());

      await _openMedicationList(tester);
      // Entry state: nothing tracked yet.
      expect(find.byKey(MedicationListScreen.emptyStateKey), findsOneWidget);

      // Tap the empty-state "Add a medication" CTA → the form.
      await _tap(tester, MedicationListScreen.emptyCtaKey);
      expect(find.byType(MedicationFormScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Add medication'), findsOneWidget);

      // Fill name + dosage; route defaults to oral; the daily-8AM
      // schedule is the form's implicit "frequency".
      await tester.enterText(
        find.byKey(MedicationFormScreen.nameFieldKey),
        'Donepezil',
      );
      await tester.enterText(
        find.byKey(MedicationFormScreen.dosageFieldKey),
        '10 mg',
      );
      await _tap(tester, MedicationFormScreen.submitButtonKey);

      // Back on the list, the new row is rendered with the entered name.
      expect(find.byType(MedicationListScreen), findsOneWidget);
      expect(
        find.byKey(MedicationListScreen.tileKey(_addedMedId)),
        findsOneWidget,
      );
      expect(find.text('Donepezil'), findsOneWidget);

      // The drift row was written — re-read straight from the repository.
      final MedicationRepository repo =
          container.read(medicationRepositoryBackendProvider);
      final Medication? saved = await repo.getMedication(_addedMedId);
      expect(saved, isNotNull);
      expect(saved!.name, 'Donepezil');
      expect(saved.dosage, '10 mg');
      expect(saved.route, MedicationRoute.oral);
      expect(saved.deletedAt, isNull);
      // …and its default daily-8AM schedule rode along.
      final List<DoseSchedule> schedules = await repo.schedulesFor(_addedMedId);
      expect(schedules, hasLength(1));
      expect(schedules.single.frequencyKind, FrequencyKind.daily);

      // The dose-schedule provider now expands the new med's 8AM dose
      // onto today.
      final List<ScheduledDose> doses = await _readDosesToday(container);
      expect(doses.any((ScheduledDose d) => d.medication.id == _addedMedId),
          isTrue);

      // And the dose-log screen renders that row.
      await _openDoseLog(container, tester);
      expect(
        find.byKey(DoseLogScreen.rowKey(_addedMedId, _eightAmToday)),
        findsOneWidget,
      );
      await _flushTimers(tester);
    });
  });

  group('Medication CRUD — edit a medication (Phase 15.6)', () {
    testWidgets('tap row → pre-filled form → change dosage → list updates',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _crudOverrides());
      await _seedMedication(tester, container, dosage: '10 mg');

      await _openMedicationList(tester);
      expect(
          find.byKey(MedicationListScreen.tileKey(_seedMedId)), findsOneWidget);

      // Tap the row → the edit form, hydrated from the saved row.
      await _tap(tester, MedicationListScreen.tileKey(_seedMedId));
      expect(find.byType(MedicationFormScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Edit medication'), findsOneWidget);
      // Pre-fill: the saved name + dosage render in their fields.
      expect(find.text('Donepezil'), findsOneWidget);
      expect(find.text('10 mg'), findsOneWidget);

      // Change the dosage and save.
      await tester.enterText(
        find.byKey(MedicationFormScreen.dosageFieldKey),
        '5 mg',
      );
      await _tap(tester, MedicationFormScreen.submitButtonKey);

      // The list reflects the new dosage; the old value is gone.
      expect(find.byType(MedicationListScreen), findsOneWidget);
      expect(find.text('5 mg'), findsOneWidget);
      expect(find.text('10 mg'), findsNothing);

      // The drift row carries the new dosage; the schedule was preserved.
      final MedicationRepository repo =
          container.read(medicationRepositoryBackendProvider);
      expect((await repo.getMedication(_seedMedId))!.dosage, '5 mg');
      expect(await repo.schedulesFor(_seedMedId), hasLength(1));

      // The dose-schedule provider's row for the med shows the new dosage.
      final List<ScheduledDose> doses = await _readDosesToday(container);
      final ScheduledDose dose =
          doses.firstWhere((ScheduledDose d) => d.medication.id == _seedMedId);
      expect(dose.medication.dosage, '5 mg');

      await _openDoseLog(container, tester);
      expect(
        find.byKey(DoseLogScreen.rowKey(_seedMedId, _eightAmToday)),
        findsOneWidget,
      );
      expect(find.text('5 mg'), findsOneWidget);
      await _flushTimers(tester);
    });
  });

  group('Medication CRUD — delete a medication (Phase 15.6)', () {
    testWidgets('long-press → confirm → soft-delete drops it everywhere',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _crudOverrides());
      await _seedMedication(tester, container, dosage: '10 mg');

      await _openMedicationList(tester);
      expect(
          find.byKey(MedicationListScreen.tileKey(_seedMedId)), findsOneWidget);

      // Long-press raises the confirmation dialog.
      await tester
          .longPress(find.byKey(MedicationListScreen.tileKey(_seedMedId)));
      await tester.pumpAndSettle();
      expect(find.byKey(MedicationListScreen.deleteDialogKey), findsOneWidget);

      // Confirm → the row leaves the list (back to the empty state).
      await _tap(tester, MedicationListScreen.deleteConfirmKey);
      expect(
          find.byKey(MedicationListScreen.tileKey(_seedMedId)), findsNothing);
      expect(find.byKey(MedicationListScreen.emptyStateKey), findsOneWidget);

      // Soft-delete: the row survives on disk with a tombstone, but it is
      // excluded from the live list.
      final MedicationRepository repo =
          container.read(medicationRepositoryBackendProvider);
      final Medication? tombstoned = await repo.getMedication(_seedMedId);
      expect(tombstoned, isNotNull);
      expect(tombstoned!.deletedAt, kHarnessClock);
      expect(await repo.listMedications(), isEmpty);

      // The dose-schedule provider no longer surfaces the med's dose.
      final List<ScheduledDose> doses = await _readDosesToday(container);
      expect(doses.any((ScheduledDose d) => d.medication.id == _seedMedId),
          isFalse);

      await _openDoseLog(container, tester);
      expect(
        find.byKey(DoseLogScreen.rowKey(_seedMedId, _eightAmToday)),
        findsNothing,
      );
      expect(find.byKey(DoseLogScreen.emptyStateKey), findsOneWidget);
      await _flushTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// Seeding
// ---------------------------------------------------------------------------

/// Seed one daily-8AM medication (id [_seedMedId]) straight through the
/// harness's in-memory repository, then invalidate the medication-list +
/// dose-schedule providers so the already-settled surfaces re-read it.
Future<void> _seedMedication(
  WidgetTester tester,
  ProviderContainer container, {
  required String dosage,
}) async {
  final MedicationRepository repo =
      container.read(medicationRepositoryBackendProvider);
  await repo.upsertMedication(Medication(
    id: _seedMedId,
    name: 'Donepezil',
    dosage: dosage,
    route: MedicationRoute.oral,
  ));
  await repo.upsertSchedule(DoseSchedule(
    id: 'crud-sched-1',
    medicationId: _seedMedId,
    frequencyKind: FrequencyKind.daily,
    timesOfDay: const <TimeOfDay>[TimeOfDay(hour: 8, minute: 0)],
    daysOfWeek: const <int>{},
    startsOn: DateTime(2026, 5, 1),
  ));
  container.invalidate(medicationListProvider);
  container.invalidate(dosesTodayProvider);
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Navigation + assertion helpers
// ---------------------------------------------------------------------------

/// Home → Medical tab → Medications tile → [MedicationListScreen].
Future<void> _openMedicationList(WidgetTester tester) async {
  await tester.tap(tabFor('Medical'));
  await tester.pumpAndSettle();
  expect(find.byType(MedicalHubScreen), findsOneWidget);

  await tester.tap(findHubTile('Medications'));
  await tester.pumpAndSettle();
  expect(find.byType(MedicationListScreen), findsOneWidget);
}

/// Push the dose-log route and confirm [DoseLogScreen] mounts. The
/// dose-schedule provider is invalidated first so the screen re-reads the
/// latest repository state (Home keeps [dosesTodayProvider] alive while
/// its Medications Today card is mounted, so a mutation needs the nudge —
/// the same pattern the Phase 15.5 dose-log flow uses).
Future<void> _openDoseLog(
  ProviderContainer container,
  WidgetTester tester,
) async {
  container.invalidate(dosesTodayProvider);
  unawaited(container
      .read(careblazersRouterProvider)
      .pushNamed(CareblazersRoutes.medicationDoseLog));
  await tester.pumpAndSettle();
  expect(find.byType(DoseLogScreen), findsOneWidget);
}

/// Re-read the dose-schedule provider fresh (after invalidation) — the
/// "dose-schedule provider reflects the change" assertion the task asks
/// for, read straight rather than through the widget tree.
Future<List<ScheduledDose>> _readDosesToday(ProviderContainer container) async {
  container.invalidate(dosesTodayProvider);
  return container.read(dosesTodayProvider.future);
}

/// Scroll [key] into view (the form's Save button + lower rows can sit
/// below the fold on the harness's 420×900 surface) then tap + settle.
Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// Drain any bare-timer streams (e.g. Home's still-mounted "catch me up"
/// recap) so none outlive the test and trip flutter_test's "Timer still
/// pending" invariant — mirrors the Phase 15.5 flow's recap flush.
Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}
