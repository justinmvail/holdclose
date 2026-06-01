/// Integration coverage for the dose-log marking flow (BUILD_SPEC.md
/// §5.18 Medications Today card → §5.13 Medical → the dose-log screen),
/// per TASKS.md Phase 15.5.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (in-memory drift, pinned clock, no-op TTS/analytics) and
/// assert real navigation + drift persistence — never goldens. Five
/// groups, each one logical caregiver flow end-to-end:
///   1. Tap an unlogged dose row (its checkbox is the row's leading
///      indicator) → status flips to taken → the drift row persists
///      (re-read straight from the repository).
///   2. Tap the per-row "Mark taken" button → same persisted flip.
///   3. Tap a logged-taken row → the status bottom sheet appears → tap
///      "Skipped" → status changes + the sheet dismisses.
///   4. Tap "Mark all before noon" → every morning *pending* dose flips
///      to taken in one tap (the already-taken morning dose is left
///      alone, the afternoon dose is out of range).
///   5. The Home Add-sheet voice path hands a transcript to the dose-log
///      route as nav `extra` (an [AddSheetTranscript] of kind `medDose`)
///      and it lands pre-filled in the note field, then rides along into
///      the [DoseLog.notes] of the next dose the caregiver marks.
///
/// After each mutation the test pops back to Home and asserts the
/// Medications Today card's "X of Y" count re-reads the new state.
///
/// Naming note: the Phase 15.5 task copy calls the payload
/// `VoiceTranscript(...)` and the pre-fill target a "bottom sheet
/// textarea"; in the shipped code the payload is [AddSheetTranscript]
/// (lib/services/voice_intake.dart) and the target is the dose-log
/// screen's pre-filled note field (`DoseLogScreen.noteFieldKey`). Tested
/// against the real types.
///
/// Seed shape (4 doses on the pinned "today", 2026-06-01): one daily
/// schedule firing at 08:00 (logged taken), 10:45 + 10:50 (unlogged
/// morning), and 14:00 (logged missed afternoon). The two unlogged
/// morning times sit inside the 30-minute "late" threshold of the
/// 11:00 clock, so marking them records [DoseStatus.taken] (not `late`).
library;

import 'dart:async';

import 'package:careblazers/models/medication.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/voice_intake.dart';
import 'package:careblazers/widgets/home/medications_today_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

const String _medId = 'flow-med-donepezil';

/// The four scheduled instants on the pinned "today" (2026-06-01).
final DateTime _takenMorning = DateTime(2026, 6, 1, 8, 0);
final DateTime _unloggedA = DateTime(2026, 6, 1, 10, 45);
final DateTime _unloggedB = DateTime(2026, 6, 1, 10, 50);
final DateTime _missedAfternoon = DateTime(2026, 6, 1, 14, 0);

/// Monotonic id minter so any freshly-written [DoseLog] compares
/// deterministically across runs (the harness pins the clock but leaves
/// the id factory at its random default).
List<Override> _idOverrides() {
  int counter = 0;
  return <Override>[
    doseLogIdFactoryProvider.overrideWithValue(() => 'flow-log-${counter++}'),
  ];
}

