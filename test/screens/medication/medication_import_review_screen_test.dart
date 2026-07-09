import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/models/medication_draft.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/medication/medication_form_screen.dart';
import 'package:holdclose/screens/medication/medication_import_review_screen.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// End-to-end coverage for the scanned-prescription review + approval
/// screen: it pre-fills the AI's read into editable fields, saves NOTHING
/// until the caregiver taps Save (the human-in-the-loop gate), validates,
/// and persists through the same `upsertMedication` path as the form.

DateTime _fixedNow() => DateTime(2026, 6, 4, 9, 0);

Future<void> _pumpReview(
  WidgetTester tester, {
  required MedicationRepository repo,
  required MedicationDraft draft,
  Set<String> uncertain = const <String>{},
  String idValue = '1',
}) async {
  await tester.binding.setSurfaceSize(const Size(440, 2800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/medications/scan/review',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medications',
        parentNavigatorKey: rootKey,
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'scan/review',
            parentNavigatorKey: rootKey,
            builder: (BuildContext c, GoRouterState s) =>
                MedicationImportReviewScreen(
              draft: draft,
              uncertain: uncertain,
            ),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        medicationRepositoryBackendProvider.overrideWithValue(repo),
        medicationFormIdFactoryProvider.overrideWithValue(() => idValue),
        storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

const MedicationDraft _draft = MedicationDraft(
  name: 'Lisinopril',
  dosage: '10 mg',
  route: MedicationRoute.oral,
  prescriber: 'Dr. Alvarez',
  notes: 'Take one tablet by mouth once daily.',
  rxNumber: '1687749',
  quantity: '180',
  refills: '3',
  pharmacyName: 'CVS Pharmacy',
  pharmacyPhone: '843-767-4500',
  dateFilled: '12/3/21',
  discardAfter: '12/3/22',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HoldcloseDatabase db;
  late MedicationRepository repo;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    repo = MedicationRepository(db, clock: _fixedNow);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('pre-fills the fields from the AI draft', (tester) async {
    await _pumpReview(tester, repo: repo, draft: _draft);

    expect(find.byKey(MedicationImportReviewScreen.bannerKey), findsOneWidget);
    // Extracted values are shown, editable, and nothing is saved yet.
    expect(find.text('Lisinopril'), findsOneWidget);
    expect(find.text('10 mg'), findsOneWidget);
    expect(find.text('Dr. Alvarez'), findsOneWidget);
    // Prescription-label details prefilled too.
    expect(find.text('1687749'), findsOneWidget);
    expect(find.text('180'), findsOneWidget);
    expect(find.text('CVS Pharmacy'), findsOneWidget);
    expect(find.text('843-767-4500'), findsOneWidget);
    expect(await repo.listMedications(), isEmpty);
  });

  testWidgets('approving persists via upsert and pops to the list',
      (tester) async {
    await _pumpReview(tester, repo: repo, draft: _draft);

    await tester.tap(find.byKey(MedicationImportReviewScreen.saveButtonKey));
    await tester.pumpAndSettle();

    final List<Medication> meds = await repo.listMedications();
    expect(meds, hasLength(1));
    final Medication saved = meds.single;
    expect(saved.id, 'med-1');
    expect(saved.name, 'Lisinopril');
    expect(saved.dosage, '10 mg');
    expect(saved.route, MedicationRoute.oral);
    expect(saved.prescriber, 'Dr. Alvarez');
    expect(saved.notes, 'Take one tablet by mouth once daily.');
    // Prescription-label details persist through the same upsert path.
    expect(saved.rxNumber, '1687749');
    expect(saved.quantity, '180');
    expect(saved.refills, '3');
    expect(saved.pharmacyName, 'CVS Pharmacy');
    expect(saved.pharmacyPhone, '843-767-4500');
    expect(saved.dateFilled, '12/3/21');
    expect(saved.discardAfter, '12/3/22');
    // Popped back to the list stub.
    expect(find.text('list-stub'), findsOneWidget);
  });

  testWidgets('edits before saving are respected', (tester) async {
    await _pumpReview(tester, repo: repo, draft: _draft);

    await tester.enterText(
        find.byKey(MedicationImportReviewScreen.nameFieldKey), 'Lisinopril HCTZ');
    await tester.tap(find.byKey(MedicationImportReviewScreen.saveButtonKey));
    await tester.pumpAndSettle();

    final Medication saved = (await repo.listMedications()).single;
    expect(saved.name, 'Lisinopril HCTZ');
  });

  testWidgets('a required-field gap blocks save', (tester) async {
    await _pumpReview(tester, repo: repo, draft: _draft);

    await tester.enterText(
        find.byKey(MedicationImportReviewScreen.nameFieldKey), '');
    await tester.tap(find.byKey(MedicationImportReviewScreen.saveButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('Name is required.'), findsOneWidget);
    expect(await repo.listMedications(), isEmpty);
  });

  testWidgets('an empty draft opens blank for manual entry', (tester) async {
    await _pumpReview(tester, repo: repo, draft: const MedicationDraft());

    // No pre-filled values; the screen is a manual-entry surface.
    expect(find.text('Lisinopril'), findsNothing);
    expect(find.byKey(MedicationImportReviewScreen.nameFieldKey),
        findsOneWidget);
  });

  group('uncertainty flagging (weak-data results)', () {
    test('uncertainFieldsFrom parses the scan array, tolerating junk', () {
      expect(
        MedicationImportReviewScreen.uncertainFieldsFrom(<String, dynamic>{
          'uncertain': <dynamic>[' dosage ', '', 3, 'refills'],
        }),
        <String>{'dosage', 'refills'},
      );
      // Missing / malformed → empty set (never crashes an old reply).
      expect(
        MedicationImportReviewScreen.uncertainFieldsFrom(
            <String, dynamic>{'uncertain': 'nope'}),
        isEmpty,
      );
      expect(
        MedicationImportReviewScreen.uncertainFieldsFrom(<String, dynamic>{}),
        isEmpty,
      );
    });

    testWidgets('an uncertain field renders the amber "check this" treatment',
        (tester) async {
      await _pumpReview(
        tester,
        repo: repo,
        draft: _draft,
        uncertain: <String>{'dosage'},
      );

      // Summary banner names the weak read...
      expect(find.byKey(MedicationImportReviewScreen.uncertainBannerKey),
          findsOneWidget);
      // ...and the flagged field carries its own amber hint.
      expect(
        find.byKey(const Key('rx-import-uncertain-dosage')),
        findsOneWidget,
      );
      expect(
        find.textContaining("we weren't sure we read it right",
            findRichText: false),
        findsOneWidget,
      );
      // A field NOT flagged has no hint.
      expect(find.byKey(const Key('rx-import-uncertain-name')), findsNothing);
      // The human-approval gate is intact: nothing saved yet.
      expect(await repo.listMedications(), isEmpty);
    });

    testWidgets('editing a flagged field clears its amber hint', (tester) async {
      await _pumpReview(
        tester,
        repo: repo,
        draft: _draft,
        uncertain: <String>{'dosage'},
      );
      expect(find.byKey(const Key('rx-import-uncertain-dosage')),
          findsOneWidget);

      await tester.enterText(
          find.byKey(MedicationImportReviewScreen.dosageFieldKey), '20 mg');
      await tester.pump();

      // The caregiver has verified it — the amber treatment retires.
      expect(find.byKey(const Key('rx-import-uncertain-dosage')), findsNothing);
      // The single-field banner also clears once the only flag is gone.
      expect(find.byKey(MedicationImportReviewScreen.uncertainBannerKey),
          findsNothing);
    });

    testWidgets('no uncertain fields → no amber banner', (tester) async {
      await _pumpReview(tester, repo: repo, draft: _draft);
      expect(find.byKey(MedicationImportReviewScreen.uncertainBannerKey),
          findsNothing);
    });
  });
}
