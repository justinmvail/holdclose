import 'dart:convert';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart' as model;
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/screens/appointment/appointment_detail_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime.utc(2026, 6, 1, 12);

Future<void> _seedProvider(
  CareblazersDatabase db, {
  String id = 'prov-1',
  String name = 'Dr. Ortega',
  String phone = '(415) 555-0188',
  String address = '250 Bon Air Rd, Greenbrae CA',
}) async {
  final model.Provider p = model.Provider(
    id: id,
    name: name,
    role: model.ProviderRole.neurologist,
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
  Set<int> completedAgendaIndices = const <int>{},
  String location = 'Marin General — Neurology',
  String? notes,
}) =>
    model.Appointment(
      id: id,
      providerId: providerId,
      startsAt: startsAt,
      durationMinutes: 30,
      location: location,
      agenda: agenda,
      completedAgendaIndices: completedAgendaIndices,
      status: status,
      notes: notes,
    );

Future<({
  GoRouter router,
  AppointmentRepository repo,
  CareblazersDatabase db,
  RecordingLinkLauncher launcher,
})> _pumpDetail(
  WidgetTester tester, {
  required AppointmentRepository repo,
  required CareblazersDatabase db,
  required String appointmentId,
  Size surfaceSize = const Size(420, 1400),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final RecordingLinkLauncher launcher = RecordingLinkLauncher();
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    // Land on the list, then push the detail so the detail's
    // `context.canPop()` is true and a delete pops cleanly back to a
    // real list stub the test can assert on.
    initialLocation: '/appointments/$appointmentId',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/appointments',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Text('appointment-list-stub')),
        routes: <RouteBase>[
          GoRoute(
            path: ':id',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                AppointmentDetailScreen(
              appointmentId: state.pathParameters['id'] ?? '',
            ),
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
        linkLauncherProvider.overrideWithValue(launcher),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return (router: router, repo: repo, db: db, launcher: launcher);
}

void main() {
  late CareblazersDatabase db;
  late AppointmentRepository repo;

  setUp(() async {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = AppointmentRepository(db, clock: _fixedNow);
    await _seedProvider(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('AppointmentDetailScreen — missing appointment', () {
    testWidgets('shows the not-found fallback for an unknown id',
        (WidgetTester tester) async {
      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'nope');

      expect(find.byKey(AppointmentDetailScreen.notFoundKey), findsOneWidget);
      expect(find.text('This appointment is no longer on file.'),
          findsOneWidget);
    });
  });

  group('AppointmentDetailScreen — upcoming appointment', () {
    testWidgets('renders date + provider + status chip + agenda checklist',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        agenda: const <String>[
          'Ask about evening agitation',
          'Refill Donepezil',
        ],
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      expect(find.text('Monday, June 15'), findsOneWidget);
      expect(find.text('2:30 PM'), findsOneWidget);
      expect(find.text('Dr. Ortega'), findsOneWidget);
      expect(find.text('Upcoming'), findsOneWidget);
      expect(find.text('Ask about evening agitation'), findsOneWidget);
      expect(find.text('Refill Donepezil'), findsOneWidget);
      expect(find.byKey(AppointmentDetailScreen.agendaListKey), findsOneWidget);
      expect(find.byKey(AppointmentDetailScreen.agendaItemKey(0)),
          findsOneWidget);
      expect(find.byKey(AppointmentDetailScreen.agendaItemKey(1)),
          findsOneWidget);
    });

    testWidgets(
        'checking an agenda item toggles its persisted completed-indices',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        agenda: const <String>['Ask about evening agitation', 'Refill'],
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      // First, unchecked.
      expect(find.byIcon(Icons.check_box_outline_blank), findsNWidgets(2));
      expect(find.byIcon(Icons.check_box), findsNothing);

      await tester.tap(find.byKey(AppointmentDetailScreen.agendaItemKey(0)));
      await tester.pumpAndSettle();

      // Persisted to the repo.
      final model.Appointment? loaded = await repo.getAppointment('appt-1');
      expect(loaded?.completedAgendaIndices, <int>{0});

      // UI reflects the new state.
      expect(find.byIcon(Icons.check_box), findsOneWidget);

      // Uncheck round-trips back to empty.
      await tester.tap(find.byKey(AppointmentDetailScreen.agendaItemKey(0)));
      await tester.pumpAndSettle();
      final model.Appointment? cleared = await repo.getAppointment('appt-1');
      expect(cleared?.completedAgendaIndices, isEmpty);
    });

    testWidgets('Call provider button launches tel: URL', (
      WidgetTester tester,
    ) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
      ));

      final p =
          await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      await tester.tap(find.byKey(AppointmentDetailScreen.callButtonKey));
      await tester.pumpAndSettle();

      expect(p.launcher.launched, hasLength(1));
      expect(p.launcher.launched.single.scheme, 'tel');
      // The provider's "(415) 555-0188" should collapse to digits.
      expect(p.launcher.launched.single.path, '4155550188');
    });

    testWidgets('Get directions button launches maps URL with the address',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
      ));

      final p =
          await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      await tester.tap(find.byKey(AppointmentDetailScreen.directionsButtonKey));
      await tester.pumpAndSettle();

      expect(p.launcher.launched, hasLength(1));
      final Uri launched = p.launcher.launched.single;
      expect(launched.host, contains('maps'));
      expect(launched.queryParameters['q'], '250 Bon Air Rd, Greenbrae CA');
    });

    testWidgets('Saving notes persists the text + emits a confirmation snack',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      await tester.enterText(
        find.byKey(AppointmentDetailScreen.notesFieldKey),
        'Trazodone trial — pharmacy will call.',
      );
      await tester.tap(find.byKey(AppointmentDetailScreen.saveNotesButtonKey));
      await tester.pump(); // build the snack
      await tester.pump(const Duration(milliseconds: 100));

      final model.Appointment? loaded = await repo.getAppointment('appt-1');
      expect(loaded?.notes, 'Trazodone trial — pharmacy will call.');

      expect(find.text('Notes saved.'), findsOneWidget);
    });

    testWidgets('Saving empty notes nulls the field rather than storing ""',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        notes: 'old note',
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      // Clear the field and save.
      await tester.enterText(
        find.byKey(AppointmentDetailScreen.notesFieldKey),
        '',
      );
      await tester.tap(find.byKey(AppointmentDetailScreen.saveNotesButtonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final model.Appointment? loaded = await repo.getAppointment('appt-1');
      expect(loaded?.notes, isNull);
    });
  });

  group('AppointmentDetailScreen — completed appointment', () {
    testWidgets('renders the completed status chip + hydrates existing notes',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-done',
        startsAt: DateTime.utc(2026, 5, 20, 10),
        status: model.AppointmentStatus.completed,
        agenda: const <String>['Discuss sundowning'],
        completedAgendaIndices: const <int>{0},
        notes: 'Dr. suggested trazodone trial.',
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-done');

      expect(find.text('Completed'), findsOneWidget);
      // Previously-checked agenda item shows the checked icon.
      expect(find.byIcon(Icons.check_box), findsOneWidget);
      // Existing notes show in the field.
      final TextField field =
          tester.widget(find.byKey(AppointmentDetailScreen.notesFieldKey));
      expect(field.controller?.text, 'Dr. suggested trazodone trial.');
    });
  });

  group('AppointmentDetailScreen — canceled appointment', () {
    testWidgets('renders the canceled chip + empty-agenda fallback',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-x',
        startsAt: DateTime.utc(2026, 5, 25, 11),
        status: model.AppointmentStatus.canceled,
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-x');

      expect(find.text('Canceled'), findsOneWidget);
      expect(find.byKey(AppointmentDetailScreen.emptyAgendaKey),
          findsOneWidget);
      expect(find.byKey(AppointmentDetailScreen.agendaListKey), findsNothing);
    });
  });

  group('AppointmentDetailScreen — hard delete', () {
    testWidgets('delete button shows on the detail screen',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      expect(find.byKey(AppointmentDetailScreen.deleteButtonKey),
          findsOneWidget);
    });

    testWidgets(
        'confirming the delete dialog removes the appointment from the repo '
        'and pops back to the list', (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      // Precondition: the appointment is on file.
      expect(await repo.listAppointments(), hasLength(1));

      await tester.tap(find.byKey(AppointmentDetailScreen.deleteButtonKey));
      await tester.pumpAndSettle();

      // Confirm dialog is up; confirm it.
      expect(find.text('Delete appointment?'), findsOneWidget);
      await tester
          .tap(find.byKey(AppointmentDetailScreen.confirmDeleteButtonKey));
      await tester.pumpAndSettle();

      // Gone from the repository entirely (hard delete, not a soft-cancel).
      expect(await repo.listAppointments(), isEmpty);
      expect(await repo.getAppointment('appt-1'), isNull);

      // Popped back to the list stub.
      expect(find.text('appointment-list-stub'), findsOneWidget);
    });

    testWidgets('cancelling the delete dialog keeps the appointment',
        (WidgetTester tester) async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
      ));

      await _pumpDetail(tester, repo: repo, db: db, appointmentId: 'appt-1');

      await tester.tap(find.byKey(AppointmentDetailScreen.deleteButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      // Still on file, still on the detail screen.
      expect(await repo.listAppointments(), hasLength(1));
      expect(find.byKey(AppointmentDetailScreen.scaffoldKey), findsOneWidget);
    });
  });

  group('AppointmentDetailScreen — degraded provider data', () {
    testWidgets(
        'call + directions buttons are disabled when the provider has no '
        'phone/address', (WidgetTester tester) async {
      // Seed a barebones second provider with empty phone + address —
      // the FK is satisfied but the call/directions buttons should
      // refuse to launch a tel: or maps: link against empty input.
      await _seedProvider(
        db,
        id: 'prov-blank',
        name: 'Home Health Aide',
        phone: '',
        address: '',
      );
      await repo.upsertAppointment(_appt(
        id: 'appt-blank',
        providerId: 'prov-blank',
        startsAt: DateTime.utc(2026, 6, 15, 9),
      ));

      await _pumpDetail(tester, repo: repo, db: db,
          appointmentId: 'appt-blank');

      final OutlinedButton call = tester.widget(
        find.byKey(AppointmentDetailScreen.callButtonKey),
      );
      final OutlinedButton dir = tester.widget(
        find.byKey(AppointmentDetailScreen.directionsButtonKey),
      );
      expect(call.onPressed, isNull);
      expect(dir.onPressed, isNull);
      expect(find.text('Home Health Aide'), findsOneWidget);
    });
  });
}