void main() {
  group('Dose log — checkbox flips an unlogged dose to taken (Phase 15.5)',
      () {
    testWidgets('tapping the row marks taken + persists to drift',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _idOverrides());
      await _seedFourDoses(tester, container);

      // Entry: Home card reads "1 of 4" — only the 08:00 dose is taken.
      expect(_cardCount(tester), '1 of 4');

      await _openDoseLog(tester);
      // The unlogged morning row shows its "Mark taken" CTA (i.e. it is
      // genuinely unlogged before we touch it).
      expect(
        find.byKey(DoseLogScreen.markTakenButtonKey(_medId, _unloggedA)),
        findsOneWidget,
      );

      // The checkbox IS the row tap target for an unlogged dose.
      await _tap(tester, DoseLogScreen.rowKey(_medId, _unloggedA));

      // The row is now logged: its CTA is gone, a "Taken" label shows.
      expect(
        find.byKey(DoseLogScreen.markTakenButtonKey(_medId, _unloggedA)),
        findsNothing,
      );
      expect(find.text('Taken'), findsWidgets);

      // Reload straight from the repository → the drift row persisted.
      final DoseLog log = await _logAt(container, _unloggedA);
      expect(log.status, DoseStatus.taken);
      expect(log.takenAt, kHarnessClock);

      // Card re-reads "2 of 4" back on Home.
      await _backToHome(tester);
      expect(_cardCount(tester), '2 of 4');
    });
  });

  group('Dose log — the "Mark taken" button flips a dose (Phase 15.5)', () {
    testWidgets('tapping the per-row CTA marks taken + persists',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _idOverrides());
      await _seedFourDoses(tester, container);
      expect(_cardCount(tester), '1 of 4');

      await _openDoseLog(tester);
      await _tap(tester, DoseLogScreen.markTakenButtonKey(_medId, _unloggedB));

      expect(
        find.byKey(DoseLogScreen.markTakenButtonKey(_medId, _unloggedB)),
        findsNothing,
      );
      final DoseLog log = await _logAt(container, _unloggedB);
      expect(log.status, DoseStatus.taken);

      await _backToHome(tester);
      expect(_cardCount(tester), '2 of 4');
    });
  });

  group('Dose log — status sheet re-marks a taken dose skipped (Phase 15.5)',
      () {
    testWidgets('tapping a logged row opens the sheet → "Skipped" applies',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _idOverrides());
      await _seedFourDoses(tester, container);
      expect(_cardCount(tester), '1 of 4');

      await _openDoseLog(tester);

      // Tapping the already-logged 08:00 row opens the status bottom sheet.
      await _tap(tester, DoseLogScreen.rowKey(_medId, _takenMorning));
      expect(
        find.byKey(DoseLogScreen.statusSheetOptionKey(DoseStatus.skipped)),
        findsOneWidget,
      );

      // Choose "Skipped" → the sheet dismisses and the status changes.
      await tester.tap(
        find.byKey(DoseLogScreen.statusSheetOptionKey(DoseStatus.skipped)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(DoseLogScreen.statusSheetOptionKey(DoseStatus.skipped)),
        findsNothing,
      );

      final DoseLog log = await _logAt(container, _takenMorning);
      expect(log.status, DoseStatus.skipped);
      expect(log.takenAt, isNull); // skipped clears the taken stamp.

      // No more taken doses today → the card reads "0 of 4".
      await _backToHome(tester);
      expect(_cardCount(tester), '0 of 4');
    });
  });

  group('Dose log — "Mark all before noon" batches the morning (Phase 15.5)',
      () {
    testWidgets('one tap flips every pending morning dose to taken',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _idOverrides());
      await _seedFourDoses(tester, container);
      expect(_cardCount(tester), '1 of 4');

      await _openDoseLog(tester);
      await _tap(tester, DoseLogScreen.bulkMorningButtonKey);

      // Both unlogged morning doses are now taken; the bulk button retires
      // once nothing before noon is pending.
      expect(await _statusAt(container, _unloggedA), DoseStatus.taken);
      expect(await _statusAt(container, _unloggedB), DoseStatus.taken);
      expect(find.byKey(DoseLogScreen.bulkMorningButtonKey), findsNothing);

      // The already-taken morning dose is untouched and the afternoon
      // dose stays missed — the batch only swept *pending* before-noon rows.
      expect(await _statusAt(container, _takenMorning), DoseStatus.taken);
      expect(await _statusAt(container, _missedAfternoon), DoseStatus.missed);

      // 3 of the 4 doses are now taken on the Home card.
      await _backToHome(tester);
      expect(_cardCount(tester), '3 of 4');
    });
  });

  group('Dose log — voice transcript pre-fills the note field (Phase 15.5)',
      () {
    testWidgets('an AddSheetTranscript extra lands pre-filled + rides the log',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: _idOverrides());
      await _seedFourDoses(tester, container);
      expect(_cardCount(tester), '1 of 4');

      // The Home Add-sheet voice button forwards the captured phrase to the
      // dose-log route as nav `extra`; reproduce that hand-off directly.
      const String spoken = 'gave it with applesauce';
      unawaited(container.read(careblazersRouterProvider).pushNamed(
            CareblazersRoutes.medicationDoseLog,
            extra: const AddSheetTranscript(
              text: spoken,
              kind: AddSheetKind.medDose,
            ),
          ));
      await tester.pumpAndSettle();
      expect(find.byType(DoseLogScreen), findsOneWidget);

      // The transcript arrived pre-filled in the note field.
      final TextField field =
          tester.widget<TextField>(find.byKey(DoseLogScreen.noteFieldKey));
      expect(field.controller?.text, spoken);

      // Marking the next dose carries the note into its persisted DoseLog.
      await _tap(tester, DoseLogScreen.markTakenButtonKey(_medId, _unloggedA));
      final DoseLog log = await _logAt(container, _unloggedA);
      expect(log.status, DoseStatus.taken);
      expect(log.notes, spoken);

      await _backToHome(tester);
      expect(_cardCount(tester), '2 of 4');
    });
  });
}

