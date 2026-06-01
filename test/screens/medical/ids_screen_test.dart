import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/providers/share_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medical/ids_screen.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 6, 1, 12);

IdentificationDoc _id({
  required String id,
  IdKind kind = IdKind.driverLicense,
  String idNumber = 'D1234567',
  DateTime? expiresOn,
  String? photoFrontPath,
  String? photoBackPath,
}) =>
    IdentificationDoc(
      id: id,
      patientId: 'demo-patient-mary',
      updatedAt: DateTime.utc(2026, 5, 1),
      kind: kind,
      idNumber: idNumber,
      expiresOn: expiresOn,
      photoFrontPath: photoFrontPath,
      photoBackPath: photoBackPath,
    );

// ---------------------------------------------------------------------------
// List host (view-provider override)
// ---------------------------------------------------------------------------

GoRouter _listRouter() {
  return GoRouter(
    initialLocation: '/medical/cards/ids',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /medical'))),
      ),
      GoRoute(
        path: '/medical/cards',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /medical/cards'))),
      ),
      GoRoute(
        path: '/medical/cards/ids',
        builder: (BuildContext c, GoRouterState s) => const IdsScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('DEST new'))),
          ),
          GoRoute(
            path: ':id',
            builder: (BuildContext c, GoRouterState s) => Scaffold(
              body: Center(child: Text('DEST ${s.pathParameters['id']}')),
            ),
          ),
        ],
      ),
    ],
  );
}

