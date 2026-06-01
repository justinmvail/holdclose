import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/appointment/appointment_form_screen.dart';
import 'package:careblazers/screens/journal/journal_wizard_screen.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:careblazers/services/voice_intake.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// End-to-end coverage for the Phase 14.14 voice-intake plumbing: an
/// [AddSheetTranscript] pushed onto a destination route (exactly what the
/// Home Add sheet does) lands as a pre-filled field on the destination
/// screen. Drives the REAL [buildRouter] so the router's bridge wiring is
/// exercised, not a stand-in.
///
/// `/decoder/triage` with no extra is the initial location because it
/// renders a provider-free soft-fallback page — a clean launch pad to
/// push the target route (with the transcript) onto.
DateTime _fixedNow() => DateTime(2026, 5, 30, 11, 0);

Future<GoRouter> _pump(
  WidgetTester tester, {
  List<Override> overrides = const <Override>[],
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = buildRouter(initialLocation: '/decoder/triage');
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets(
      'journal-entry transcript seeds the wizard situation step',
      (WidgetTester tester) async {
    final GoRouter router = await _pump(tester);

    unawaited(router.pushNamed(
      CareblazersRoutes.journalNew,
      extra: const AddSheetTranscript(
        text: 'she kept asking to call her mother',
        kind: AddSheetKind.journalEntry,
      ),
    ));
    await tester.pumpAndSettle();

    // Step 0 (when) → pick a preset, advance to the situation step.
    await tester.tap(find.byKey(JournalWizardScreen.whenPresetJustNowKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
    await tester.pumpAndSettle();

    final TextField situation = tester.widget<TextField>(
      find.byKey(JournalWizardScreen.situationFieldKey),
    );
    expect(situation.controller?.text, 'she kept asking to call her mother');
  });

  testWidgets('quick-note transcript also seeds the wizard',
      (WidgetTester tester) async {
    final GoRouter router = await _pump(tester);

    unawaited(router.pushNamed(
      CareblazersRoutes.journalNew,
      queryParameters: const <String, String>{'kind': 'note'},
      extra: const AddSheetTranscript(
        text: 'remember the spare keys',
        kind: AddSheetKind.quickNote,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(JournalWizardScreen.whenPresetJustNowKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
    await tester.pumpAndSettle();

    final TextField situation = tester.widget<TextField>(
      find.byKey(JournalWizardScreen.situationFieldKey),
    );
    expect(situation.controller?.text, 'remember the spare keys');
  });

  testWidgets('med-dose transcript pre-fills the dose-note field',
      (WidgetTester tester) async {
    final CareblazersDatabase db =
        CareblazersDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final MedicationRepository repo =
        MedicationRepository(db, clock: _fixedNow);

    final GoRouter router = await _pump(
      tester,
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        doseLogClockProvider.overrideWithValue(_fixedNow),
      ],
    );

    unawaited(router.pushNamed(
      CareblazersRoutes.medicationDoseLog,
      extra: const AddSheetTranscript(
        text: 'gave it with breakfast',
        kind: AddSheetKind.medDose,
      ),
    ));
    await tester.pumpAndSettle();

    final TextField note = tester.widget<TextField>(
      find.byKey(DoseLogScreen.noteFieldKey),
    );
    expect(note.controller?.text, 'gave it with breakfast');
  });

  testWidgets('appointment transcript pre-fills the visit-notes textarea',
      (WidgetTester tester) async {
    final CareblazersDatabase db =
        CareblazersDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final ProviderRepository providerRepo = ProviderRepository(db);

    final GoRouter router = await _pump(
      tester,
      overrides: <Override>[
        providerRepositoryBackendProvider.overrideWithValue(providerRepo),
      ],
    );

    unawaited(router.pushNamed(
      CareblazersRoutes.appointmentForm,
      extra: const AddSheetTranscript(
        text: 'ask about evening agitation',
        kind: AddSheetKind.appointment,
      ),
    ));
    await tester.pumpAndSettle();

    final TextFormField notes = tester.widget<TextFormField>(
      find.byKey(AppointmentFormScreen.notesFieldKey),
    );
    expect(notes.controller?.text, 'ask about evening agitation');
  });

  testWidgets('a plain push with no transcript leaves the dose-note field off',
      (WidgetTester tester) async {
    final CareblazersDatabase db =
        CareblazersDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final MedicationRepository repo =
        MedicationRepository(db, clock: _fixedNow);

    final GoRouter router = await _pump(
      tester,
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        doseLogClockProvider.overrideWithValue(_fixedNow),
      ],
    );

    unawaited(router.pushNamed(CareblazersRoutes.medicationDoseLog));
    await tester.pumpAndSettle();

    expect(find.byKey(DoseLogScreen.noteFieldKey), findsNothing);
  });
}
