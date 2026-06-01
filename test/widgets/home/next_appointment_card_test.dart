import 'dart:async';
import 'dart:convert';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/screens/appointment/appointment_list_screen.dart'
    show appointmentListClockProvider;
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/next_appointment_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
// `Provider` (the model) collides with riverpod's `Provider`; `hide` keeps
// the model name resolvable in the test fixtures.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Fixed "now": 9 AM on Mon Jun 1 2026. Appointments later today read as
/// "Today" (coral dot); appointments on Jun 2+ read as future (navy dot).
DateTime _fixedNow() => DateTime(2026, 6, 1, 9, 0);

Provider _provider(
  String id,
  String name,
  ProviderRole role,
) =>
    Provider(
      id: id,
      name: name,
      role: role,
      phone: '(415) 555-0100',
      address: '1 Main St',
    );

Appointment _appt({
  required String id,
  required String providerId,
  required DateTime startsAt,
  AppointmentStatus status = AppointmentStatus.upcoming,
  String? driverName,
}) =>
    Appointment(
      id: id,
      providerId: providerId,
      startsAt: startsAt,
      durationMinutes: 30,
      location: 'Marin General',
      agenda: const <String>[],
      status: status,
      driverName: driverName,
    );

/// Writes [p] straight into the providers table — provider writes have no
/// dedicated method on [AppointmentRepository] (the form owns them via the
/// companion ProviderRepository), so the test seeds the row the same way
/// the list-screen test does.
Future<void> _seedProvider(CareblazersDatabase db, Provider p) async {
  await db.into(db.providersTable).insertOnConflictUpdate(
        ProvidersTableCompanion.insert(
          id: p.id,
          name: p.name,
          payload: jsonEncode(p.toJson()),
        ),
      );
}

List<Override> _overrides(AppointmentRepository repo) => <Override>[
      appointmentRepositoryBackendProvider.overrideWithValue(repo),
      appointmentListClockProvider.overrideWithValue(_fixedNow),
    ];

