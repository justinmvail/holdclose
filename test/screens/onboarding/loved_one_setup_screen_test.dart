import 'package:careblazers/l10n/app_localizations.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/onboarding/loved_one_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

/// Pump [LovedOneSetupScreen] at `/setup` inside a minimal router with a
/// `/` stub (marker text 'test-home') so a successful save's
/// `context.go('/')` is observable. Storage is backed by the supplied
/// [storage] so the test can read back the persisted [Patient]; the id
/// factory is pinned so the saved id is deterministic.
Future<({GoRouter router})> _pumpSetup(
  WidgetTester tester, {
  required StorageProvider storage,
  String mintedId = 'patient-test-1',
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/setup',
    routes: <RouteBase>[
      GoRoute(
        path: '/setup',
        builder: (BuildContext context, GoRouterState state) =>
            const LovedOneSetupScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('test-home'))),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
        patientSetupIdFactoryProvider.overrideWithValue(() => mintedId),
      ],
      child: MaterialApp.router(
        // The wizard reads its chrome strings via AppLocalizations.of (#18
        // localization); register the generated delegate + supportedLocales
        // so `.of(context)` resolves (nullable-getter: false).
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router);
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

/// Scroll the save button into view (the form is a lazy ListView, so on
/// smaller viewports the button starts unbuilt below the fold) then tap
/// it. The outer ListView's Scrollable is the first in the tree; inner
/// per-TextField Scrollables come after, so `.first` targets the list.
Future<void> _tapSave(WidgetTester tester) async {
  final Finder save = find.byKey(LovedOneSetupScreen.saveButtonKey);
  await tester.scrollUntilVisible(
    save,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  group('LovedOneSetupScreen — chrome + copy', () {
    testWidgets('renders the warm intro + the required name field',
        (WidgetTester tester) async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);

      await _pumpSetup(tester, storage: storage);

      expect(find.text("Let's set up your person"), findsOneWidget);
      expect(find.byKey(LovedOneSetupScreen.nameFieldKey), findsOneWidget);

      // Save lives at the bottom of the long form — scroll it into the
      // lazy ListView before asserting it's present.
      await tester.scrollUntilVisible(
        find.byKey(LovedOneSetupScreen.saveButtonKey),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(LovedOneSetupScreen.saveButtonKey), findsOneWidget);
    });

    testWidgets('save button carries a Semantics label',
        (WidgetTester tester) async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);

      await _pumpSetup(tester, storage: storage);

      // The button starts below the fold in the lazy ListView; scroll it
      // into the tree so its Semantics widget is built before asserting.
      await tester.scrollUntilVisible(
        find.byKey(LovedOneSetupScreen.saveButtonKey),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(
        hasSemanticsLabel(tester, RegExp('Save your person')),
        isTrue,
      );
    });
  });

  group('LovedOneSetupScreen — validation', () {
    testWidgets('rejects an empty name — no save, stays on /setup',
        (WidgetTester tester) async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);

      final ({GoRouter router}) pumped =
          await _pumpSetup(tester, storage: storage);

      // Tap Save with the name field left blank.
      await _tapSave(tester);

      // The field validator surfaces, nothing is persisted, and we never
      // leave the wizard.
      expect(find.text('Please enter their name.'), findsOneWidget);
      expect(await storage.getPatient(), isNull);
      expect(_path(pumped.router), '/setup');
      expect(find.text('test-home'), findsNothing);
    });

    testWidgets('a blank name with other fields filled still blocks save',
        (WidgetTester tester) async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);

      await _pumpSetup(tester, storage: storage);

      await tester.enterText(
        find.byKey(LovedOneSetupScreen.diagnosisFieldKey),
        "Alzheimer's disease",
      );
      await _tapSave(tester);

      expect(find.text('Please enter their name.'), findsOneWidget);
      expect(await storage.getPatient(), isNull);
    });
  });

  group('LovedOneSetupScreen — save', () {
    testWidgets(
      'filling name + a few fields persists a Patient and navigates to /',
      (WidgetTester tester) async {
        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        addTearDown(storage.dispose);

        final ({GoRouter router}) pumped = await _pumpSetup(
          tester,
          storage: storage,
          mintedId: 'patient-fixed-id',
        );

        await tester.enterText(
          find.byKey(LovedOneSetupScreen.nameFieldKey),
          'Mary Henderson',
        );
        await tester.enterText(
          find.byKey(LovedOneSetupScreen.ageFieldKey),
          '78',
        );
        await tester.enterText(
          find.byKey(LovedOneSetupScreen.diagnosisFieldKey),
          "Alzheimer's disease",
        );
        // Multiline fields: one item per line.
        await tester.enterText(
          find.byKey(LovedOneSetupScreen.allergiesFieldKey),
          'Penicillin\nSulfa',
        );

        await _tapSave(tester);

        // Navigated to Home.
        expect(_path(pumped.router), '/');
        expect(find.text('test-home'), findsOneWidget);

        // Persisted through the storage repo with the fields the wizard
        // collected + the sensible defaults for the omitted ones.
        final Patient? saved = await storage.getPatient();
        expect(saved, isNotNull);
        expect(saved!.id, 'patient-fixed-id');
        expect(saved.name, 'Mary Henderson');
        expect(saved.age, 78);
        expect(saved.diagnosis, "Alzheimer's disease");
        expect(saved.allergies, <String>['Penicillin', 'Sulfa']);
        // Calms / escalates / primary caregiver are no longer collected in
        // setup — they default empty and are editable elsewhere later.
        expect(saved.calms, isEmpty);
        expect(saved.escalates, isEmpty);
        expect(saved.primaryCaregiver.name, isEmpty);
        expect(saved.primaryCaregiver.phone, isEmpty);
        // Defaults the wizard fills in for the omitted fields.
        expect(saved.medications, isEmpty);
        expect(
          saved.healthcarePOA,
          saved.primaryCaregiver,
          reason: 'POA mirrors the primary caregiver by default',
        );
        expect(saved.advanceDirective.dnr, isFalse);
        expect(saved.advanceDirective.onFileAt, 'Not on file');
      },
    );

    testWidgets(
      'name only (everything else blank) still saves with sane defaults',
      (WidgetTester tester) async {
        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        addTearDown(storage.dispose);

        final ({GoRouter router}) pumped =
            await _pumpSetup(tester, storage: storage);

        await tester.enterText(
          find.byKey(LovedOneSetupScreen.nameFieldKey),
          'Pat',
        );
        await _tapSave(tester);

        expect(_path(pumped.router), '/');
        final Patient? saved = await storage.getPatient();
        expect(saved, isNotNull);
        expect(saved!.name, 'Pat');
        // Blank age defaults to 0 ("not given") rather than crashing.
        expect(saved.age, 0);
        expect(saved.diagnosis, isEmpty);
        expect(saved.allergies, isEmpty);
        expect(saved.calms, isEmpty);
        expect(saved.escalates, isEmpty);
        expect(saved.primaryCaregiver.name, isEmpty);
      },
    );

    testWidgets('rejects a wildly out-of-range age',
        (WidgetTester tester) async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);

      await _pumpSetup(tester, storage: storage);

      await tester.enterText(
        find.byKey(LovedOneSetupScreen.nameFieldKey),
        'Mary',
      );
      await tester.enterText(
        find.byKey(LovedOneSetupScreen.ageFieldKey),
        '999',
      );
      await _tapSave(tester);

      expect(find.text('Enter an age between 0 and 130.'), findsOneWidget);
      expect(await storage.getPatient(), isNull);
    });
  });

  // Multi-patient ADD mode (Issue #6): the same wizard reached from the
  // "Loved ones" manager appends a loved one + makes them active, and pops
  // back instead of gating to Home.
  group('LovedOneSetupScreen — add mode', () {
    Future<({GoRouter router})> pumpAdd(
      WidgetTester tester, {
      required StorageProvider storage,
      String mintedId = 'patient-added-1',
    }) async {
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final GoRouter router = GoRouter(
        initialLocation: '/loved-ones/add',
        routes: <RouteBase>[
          GoRoute(
            path: '/loved-ones',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('manager-stub'))),
            routes: <RouteBase>[
              GoRoute(
                path: 'add',
                builder: (BuildContext c, GoRouterState s) =>
                    const LovedOneSetupScreen(isAdd: true),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            patientSetupIdFactoryProvider.overrideWithValue(() => mintedId),
          ],
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (router: router);
    }

    testWidgets(
      'saving appends the loved one, makes them active, and pops back',
      (WidgetTester tester) async {
        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        addTearDown(storage.dispose);
        // An existing loved one is already on file + active.
        await storage.upsertPatient(
          Patient(
            id: 'p-existing',
            name: 'Mary Henderson',
            age: 78,
            diagnosis: 'Dementia',
            diagnosedAt: DateTime.utc(2022, 1, 1),
            medications: const <CrisisMedication>[],
            allergies: const <String>[],
            calms: const <String>[],
            escalates: const <String>[],
            primaryCaregiver: const Contact(name: 'Sam', phone: '555'),
            healthcarePOA: const Contact(name: 'Sam', phone: '555'),
            advanceDirective: const AdvanceDirectiveStatus(
                onFileAt: 'Not on file', dnr: false),
          ),
        );
        await storage.setActivePatientId('p-existing');

        final ({GoRouter router}) pumped = await pumpAdd(
          tester,
          storage: storage,
          mintedId: 'p-new',
        );

        await tester.enterText(
          find.byKey(LovedOneSetupScreen.nameFieldKey),
          'Frank Albright',
        );
        final Finder save = find.byKey(LovedOneSetupScreen.saveButtonKey);
        await tester.scrollUntilVisible(save, 300,
            scrollable: find.byType(Scrollable).first);
        await tester.tap(save);
        await tester.pumpAndSettle();

        // Popped back to the manager (NOT Home).
        expect(_path(pumped.router), '/loved-ones');
        expect(find.text('manager-stub'), findsOneWidget);

        // Both loved ones on file; the new one is now active.
        expect((await storage.listPatients()).map((Patient p) => p.id),
            containsAll(<String>['p-existing', 'p-new']));
        expect(await storage.getActivePatientId(), 'p-new');
        expect((await storage.getPatient())!.id, 'p-new');
      },
    );
  });
}
