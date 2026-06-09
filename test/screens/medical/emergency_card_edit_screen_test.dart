import 'dart:async';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/screens/medical/emergency_card_edit_screen.dart';
import 'package:careblazers/screens/medical/emergency_card_screen.dart'
    show EmergencyCardView, emergencyCardViewProvider;
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The seed loved one's id — both the hydrated card and the persisted edit
/// hang off it, so the save read-back can look the card up by patient.
final String _patientId = maryHenderson().id;

EmergencyCardView _view({EmergencyCard? card, bool withPatient = true}) =>
    EmergencyCardView(
      patient: withPatient ? maryHenderson() : null,
      card: card,
      medications: const <Medication>[],
    );

EmergencyCard _existingCard() => EmergencyCard(
      id: 'ec-mary',
      patientId: _patientId,
      updatedAt: DateTime(2026, 6, 1),
      conditions: const <String>['Alzheimer\'s', 'Hypertension'],
      medications: const <String>['Donepezil 10 mg'],
      allergies: const <String>['Penicillin'],
      emergencyContacts: const <EmergencyContact>[
        EmergencyContact(
            name: 'Jane Doe', relation: 'Daughter', phone: '555-1234'),
      ],
      insurance: const Insurance(
          carrier: 'Medicare', policyNumber: 'P123', groupNumber: 'G9'),
      donorStatus: DonorStatus.donor,
    );

