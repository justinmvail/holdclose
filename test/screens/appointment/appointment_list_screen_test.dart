import 'dart:convert';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart' as model;
import 'package:holdclose/screens/appointment/appointment_list_screen.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/widgets/path_header.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '../_semantics_matchers.dart';

/// Fixed "now" the in-memory [AppointmentRepository] consults so the
/// upcoming/past split is deterministic across hosts.
DateTime _fixedNow() => DateTime.utc(2026, 6, 1, 12);

Future<void> _seedProvider(
  HoldcloseDatabase db, {
  String id = 'prov-1',
  String name = 'Dr. Ortega',
  model.ProviderRole role = model.ProviderRole.neurologist,
  String phone = '(415) 555-0188',
  String address = '250 Bon Air Rd, Greenbrae CA',
}) async {
  final model.Provider p = model.Provider(
    id: id,
    name: name,
    role: role,
    phone: phone,
    address: address,
  );
  await db.into(db.providersTable).insertOnConflictUpdate(
        ProvidersTableCompanion.insert(
          id: id,
          name: name,
          payload: jsonEncode(p.toJson()),
        ),
      );
}

model.Appointment _appt({
  required String id,
  required DateTime startsAt,
  String providerId = 'prov-1',
  model.AppointmentStatus status = model.AppointmentStatus.upcoming,
  List<String> agenda = const <String>[],
  String location = 'Marin General — Neurology',
}) =>
    model.Appointment(
      id: id,
      providerId: providerId,
      startsAt: startsAt,
      durationMinutes: 30,
      location: location,
      agenda: agenda,
      status: status,
    );

Future<({
  GoRouter router,
  AppointmentRepository repo,
  List<String> pushedPaths,
  HoldcloseDatabase db,
})> _pumpList(
  WidgetTester tester, {
  required AppointmentRepository repo,
  required HoldcloseDatabase db,
  Size surfaceSize = const Size(420, 1100),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> pushedPaths = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/appointments',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/appointments',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const AppointmentListScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) {
              pushedPaths.add('/appointments/new');
              return const Scaffold(body: Center(child: Text('form-stub')));
            },
          ),
          GoRoute(
            path: ':id',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) {
              pushedPaths
                  .add('/appointments/${state.pathParameters['id'] ?? ''}');
              return const Scaffold(body: Center(child: Text('detail-stub')));
            },
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: <Override>[
        appointmentRepositoryBackendProvider.overrideWithValue(repo),
        appointmentListClockProvider.overrideWithValue(_fixedNow),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return (router: router, repo: repo, pushedPaths: pushedPaths, db: db);
}

