import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/providers/share_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medical/poa_screen.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/widgets/document_scan_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

PowerOfAttorneyDoc _doc({
  String? alternateName = 'Tom Henderson',
  PoaScope scope = PoaScope.medical,
  String? scanPath,
}) =>
    PowerOfAttorneyDoc(
      id: 'poa-1',
      patientId: maryHenderson().id,
      updatedAt: DateTime.utc(2026, 5, 20),
      agentName: 'Jane Doe',
      scope: scope,
      effectiveDate: DateTime.utc(2024, 3, 14),
      alternateName: alternateName,
      scanPath: scanPath,
    );

// ---------------------------------------------------------------------------
// Screen host (view-provider override)
// ---------------------------------------------------------------------------

GoRouter _screenRouter() {
  return GoRouter(
    initialLocation: '/medical/cards/poa',
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
        path: '/medical/cards/poa',
        builder: (BuildContext c, GoRouterState s) => const PoaScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'edit',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('DEST edit'))),
          ),
        ],
      ),
    ],
  );
}

Future<(GoRouter, RecordingSharer)> _pumpScreen(
  WidgetTester tester, {
  required PoaView view,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final RecordingSharer sharer = RecordingSharer();
  final GoRouter router = _screenRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        poaViewProvider.overrideWith((Ref ref) async => view),
        sharerProvider.overrideWithValue(sharer),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router, sharer);
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.last.matchedLocation;

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
    initialLocation: '/medical/cards/poa/edit',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/cards/poa',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('list-stub'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'edit',
            builder: (BuildContext c, GoRouterState s) => const PoaEditForm(),
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
        poaFormIdFactoryProvider.overrideWithValue(() => 'poa-id${n++}'),
        poaFormClockProvider.overrideWithValue(() => DateTime(2026, 6, 1, 9)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PoaScreen — populated', () {
    testWidgets('renders agent, alternate, scope chip, and effective date',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        view: PoaView(patient: maryHenderson(), doc: _doc()),
      );

      expect(find.byKey(PoaScreen.documentCardKey), findsOneWidget);
      expect(find.text('Jane Doe'), findsOneWidget);
      expect(find.text('Tom Henderson'), findsOneWidget);
      expect(find.text('Mar 14, 2024'), findsOneWidget);
      // Scope chip reads "Medical" (disambiguated from the breadcrumb).
      expect(
        find.descendant(
          of: find.byKey(PoaScreen.scopeChipKey),
          matching: find.text('Medical'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the Cards & Documents trail + Back control',
        (WidgetTester tester) async {
      final (GoRouter router, _) = await _pumpScreen(
        tester,
        view: PoaView(patient: maryHenderson(), doc: _doc()),
      );

      expect(find.text('Back to Cards & Documents'), findsOneWidget);
      await tester.tap(find.text('Back to Cards & Documents'));
      await tester.pumpAndSettle();
      expect(_path(router), '/medical/cards');
    });

    testWidgets('edit action pushes the edit route',
        (WidgetTester tester) async {
      final (GoRouter router, _) = await _pumpScreen(
        tester,
        view: PoaView(patient: maryHenderson(), doc: _doc()),
      );

      await tester.tap(find.byKey(PoaScreen.editActionKey));
      await tester.pumpAndSettle();

      expect(_path(router), '/medical/cards/poa/edit');
      expect(find.text('DEST edit'), findsOneWidget);
    });

    testWidgets('Share hands a POA summary to the sharer',
        (WidgetTester tester) async {
      final (_, RecordingSharer sharer) = await _pumpScreen(
        tester,
        view: PoaView(patient: maryHenderson(), doc: _doc()),
      );

      await tester.tap(find.byKey(PoaScreen.shareButtonKey));
      await tester.pumpAndSettle();

      expect(sharer.shared, hasLength(1));
      expect(sharer.shared.single.text, contains('Jane Doe'));
      expect(sharer.shared.single.subject, contains('Power of Attorney'));
    });

    testWidgets('tapping the scan thumbnail opens the full-screen viewer',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        view: PoaView(
          patient: maryHenderson(),
          doc: _doc(scanPath: '/tmp/careblazers-poa-scan.png'),
        ),
      );

      expect(find.byKey(documentScanViewerKey), findsNothing);
      await tester.tap(find.byType(DocumentScanThumbnail));
      await tester.pumpAndSettle();
      expect(find.byKey(documentScanViewerKey), findsOneWidget);

      await tester.tap(find.byKey(const Key('document-scan-viewer-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(documentScanViewerKey), findsNothing);
    });
  });

  group('PoaScreen — real providers', () {
    testWidgets('poaView resolves the loved one\'s doc end to end',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final CareblazersDatabase db =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final DocumentsRepository repo = DocumentsRepository(db);
      await repo.upsertPoa(_doc());
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      await storage.upsertPatient(maryHenderson());

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            documentsRepositoryProvider.overrideWithValue(repo),
            storageProvider.overrideWithValue(storage),
          ],
          child: MaterialApp.router(routerConfig: _screenRouter()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(PoaScreen.documentCardKey), findsOneWidget);
      expect(find.text('Jane Doe'), findsOneWidget);
    });
  });

  group('PoaScreen — empty', () {
    testWidgets('shows the empty placeholder + CTA when no doc on file',
        (WidgetTester tester) async {
      final (GoRouter router, _) = await _pumpScreen(
        tester,
        view: PoaView(patient: maryHenderson(), doc: null),
      );

      expect(find.byKey(PoaScreen.emptyPlaceholderKey), findsOneWidget);
      expect(find.byKey(PoaScreen.documentCardKey), findsNothing);

      await tester.tap(find.byKey(PoaScreen.emptyCtaKey));
      await tester.pumpAndSettle();
      expect(_path(router), '/medical/cards/poa/edit');
    });
  });

  group('PoaEditForm — validation + save', () {
    late CareblazersDatabase db;
    late DocumentsRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = DocumentsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets('blank agent name blocks save', (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.tap(find.byKey(PoaEditForm.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.text("Enter the agent's name."), findsOneWidget);
      expect(await repo.listPoa(), isEmpty);
    });

    testWidgets('a valid entry upserts through the repo and pops',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      await tester.enterText(
        find.byKey(PoaEditForm.agentFieldKey),
        'Maria Lopez',
      );
      await tester.tap(find.byKey(PoaEditForm.scopeChipKey(PoaScope.financial)));
      await tester.pump();
      await tester.tap(find.byKey(PoaEditForm.saveButtonKey));
      await tester.pumpAndSettle();

      final List<PowerOfAttorneyDoc> saved = await repo.listPoa();
      expect(saved, hasLength(1));
      expect(saved.single.agentName, 'Maria Lopez');
      expect(saved.single.scope, PoaScope.financial);
      expect(saved.single.patientId, 'demo-patient-mary');
      // Popped back to the list stub.
      expect(find.text('list-stub'), findsOneWidget);
    });

    testWidgets('picking an effective date updates the field',
        (WidgetTester tester) async {
      await _pumpForm(tester, repo: repo);

      // Default effective date comes from the pinned clock (Jun 1, 2026).
      expect(find.text('Jun 1, 2026'), findsOneWidget);
      await tester.tap(find.byKey(PoaEditForm.dateFieldKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Jun 15, 2026'), findsOneWidget);
    });

    testWidgets('edit path hydrates the existing doc and offers Delete',
        (WidgetTester tester) async {
      await repo.upsertPoa(
        PowerOfAttorneyDoc(
          id: 'poa-existing',
          patientId: 'demo-patient-mary',
          updatedAt: DateTime.utc(2026, 1, 1),
          agentName: 'Existing Agent',
          scope: PoaScope.general,
          effectiveDate: DateTime.utc(2023, 1, 1),
        ),
      );
      await _pumpForm(tester, repo: repo);

      // The single on-file doc hydrates the form (edit path).
      expect(find.byKey(PoaEditForm.deleteButtonKey), findsOneWidget);
      expect(find.text('Existing Agent'), findsOneWidget);

      await tester.tap(find.byKey(PoaEditForm.deleteButtonKey));
      await tester.pumpAndSettle();
      expect(await repo.listPoa(), isEmpty);
    });
  });
}