Future<void> _pumpEdit(
  WidgetTester tester, {
  required EmergencyCardView view,
  required DocumentsRepository repo,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/medical/cards/emergency/edit',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/cards/emergency',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('card-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'edit',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                const EmergencyCardEditScreen(),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        emergencyCardViewProvider.overrideWith((Ref ref) async => view),
        documentsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

/// Enter [text] into the contact sub-field whose [InputDecoration.labelText]
/// is [label] (the contact name/relation/phone fields carry no Key). When
/// more than one contact row is on screen the freshly-added row is the
/// last of each label, so the matcher targets `.last`.
Future<void> _enterContactField(
  WidgetTester tester, {
  required String label,
  required String text,
}) async {
  final Finder field = find
      .byWidgetPredicate((Widget w) =>
          w is TextField && w.decoration?.labelText == label)
      .last;
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareblazersDatabase db;
  late DocumentsRepository repo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = DocumentsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('EmergencyCardEditScreen — hydration', () {
    testWidgets('an existing card pre-fills every field',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: _existingCard()), repo: repo);

      // String lists arrive newline-joined in their multi-line fields.
      expect(find.text("Alzheimer's\nHypertension"), findsOneWidget);
      expect(find.text('Donepezil 10 mg'), findsOneWidget);
      expect(find.text('Penicillin'), findsOneWidget);
      // Contact + insurance fields.
      expect(find.text('Jane Doe'), findsOneWidget);
      expect(find.text('Daughter'), findsOneWidget);
      expect(find.text('555-1234'), findsOneWidget);
      expect(find.text('Medicare'), findsOneWidget);
      expect(find.text('P123'), findsOneWidget);
      expect(find.byKey(EmergencyCardEditScreen.saveButtonKey), findsOneWidget);
    });

    testWidgets('a new card (none on file) renders empty, no contact rows',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: null), repo: repo);

      // 3 list fields + 3 insurance fields, zero contact rows.
      expect(find.byType(TextField), findsNWidgets(6));
      expect(find.byKey(EmergencyCardEditScreen.saveButtonKey), findsOneWidget);
      // Donor defaults to Unknown — the segment exists.
      expect(find.text('Unknown'), findsOneWidget);
    });

    testWidgets('with no loved one on file, the form is gated',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(withPatient: false), repo: repo);

      expect(
          find.text('Add a loved one before filling out the emergency card.'),
          findsOneWidget);
      expect(find.byKey(EmergencyCardEditScreen.saveButtonKey), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('EmergencyCardEditScreen — contacts', () {
    testWidgets('Add contact appends an empty contact row',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: _existingCard()), repo: repo);

      // 3 list + 3 insurance + 3 (one contact) = 9.
      expect(find.byType(TextField), findsNWidgets(9));

      await tester.ensureVisible(
          find.byKey(EmergencyCardEditScreen.addContactKey));
      await tester.tap(find.byKey(EmergencyCardEditScreen.addContactKey));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNWidgets(12));
    });

    testWidgets('removing a contact drops its row',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: _existingCard()), repo: repo);

      expect(find.text('Jane Doe'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove contact'));
      await tester.pumpAndSettle();

      expect(find.text('Jane Doe'), findsNothing);
      // Back down to 3 list + 3 insurance fields.
      expect(find.byType(TextField), findsNWidgets(6));
    });
  });

  group('EmergencyCardEditScreen — save', () {
    testWidgets('editing conditions persists and pops to the card',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: _existingCard()), repo: repo);

      await tester.enterText(
          find.byKey(EmergencyCardEditScreen.conditionsFieldKey),
          'Diabetes only');
      await tester
          .ensureVisible(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.tap(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<EmergencyCard> saved =
          await repo.emergencyCardsByPatient(_patientId);
      expect(saved, hasLength(1));
      // Same id (upsert, not insert), new conditions, other fields kept.
      expect(saved.single.id, 'ec-mary');
      expect(saved.single.conditions, <String>['Diabetes only']);
      expect(saved.single.insurance.carrier, 'Medicare');
      // Popped back to the read-only card.
      expect(find.text('card-stub'), findsOneWidget);
    });

    testWidgets('changing donor status is saved',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: _existingCard()), repo: repo);

      await tester.tap(find.text('Not a donor'));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.tap(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final EmergencyCard saved =
          (await repo.emergencyCardsByPatient(_patientId)).single;
      expect(saved.donorStatus, DonorStatus.notDonor);
    });

    testWidgets('a brand-new card is minted with a deterministic id',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: null), repo: repo);

      await tester.enterText(
          find.byKey(EmergencyCardEditScreen.medicationsFieldKey),
          'Aspirin 81 mg');
      await tester
          .ensureVisible(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.tap(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final EmergencyCard saved =
          (await repo.emergencyCardsByPatient(_patientId)).single;
      expect(saved.id, 'emergency-card-$_patientId');
      expect(saved.medications, <String>['Aspirin 81 mg']);
      expect(saved.patientId, _patientId);
    });

    testWidgets('adding a contact via the form persists it on the card',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: _existingCard()), repo: repo);

      // Append a fresh (empty) contact row, then fill its name/relation/
      // phone fields. The contact sub-fields carry no Key, so each is
      // reached by its InputDecoration label scoped to the just-added
      // row (the last of each on screen — the seed's Jane Doe holds the
      // first set).
      await tester.ensureVisible(
          find.byKey(EmergencyCardEditScreen.addContactKey));
      await tester.tap(find.byKey(EmergencyCardEditScreen.addContactKey));
      await tester.pumpAndSettle();

      await _enterContactField(tester, label: 'Name', text: 'John Smith');
      await _enterContactField(tester, label: 'Relation', text: 'Son');
      await _enterContactField(tester, label: 'Phone', text: '555-9876');

      await tester
          .ensureVisible(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.tap(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Re-read the persisted card: the original contact is kept and the
      // new one landed alongside it.
      final EmergencyCard saved =
          (await repo.emergencyCardsByPatient(_patientId)).single;
      expect(saved.id, 'ec-mary');
      expect(saved.emergencyContacts, hasLength(2));
      expect(
        saved.emergencyContacts.map((EmergencyContact c) => c.name),
        containsAll(<String>['Jane Doe', 'John Smith']),
      );
      final EmergencyContact added = saved.emergencyContacts
          .firstWhere((EmergencyContact c) => c.name == 'John Smith');
      expect(added.relation, 'Son');
      expect(added.phone, '555-9876');
      // Popped back to the read-only card.
      expect(find.text('card-stub'), findsOneWidget);
    });

    testWidgets('removing the only contact persists an empty contact list',
        (WidgetTester tester) async {
      await _pumpEdit(tester, view: _view(card: _existingCard()), repo: repo);

      // Drop the seed's single contact, then save.
      expect(find.text('Jane Doe'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove contact'));
      await tester.pumpAndSettle();
      expect(find.text('Jane Doe'), findsNothing);

      await tester
          .ensureVisible(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.tap(find.byKey(EmergencyCardEditScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // The persisted card carries no contacts; the rest of the card is
      // untouched (same id, conditions kept).
      final EmergencyCard saved =
          (await repo.emergencyCardsByPatient(_patientId)).single;
      expect(saved.id, 'ec-mary');
      expect(saved.emergencyContacts, isEmpty);
      expect(saved.conditions, <String>['Alzheimer\'s', 'Hypertension']);
    });
  });

  group('EmergencyCardEditScreen — PathHeader back affordance', () {
    // Regression for alpha bug fb_1780932762335231: the breadcrumb back
    // affordance must be present on EVERY branch — including before the
    // view resolves (and on the error state), which previously rendered a
    // bare message with no header, leaving the screen swipe-only.
    testWidgets('renders the PathHeader breadcrumb before the view resolves',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final GoRouter router = GoRouter(
        initialLocation: '/medical/cards/emergency/edit',
        routes: <RouteBase>[
          GoRoute(
            path: '/medical/cards/emergency/edit',
            builder: (BuildContext context, GoRouterState state) =>
                const EmergencyCardEditScreen(),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            // A future that never completes keeps the screen on the
            // loading branch for the single pump below.
            emergencyCardViewProvider.overrideWith(
              (Ref ref) => Completer<EmergencyCardView>().future,
            ),
            documentsRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      // Even before/while the view resolves (and on the error branch), the
      // breadcrumb back affordance is on screen — never a swipe-only
      // dead-end. The PathHeader is structurally outside the `.when()`.
      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
      expect(find.text('Emergency Card'), findsOneWidget);
    });
  });
}