Future<GoRouter> _pumpList(
  WidgetTester tester, {
  required List<IdentificationDoc> docs,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = _listRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        idsViewProvider.overrideWith(
          (Ref ref) async => IdsView(patient: null, docs: docs),
        ),
        idsClockProvider.overrideWithValue(_fixedNow),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.last.matchedLocation;

Color? _expiresColor(WidgetTester tester, String docId) =>
    tester.widget<Text>(find.byKey(IdsScreen.expiresKey(docId))).style?.color;

// ---------------------------------------------------------------------------
// Detail host
// ---------------------------------------------------------------------------

Future<(GoRouter, RecordingSharer)> _pumpDetail(
  WidgetTester tester, {
  required IdentificationDoc doc,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final RecordingSharer sharer = RecordingSharer();
  final GoRouter router = GoRouter(
    initialLocation: '/medical/cards/ids/${doc.id}',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/cards/ids',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: ':id',
            builder: (BuildContext c, GoRouterState s) =>
                IdDetailScreen(docId: s.pathParameters['id'] ?? ''),
            routes: <RouteBase>[
              GoRoute(
                path: 'edit',
                builder: (BuildContext c, GoRouterState s) =>
                    const Scaffold(body: Center(child: Text('DEST edit'))),
              ),
            ],
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        idDetailProvider(doc.id).overrideWith((Ref ref) async => doc),
        sharerProvider.overrideWithValue(sharer),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router, sharer);
}

// ---------------------------------------------------------------------------
// Form host (real in-memory repo)
// ---------------------------------------------------------------------------

Future<void> _pumpForm(
  WidgetTester tester, {
  required DocumentsRepository repo,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/medical/cards/ids/new',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/cards/ids',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            builder: (BuildContext c, GoRouterState s) => const IdEditForm(),
          ),
        ],
      ),
    ],
  );

  int n = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        documentsRepositoryProvider.overrideWithValue(repo),
        storageProvider.overrideWithValue(InMemoryStorageProvider()),
        idFormIdFactoryProvider.overrideWithValue(() => 'id-id${n++}'),
        idFormClockProvider.overrideWithValue(() => DateTime(2026, 6, 1, 9)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IdsScreen — list', () {
    testWidgets('masks the id number as ****<last 4>',
        (WidgetTester tester) async {
      await _pumpList(tester, docs: <IdentificationDoc>[
        _id(id: 'a', idNumber: 'D1234567'),
      ]);

      expect(find.text('****4567'), findsOneWidget);
      // The full number never appears on the list.
      expect(find.text('D1234567'), findsNothing);
    });

    testWidgets('colors expiry coral within 60 days / past, neutral beyond',
        (WidgetTester tester) async {
      // now = 2026-06-01. Boundaries: +60d (Jul 31) soon, +61d (Aug 1)
      // neutral, today soon, past soon.
      await _pumpList(tester, docs: <IdentificationDoc>[
        _id(id: 'exact60', expiresOn: DateTime(2026, 7, 31)),
        _id(id: 'over60', expiresOn: DateTime(2026, 8, 1)),
        _id(id: 'today', expiresOn: DateTime(2026, 6, 1)),
        _id(id: 'past', expiresOn: DateTime(2026, 5, 1)),
        _id(id: 'none', expiresOn: null),
      ]);

      expect(_expiresColor(tester, 'exact60'), careblazersColors.cta);
      expect(_expiresColor(tester, 'over60'), careblazersColors.primarySoft);
      expect(_expiresColor(tester, 'today'), careblazersColors.cta);
      expect(_expiresColor(tester, 'past'), careblazersColors.cta);
      expect(_expiresColor(tester, 'none'), careblazersColors.primarySoft);
    });

    testWidgets('tapping a row opens the detail route',
        (WidgetTester tester) async {
      final GoRouter router = await _pumpList(tester, docs: <IdentificationDoc>[
        _id(id: 'lic-9'),
      ]);

      await tester.tap(find.byKey(IdsScreen.rowKey('lic-9')));
      await tester.pumpAndSettle();
      expect(_path(router), '/medical/cards/ids/lic-9');
    });

    testWidgets('FAB opens the new-ID form', (WidgetTester tester) async {
      final GoRouter router = await _pumpList(tester, docs: <IdentificationDoc>[
        _id(id: 'a'),
      ]);

      await tester.tap(find.byKey(IdsScreen.fabKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/medical/cards/ids/new');
    });

    testWidgets('empty state renders its CTA; no FAB',
        (WidgetTester tester) async {
      final GoRouter router =
          await _pumpList(tester, docs: const <IdentificationDoc>[]);

      expect(find.byKey(IdsScreen.emptyStateKey), findsOneWidget);
      expect(find.byKey(IdsScreen.fabKey), findsNothing);

      await tester.tap(find.byKey(IdsScreen.emptyCtaKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/medical/cards/ids/new');
    });
  });

  group('IdsScreen + IdDetail — real providers', () {
    testWidgets('idsView + idDetail resolve through the repo end to end',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final CareblazersDatabase db =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final DocumentsRepository repo = DocumentsRepository(db);
      await repo.upsertId(_id(id: 'r1', idNumber: 'D1234567'));
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      await storage.upsertPatient(maryHenderson());

      final GoRouter router = GoRouter(
        initialLocation: '/medical/cards/ids',
        routes: <RouteBase>[
          GoRoute(
            path: '/medical/cards/ids',
            builder: (BuildContext c, GoRouterState s) => const IdsScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: ':id',
                builder: (BuildContext c, GoRouterState s) =>
                    IdDetailScreen(docId: s.pathParameters['id'] ?? ''),
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            documentsRepositoryProvider.overrideWithValue(repo),
            storageProvider.overrideWithValue(storage),
            idsClockProvider.overrideWithValue(_fixedNow),
            sharerProvider.overrideWithValue(RecordingSharer()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // List (idsView) masks the number...
      expect(find.text('****4567'), findsOneWidget);
      await tester.tap(find.byKey(IdsScreen.rowKey('r1')));
      await tester.pumpAndSettle();
      // ...detail (idDetail) unmasks it.
      expect(
        tester.widget<Text>(find.byKey(IdDetailScreen.idNumberKey)).data,
        'D1234567',
      );
    });
  });

  group('IdDetailScreen', () {
    testWidgets('shows the UNMASKED id number, expires, and Share',
        (WidgetTester tester) async {
      final (_, RecordingSharer sharer) = await _pumpDetail(
        tester,
        doc: _id(id: 'd1', idNumber: 'D1234567', expiresOn: DateTime(2027, 4, 9)),
      );

      expect(
        tester.widget<Text>(find.byKey(IdDetailScreen.idNumberKey)).data,
        'D1234567',
      );
      expect(find.text('Expires Apr 9, 2027'), findsOneWidget);

      await tester.tap(find.byKey(IdDetailScreen.shareButtonKey));
      await tester.pumpAndSettle();
      expect(sharer.shared, hasLength(1));
      expect(sharer.shared.single.text, contains('D1234567'));
    });

    testWidgets('edit action pushes the edit route',
        (WidgetTester tester) async {
      final (GoRouter router, _) = await _pumpDetail(tester, doc: _id(id: 'd1'));

      await tester.tap(find.byKey(IdDetailScreen.editActionKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/medical/cards/ids/d1/edit');
      expect(find.text('DEST edit'), findsOneWidget);
    });
  });

  group('IdEditForm — validation + save', () {
    late CareblazersDatabase db;
    late DocumentsRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = DocumentsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets('blank id number blocks save', (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.tap(find.byKey(IdEditForm.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Enter the ID number.'), findsOneWidget);
      expect(await repo.listIds(), isEmpty);
    });

    testWidgets('picking then clearing the expiry date',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      expect(find.text('No expiry date'), findsOneWidget);
      await tester.tap(find.byKey(IdEditForm.expiryFieldKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Jun 15, 2026'), findsOneWidget);

      await tester.tap(find.byKey(IdEditForm.expiryClearKey));
      await tester.pump();
      expect(find.text('No expiry date'), findsOneWidget);
    });

    testWidgets('a valid entry upserts through the repo and pops',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.tap(find.byKey(IdEditForm.kindChipKey(IdKind.passport)));
      await tester.pump();
      await tester.enterText(
        find.byKey(IdEditForm.idNumberFieldKey),
        'X9988776',
      );
      await tester.tap(find.byKey(IdEditForm.saveButtonKey));
      await tester.pumpAndSettle();

      final List<IdentificationDoc> saved = await repo.listIds();
      expect(saved, hasLength(1));
      expect(saved.single.idNumber, 'X9988776');
      expect(saved.single.kind, IdKind.passport);
      expect(saved.single.patientId, 'demo-patient-mary');
      expect(find.text('list-stub'), findsOneWidget);
    });
  });
}