// ---------------------------------------------------------------------------
// Seeding
// ---------------------------------------------------------------------------

/// Seed Mary's 4 doses for the pinned "today" through the harness's
/// in-memory medication repository, then invalidate [dosesTodayProvider]
/// so the already-settled Home card re-reads the freshly-seeded state.
Future<void> _seedFourDoses(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final MedicationRepository repo =
      container.read(medicationRepositoryBackendProvider);

  await repo.upsertMedication(const Medication(
    id: _medId,
    name: 'Donepezil',
    dosage: '10 mg',
    route: MedicationRoute.oral,
  ));
  await repo.upsertSchedule(DoseSchedule(
    id: 'flow-sched-donepezil',
    medicationId: _medId,
    frequencyKind: FrequencyKind.daily,
    timesOfDay: const <TimeOfDay>[
      TimeOfDay(hour: 8, minute: 0),
      TimeOfDay(hour: 10, minute: 45),
      TimeOfDay(hour: 10, minute: 50),
      TimeOfDay(hour: 14, minute: 0),
    ],
    daysOfWeek: const <int>{},
    startsOn: DateTime(2026, 5, 1),
  ));
  // 08:00 already taken; 14:00 already missed; 10:45 + 10:50 left unlogged.
  await repo.upsertDoseLog(DoseLog(
    id: 'flow-seed-taken',
    medicationId: _medId,
    scheduledFor: _takenMorning,
    takenAt: _takenMorning,
    status: DoseStatus.taken,
  ));
  await repo.upsertDoseLog(DoseLog(
    id: 'flow-seed-missed',
    medicationId: _medId,
    scheduledFor: _missedAfternoon,
    status: DoseStatus.missed,
  ));

  container.invalidate(dosesTodayProvider);
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Navigation + assertion helpers
// ---------------------------------------------------------------------------

/// Open the dose-log screen by tapping the Home Medications Today card.
Future<void> _openDoseLog(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(MedicationsTodayCard.cardKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(MedicationsTodayCard.cardKey));
  await tester.pumpAndSettle();
  expect(find.byType(DoseLogScreen), findsOneWidget);
}

/// Pop the pushed dose-log screen via its AppBar Back control and confirm
/// we're back on the Home dashboard.
Future<void> _backToHome(WidgetTester tester) async {
  await tester.tap(find.descendant(
    of: find.byType(DoseLogScreen),
    matching: find.byType(BackButton),
  ));
  await tester.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget);
  await _flushRecap(tester);
}

/// Flush Home's "catch me up" recap stream
/// ([FakeLLMProvider.generateActivitySummary]) before teardown. It
/// streams in 60ms-spaced slices via bare timers that `pumpAndSettle`
/// won't advance, so a generous fake-time elapse fires the whole chain
/// and no timer outlives the test (mirrors the Phase 15.4 decoder flow).
Future<void> _flushRecap(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// Scroll [key] into view (the dose list + bulk button can sit below the
/// fold on the harness's 420×900 surface) then tap + settle.
Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// The "X of Y" string the Medications Today card currently renders.
String _cardCount(WidgetTester tester) {
  final Text text =
      tester.widget<Text>(find.byKey(MedicationsTodayCard.countKey));
  return text.data ?? '';
}

/// Re-read the [DoseLog] whose `scheduledFor` is [scheduledFor] straight
/// from the repository (a fresh drift query — the "reload provider" the
/// task asks for). Fails the test if no row exists yet.
Future<DoseLog> _logAt(
  ProviderContainer container,
  DateTime scheduledFor,
) async {
  final MedicationRepository repo =
      container.read(medicationRepositoryBackendProvider);
  final List<DoseLog> logs = await repo.logsFor(_medId);
  return logs.firstWhere((DoseLog l) => l.scheduledFor == scheduledFor);
}

/// The persisted [DoseStatus] for the dose at [scheduledFor].
Future<DoseStatus> _statusAt(
  ProviderContainer container,
  DateTime scheduledFor,
) async =>
    (await _logAt(container, scheduledFor)).status;