void main() {
  late HoldcloseDatabase db;
  late AppointmentRepository repo;

  setUp(() async {
    db = HoldcloseDatabase(NativeDatabase.memory());
    repo = AppointmentRepository(db, clock: _fixedNow);
    await _seedProvider(db);
    // The add-form debounce is a process-wide singleton; clear it so each
    // case starts with a fresh window (otherwise a prior test's open would
    // suppress this test's first tap).
    appointmentAddDebounce.reset();
  });

  tearDown(() async {
    await db.close();
  });

  group('AppointmentListScreen — empty state', () {
    testWidgets('renders the empty-state CTA when no appointments exist',
        (WidgetTester tester) async {
      await _pumpList(tester, repo: repo, db: db);

      expect(find.byKey(AppointmentListScreen.emptyStateKey), findsOneWidget);
      expect(find.byKey(AppointmentListScreen.emptyCtaKey), findsOneWidget);
      expect(find.byKey(AppointmentListScreen.fabKey), findsNothing);
      expect(find.byKey(AppointmentListScreen.listKey), findsNothing);
    });

    testWidgets('tapping the empty-state CTA pushes /appointments/new',
        (WidgetTester tester) async {
      final p = await _pumpList(tester, repo: repo, db: db);

      await tester.tap(find.byKey(AppointmentListScreen.emptyCtaKey));
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/appointments/new']);
    });

    testWidgets('PathHeader title is "Appointments"',
        (WidgetTester tester) async {
      await _pumpList(tester, repo: repo, db: db);
      // The AppBar back-arrow header was replaced by the PathHeader
      // pattern: the page title now lives in PathHeader.title, rendered
      // as navy Text inside the header. "Appointments" also appears as
      // the terminal breadcrumb crumb, so scope the assertion to the
      // header's `title` property to keep checking the real title.
      final PathHeader header =
          tester.widget<PathHeader>(find.byType(PathHeader));
      expect(header.title, 'Appointments');
      // The "Back to X" control was removed; the parent breadcrumb crumb
      // ('Care') is now the back affordance, rendered as a tappable
      // InkWell in the header's breadcrumb row. (IA rename 2026-06: the
      // former 'Medical' tab is now 'Care'; the route path stays /medical.)
      expect(find.widgetWithText(InkWell, 'Care'), findsOneWidget);
      // ...and the title renders as visible text (crumb + title =>
      // findsWidgets).
      expect(
        find.descendant(
          of: find.byType(PathHeader),
          matching: find.text('Appointments'),
        ),
        findsWidgets,
      );
    });
  });

  group('AppointmentListScreen — upcoming + past grouping', () {
    testWidgets(
        'renders Upcoming and Past sections with their respective cards',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-upcoming',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        agenda: const <String>['Ask about evening agitation'],
      ));
      await repo.upsertAppointment(_appt(
        id: 'appt-completed',
        startsAt: DateTime.utc(2026, 5, 20, 10),
        status: model.AppointmentStatus.completed,
      ));

      await _pumpList(tester, repo: repo, db: db);

      expect(find.byKey(AppointmentListScreen.upcomingSectionKey),
          findsOneWidget);
      expect(find.byKey(AppointmentListScreen.pastSectionKey), findsOneWidget);
      expect(find.byKey(AppointmentListScreen.cardKey('appt-upcoming')),
          findsOneWidget);
      expect(find.byKey(AppointmentListScreen.cardKey('appt-completed')),
          findsOneWidget);
      expect(find.byKey(AppointmentListScreen.fabKey), findsOneWidget);
    });

    testWidgets('Upcoming section is hidden when no upcoming appointments',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-canceled',
        startsAt: DateTime.utc(2026, 5, 15, 9),
        status: model.AppointmentStatus.canceled,
      ));

      await _pumpList(tester, repo: repo, db: db);

      expect(find.byKey(AppointmentListScreen.upcomingSectionKey),
          findsNothing);
      expect(find.byKey(AppointmentListScreen.pastSectionKey), findsOneWidget);
    });

    testWidgets('Past section is hidden when nothing past',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-future',
        startsAt: DateTime.utc(2026, 6, 15, 9),
      ));

      await _pumpList(tester, repo: repo, db: db);

      expect(find.byKey(AppointmentListScreen.upcomingSectionKey),
          findsOneWidget);
      expect(find.byKey(AppointmentListScreen.pastSectionKey), findsNothing);
    });

    testWidgets('each card shows date/time + provider + location',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        location: 'Marin General — Neurology',
      ));

      await _pumpList(tester, repo: repo, db: db);

      // Date format: "Jun 15, 2:30 PM"
      expect(find.text('Jun 15, 2:30 PM'), findsOneWidget);
      expect(find.text('Dr. Ortega'), findsOneWidget);
      expect(find.text('Marin General — Neurology'), findsOneWidget);
    });

    testWidgets('agenda count chip shows the item count', (
      WidgetTester tester,
    ) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-many',
        startsAt: DateTime.utc(2026, 6, 15, 9),
        agenda: const <String>[
          'Ask about evening agitation',
          'Refill Donepezil',
          'Review Memantine side effects',
        ],
      ));
      await repo.upsertAppointment(_appt(
        id: 'appt-none',
        startsAt: DateTime.utc(2026, 6, 16, 9),
      ));

      await _pumpList(tester, repo: repo, db: db);

      expect(
        find.descendant(
          of: find.byKey(AppointmentListScreen.agendaCountKey('appt-many')),
          matching: find.text('3 agenda items'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(AppointmentListScreen.agendaCountKey('appt-none')),
          matching: find.text('No agenda items yet'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping a card pushes /appointments/:id',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 9),
      ));

      final p = await _pumpList(tester, repo: repo, db: db);

      await tester.tap(find.byKey(AppointmentListScreen.cardKey('appt-1')));
      await tester.pumpAndSettle();

      expect(p.pushedPaths, contains('/appointments/appt-1'));
    });

    testWidgets('FAB pushes /appointments/new', (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 9),
      ));

      final p = await _pumpList(tester, repo: repo, db: db);

      await tester.tap(find.byKey(AppointmentListScreen.fabKey));
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/appointments/new']);
    });

    testWidgets(
        'double-tapping the FAB pushes the add form exactly ONCE '
        '(the duplicate-appointment vector)', (WidgetTester tester) async {
      // Regression (alpha bug "got added twice", 2026-06-07): a fast
      // double-tap on the add FAB used to push `/appointments/new` twice,
      // stacking two forms the caregiver then both saved → two identical
      // rows. The list now guards the push on `ModalRoute.isCurrent`, so
      // the second tap — fired before the first push settles — is a no-op.
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 9),
      ));

      final p = await _pumpList(tester, repo: repo, db: db);

      final Finder fab = find.byKey(AppointmentListScreen.fabKey);
      // First tap kicks off the push; the second fires before the route
      // transition settles. Only one form push must land.
      await tester.tap(fab);
      await tester.tap(fab, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/appointments/new'],
          reason: 'the second tap must be dropped while the form is opening');
    });

    testWidgets(
        'double-tapping the empty-state CTA pushes the add form exactly ONCE',
        (WidgetTester tester) async {
      // Same guard as the FAB, exercised through the empty-state CTA (the
      // other entry point into the add form).
      final p = await _pumpList(tester, repo: repo, db: db);

      final Finder cta = find.byKey(AppointmentListScreen.emptyCtaKey);
      await tester.tap(cta);
      await tester.tap(cta, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(p.pushedPaths, <String>['/appointments/new']);
    });
  });

  group('AppointmentListScreen — every status renders', () {
    testWidgets('upcoming + completed + canceled cards all render',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-up',
        startsAt: DateTime.utc(2026, 6, 15, 9),
      ));
      await repo.upsertAppointment(_appt(
        id: 'appt-done',
        startsAt: DateTime.utc(2026, 5, 20, 10),
        status: model.AppointmentStatus.completed,
      ));
      await repo.upsertAppointment(_appt(
        id: 'appt-x',
        startsAt: DateTime.utc(2026, 5, 25, 11),
        status: model.AppointmentStatus.canceled,
      ));

      await _pumpList(tester, repo: repo, db: db);

      for (final String id in <String>['appt-up', 'appt-done', 'appt-x']) {
        expect(find.byKey(AppointmentListScreen.cardKey(id)), findsOneWidget,
            reason: 'card for $id should render');
      }
      expect(find.text('Upcoming'), findsWidgets);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Canceled'), findsOneWidget);
    });
  });

  group('AppointmentListScreen — VoiceOver labels', () {
    testWidgets('the empty-state CTA carries a screen-reader label',
        (WidgetTester tester) async {
      await _pumpList(tester, repo: repo, db: db);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Add an appointment.*Open the add-appointment form'),
        ),
        isTrue,
      );
    });

    testWidgets('a populated card announces provider + time + status',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        agenda: const <String>['Ask about evening agitation'],
      ));

      await _pumpList(tester, repo: repo, db: db);

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Dr. Ortega.*Jun 15.*Upcoming.*agenda item'),
        ),
        isTrue,
      );
    });
  });

  group('AppointmentListScreen — Today/Tomorrow formatting', () {
    testWidgets('"Today" prefix when an appointment falls on the clock day',
        (WidgetTester tester) async {
      // clock is 2026-06-01 12:00 UTC; pick an appointment later that day.
      await repo.upsertAppointment(_appt(
        id: 'appt-today',
        startsAt: DateTime.utc(2026, 6, 1, 15, 30),
      ));

      await _pumpList(tester, repo: repo, db: db);

      expect(find.text('Today, 3:30 PM'), findsOneWidget);
    });

    testWidgets('"Tomorrow" prefix when an appointment falls the next day',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-tomorrow',
        startsAt: DateTime.utc(2026, 6, 2, 9),
      ));

      await _pumpList(tester, repo: repo, db: db);

      expect(find.text('Tomorrow, 9:00 AM'), findsOneWidget);
    });
  });

  group('AppointmentListScreen — route registration sanity', () {
    testWidgets('/appointments mounts the list screen',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final GoRouter router = GoRouter(
        initialLocation: '/appointments',
        routes: <RouteBase>[
          GoRoute(
            path: '/appointments',
            builder: (BuildContext context, GoRouterState state) =>
                const AppointmentListScreen(),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appointmentRepositoryBackendProvider.overrideWithValue(repo),
            appointmentListClockProvider.overrideWithValue(_fixedNow),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AppointmentListScreen), findsOneWidget);
    });
  });
}