/// Pumps the card inside a two-route harness so the whole-card tap can
/// resolve `push('/appointments/:id')` end to end.
Future<void> _pumpCard(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) => const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: NextAppointmentCard(),
          ),
        ),
      ),
      GoRoute(
        path: '/appointments/:id',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            Scaffold(body: Text('APPT DEST ${state.pathParameters['id']}')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        routerConfig: router,
        theme: careblazersLightTheme,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ---- pure predicate ----------------------------------------------------

  group('pickNextAppointment — predicate (Phase 14.10)', () {
    final DateTime now = _fixedNow();

    test('picks the soonest appointment strictly after now', () {
      final List<Appointment> all = <Appointment>[
        _appt(id: 'far', providerId: 'p', startsAt: DateTime(2026, 6, 10, 9)),
        _appt(id: 'soon', providerId: 'p', startsAt: DateTime(2026, 6, 2, 9)),
        _appt(id: 'mid', providerId: 'p', startsAt: DateTime(2026, 6, 5, 9)),
      ];
      expect(pickNextAppointment(all, now)?.id, 'soon');
    });

    test('skips canceled appointments even when soonest', () {
      final List<Appointment> all = <Appointment>[
        _appt(
          id: 'canceled',
          providerId: 'p',
          startsAt: DateTime(2026, 6, 1, 14),
          status: AppointmentStatus.canceled,
        ),
        _appt(id: 'next', providerId: 'p', startsAt: DateTime(2026, 6, 3, 9)),
      ];
      expect(pickNextAppointment(all, now)?.id, 'next');
    });

    test('excludes appointments at or before now', () {
      final List<Appointment> all = <Appointment>[
        // Exactly now — not strictly after, excluded.
        _appt(id: 'atNow', providerId: 'p', startsAt: now),
        _appt(
          id: 'past',
          providerId: 'p',
          startsAt: DateTime(2026, 5, 30, 9),
        ),
      ];
      expect(pickNextAppointment(all, now), isNull);
    });

    test('a completed-but-future appointment still qualifies', () {
      // The predicate is status != canceled, so a future completed row
      // counts (broader than the list screen "Upcoming" section).
      final List<Appointment> all = <Appointment>[
        _appt(
          id: 'done',
          providerId: 'p',
          startsAt: DateTime(2026, 6, 4, 9),
          status: AppointmentStatus.completed,
        ),
      ];
      expect(pickNextAppointment(all, now)?.id, 'done');
    });

    test('empty list returns null', () {
      expect(pickNextAppointment(const <Appointment>[], now), isNull);
    });
  });

  group('specialtyLabel — role wording', () {
    test('maps each role to its label, blank for other/null', () {
      expect(specialtyLabel(_provider('a', 'Dr. A', ProviderRole.doctor)),
          'Doctor');
      expect(
          specialtyLabel(_provider('b', 'Dr. B', ProviderRole.neurologist)),
          'Neurologist');
      expect(
          specialtyLabel(_provider('c', 'C', ProviderRole.socialWorker)),
          'Social worker');
      expect(specialtyLabel(_provider('d', 'D', ProviderRole.other)), '');
      expect(specialtyLabel(null), '');
    });
  });

  group('formatAppointmentWhen — Today / Tomorrow / fallback', () {
    final DateTime now = _fixedNow();
    test('today, tomorrow, and a later date', () {
      expect(formatAppointmentWhen(DateTime(2026, 6, 1, 14, 30), now),
          'Today, 2:30 PM');
      expect(formatAppointmentWhen(DateTime(2026, 6, 2, 9, 0), now),
          'Tomorrow, 9:00 AM');
      expect(formatAppointmentWhen(DateTime(2026, 6, 15, 14, 30), now),
          'Jun 15, 2:30 PM');
    });
  });

  // ---- widget behaviour ---------------------------------------------------

  group('NextAppointmentCard', () {
    late CareblazersDatabase db;
    late AppointmentRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = AppointmentRepository(db, clock: _fixedNow);
    });
    tearDown(() => db.close());

    testWidgets('empty — renders "No upcoming appointments."',
        (WidgetTester tester) async {
      await _pumpCard(tester, overrides: _overrides(repo));

      expect(find.byKey(NextAppointmentCard.emptyKey), findsOneWidget);
      expect(find.text('No upcoming appointments.'), findsOneWidget);
      expect(find.byKey(NextAppointmentCard.rowKey), findsNothing);
      expect(find.text('Next Appointment'), findsOneWidget);
    });

    testWidgets('empty — the card is not tappable',
        (WidgetTester tester) async {
      await _pumpCard(tester, overrides: _overrides(repo));
      final InkWell ink = tester.widget<InkWell>(
        find.byKey(NextAppointmentCard.cardKey),
      );
      expect(ink.onTap, isNull);
    });

    testWidgets('populated — renders specialty, time and driver',
        (WidgetTester tester) async {
      await _seedProvider(
        db,
        _provider('prov-1', 'Dr. Ortega', ProviderRole.neurologist),
      );
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 4, 14, 30),
        driverName: 'Maria',
      ));

      await _pumpCard(tester, overrides: _overrides(repo));

      expect(find.byKey(NextAppointmentCard.rowKey), findsOneWidget);
      expect(find.text('Jun 4, 2:30 PM'), findsOneWidget);
      expect(find.byKey(NextAppointmentCard.driverKey), findsOneWidget);
      expect(find.text('Driver: Maria'), findsOneWidget);
      expect(find.byKey(NextAppointmentCard.emptyKey), findsNothing);
    });

    testWidgets('populated — a visit today paints the coral dot',
        (WidgetTester tester) async {
      await _seedProvider(
        db,
        _provider('prov-1', 'Dr. Ortega', ProviderRole.doctor),
      );
      await repo.upsertAppointment(_appt(
        id: 'appt-today',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 1, 15, 0),
      ));

      await _pumpCard(tester, overrides: _overrides(repo));

      expect(find.text('Today, 3:00 PM'), findsOneWidget);
      final Container dot =
          tester.widget<Container>(find.byKey(NextAppointmentCard.dotKey));
      final BoxDecoration decoration = dot.decoration! as BoxDecoration;
      expect(decoration.color, NextAppointmentCard.todayColor);
    });

    testWidgets('populated — a future visit paints the navy dot',
        (WidgetTester tester) async {
      await _seedProvider(
        db,
        _provider('prov-1', 'Dr. Ortega', ProviderRole.doctor),
      );
      await repo.upsertAppointment(_appt(
        id: 'appt-future',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 8, 10, 0),
      ));

      await _pumpCard(tester, overrides: _overrides(repo));

      final Container dot =
          tester.widget<Container>(find.byKey(NextAppointmentCard.dotKey));
      final BoxDecoration decoration = dot.decoration! as BoxDecoration;
      expect(decoration.color, careblazersColors.primary);
    });

    testWidgets('populated — omits the driver line when none is assigned',
        (WidgetTester tester) async {
      await _seedProvider(
        db,
        _provider('prov-1', 'Dr. Ortega', ProviderRole.doctor),
      );
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 4, 9, 0),
      ));

      await _pumpCard(tester, overrides: _overrides(repo));

      expect(find.byKey(NextAppointmentCard.rowKey), findsOneWidget);
      expect(find.byKey(NextAppointmentCard.driverKey), findsNothing);
    });

    testWidgets('populated — picks the soonest of several upcoming visits',
        (WidgetTester tester) async {
      await _seedProvider(
        db,
        _provider('prov-1', 'Dr. Ortega', ProviderRole.doctor),
      );
      await repo.upsertAppointment(_appt(
        id: 'later',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 20, 9, 0),
      ));
      await repo.upsertAppointment(_appt(
        id: 'soonest',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 2, 11, 0),
      ));

      await _pumpCard(tester, overrides: _overrides(repo));

      expect(find.text('Tomorrow, 11:00 AM'), findsOneWidget);
      // Tapping opens the soonest one.
      await tester.tap(find.byKey(NextAppointmentCard.cardKey));
      await tester.pumpAndSettle();
      expect(find.text('APPT DEST soonest'), findsOneWidget);
    });

    testWidgets('navigation — tapping the card pushes /appointments/:id',
        (WidgetTester tester) async {
      await _seedProvider(
        db,
        _provider('prov-1', 'Dr. Ortega', ProviderRole.doctor),
      );
      await repo.upsertAppointment(_appt(
        id: 'appt-42',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 4, 9, 0),
      ));

      await _pumpCard(tester, overrides: _overrides(repo));

      expect(find.text('APPT DEST appt-42'), findsNothing);
      await tester.tap(find.byKey(NextAppointmentCard.cardKey));
      await tester.pumpAndSettle();
      expect(find.text('APPT DEST appt-42'), findsOneWidget);
    });
  });

  group('NextAppointmentCard — loading skeleton', () {
    testWidgets('shows the skeleton while the future is unresolved',
        (WidgetTester tester) async {
      final Completer<NextAppointmentItem?> pending =
          Completer<NextAppointmentItem?>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(null);
      });

      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            nextAppointmentProvider.overrideWith((ref) => pending.future),
            appointmentListClockProvider.overrideWithValue(_fixedNow),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: NextAppointmentCard(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(NextAppointmentCard.skeletonKey), findsOneWidget);
      expect(find.byKey(NextAppointmentCard.emptyKey), findsNothing);
      expect(find.byKey(NextAppointmentCard.rowKey), findsNothing);
    });
  });
}
