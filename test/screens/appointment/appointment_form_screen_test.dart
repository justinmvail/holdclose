import 'dart:convert';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart' as model;
import 'package:careblazers/screens/appointment/appointment_form_screen.dart';
import 'package:careblazers/screens/appointment/appointment_list_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Fixed "now" so the default startsAt slot is deterministic — the form
/// stamps the slot one week out at the next round hour after the
/// initial clock sample.
DateTime _fixedNow() => DateTime(2026, 5, 30, 9, 0);

/// Deterministic id factory: each call returns `id0`, `id1`, … so the
/// form mints `appt-id0` for an appointment and `prov-id0` for the
/// inline provider creation.
String Function() _counterFactory() {
  int n = 0;
  return () => 'id${n++}';
}

Future<void> _seedProvider(
  CareblazersDatabase db, {
  required String id,
  required String name,
  String phone = '(415) 555-0188',
  String address = '250 Bon Air Rd, Greenbrae CA',
  model.ProviderRole role = model.ProviderRole.neurologist,
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

Future<({
  GoRouter router,
  AppointmentRepository apptRepo,
  ProviderRepository providerRepo,
  CareblazersDatabase db,
  List<String> popped,
})> _pumpForm(
  WidgetTester tester, {
  required AppointmentRepository apptRepo,
  required ProviderRepository providerRepo,
  required CareblazersDatabase db,
  String? editAppointmentId,
  String Function()? idFactory,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final List<String> popped = <String>[];
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final String initialLocation = editAppointmentId == null
      ? '/appointments/new'
      : '/appointments/$editAppointmentId/edit';
  final GoRouter router = GoRouter(
    initialLocation: initialLocation,
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/appointments',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) {
          popped.add('/appointments');
          return const Scaffold(body: Center(child: Text('list-stub')));
        },
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) =>
                const AppointmentFormScreen(),
          ),
          GoRoute(
            path: ':id',
            parentNavigatorKey: rootKey,
            builder: (BuildContext context, GoRouterState state) {
              popped.add('/appointments/${state.pathParameters['id']}');
              return const Scaffold(body: Center(child: Text('detail-stub')));
            },
            routes: <RouteBase>[
              GoRoute(
                path: 'edit',
                parentNavigatorKey: rootKey,
                builder: (BuildContext context, GoRouterState state) =>
                    AppointmentFormScreen(
                  appointmentId: state.pathParameters['id'],
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: <Override>[
        appointmentRepositoryBackendProvider.overrideWithValue(apptRepo),
        providerRepositoryBackendProvider.overrideWithValue(providerRepo),
        appointmentFormClockProvider.overrideWithValue(_fixedNow),
        appointmentFormIdFactoryProvider
            .overrideWithValue(idFactory ?? _counterFactory()),
        appointmentListClockProvider.overrideWithValue(_fixedNow),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return (
    router: router,
    apptRepo: apptRepo,
    providerRepo: providerRepo,
    db: db,
    popped: popped,
  );
}

void main() {
  late CareblazersDatabase db;
  late AppointmentRepository apptRepo;
  late ProviderRepository providerRepo;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    apptRepo = AppointmentRepository(db, clock: _fixedNow);
    providerRepo = ProviderRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('AppointmentFormScreen — add path with existing provider', () {
    testWidgets(
        'submitting without a provider selection surfaces a snackbar',
        (WidgetTester tester) async {
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      final p = await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      // Tap submit without picking a provider.
      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Pick a provider or add a new one first.'),
          findsOneWidget);
      expect(await p.apptRepo.listAppointments(), isEmpty);
    });

    testWidgets('submitting with a bad duration surfaces a validation error',
        (WidgetTester tester) async {
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      // Open the provider dropdown and pick one.
      await tester.tap(find.byKey(AppointmentFormScreen.providerDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dr. Ortega').last);
      await tester.pumpAndSettle();

      // Clear duration to an invalid value.
      await tester.enterText(
        find.byKey(AppointmentFormScreen.durationFieldKey),
        '-5',
      );
      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Use a positive whole number of minutes.'),
          findsOneWidget);
      expect(await apptRepo.listAppointments(), isEmpty);
    });

    testWidgets('happy path — selecting an existing provider and saving '
        'inserts an Appointment + pops back', (WidgetTester tester) async {
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      final p = await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.providerDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dr. Ortega').last);
      await tester.pumpAndSettle();

      // Picking an existing provider auto-fills the location from the
      // provider's address. The caregiver can still override it.
      await tester.enterText(
        find.byKey(AppointmentFormScreen.locationFieldKey),
        'Marin General — Neurology, Suite 200',
      );
      await tester.enterText(
        find.byKey(AppointmentFormScreen.durationFieldKey),
        '45',
      );

      // Add two agenda items.
      await tester.tap(find.byKey(AppointmentFormScreen.addAgendaButtonKey));
      await tester.pump();
      await tester.enterText(
        find.byKey(AppointmentFormScreen.agendaItemFieldKey(0)),
        'Ask about evening agitation',
      );
      await tester.tap(find.byKey(AppointmentFormScreen.addAgendaButtonKey));
      await tester.pump();
      await tester.enterText(
        find.byKey(AppointmentFormScreen.agendaItemFieldKey(1)),
        'Refill Donepezil',
      );

      await tester.enterText(
        find.byKey(AppointmentFormScreen.notesFieldKey),
        'Bring journal.',
      );

      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(p.popped, contains('/appointments'));

      final List<model.Appointment> rows = await apptRepo.listAppointments();
      expect(rows, hasLength(1));
      final model.Appointment saved = rows.single;
      expect(saved.id, 'appt-id0');
      expect(saved.providerId, 'prov-1');
      expect(saved.durationMinutes, 45);
      expect(saved.location, 'Marin General — Neurology, Suite 200');
      expect(saved.agenda,
          <String>['Ask about evening agitation', 'Refill Donepezil']);
      expect(saved.status, model.AppointmentStatus.upcoming);
      expect(saved.notes, 'Bring journal.');
    });

    testWidgets(
        'double-tapping Save writes exactly ONE appointment row '
        '(the in-flight guard blocks the re-entrant submit)',
        (WidgetTester tester) async {
      // Regression: a fast double-tap on Save used to mint a second
      // `appt-${mint()}` id and insert a duplicate row. The `_submitting`
      // guard (set synchronously before the first await + the button's
      // `onPressed: _submitting ? null : _submit` disable) must collapse
      // the two taps into a single insert. A fresh monotonic id factory
      // proves it: an unguarded second submit would mint `appt-id1` and
      // land a second row.
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      final p = await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.providerDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dr. Ortega').last);
      await tester.pumpAndSettle();

      // First tap kicks off the (async) save; the second tap fires before
      // it settles. The guard must drop the second.
      final Finder save = find.byKey(AppointmentFormScreen.submitButtonKey);
      await tester.tap(save);
      await tester.pump(); // commit setState(_submitting = true) + disable
      await tester.tap(save, warnIfMissed: false);
      await tester.pumpAndSettle();

      // Exactly one row, and it kept the first minted id.
      final List<model.Appointment> rows = await apptRepo.listAppointments();
      expect(rows, hasLength(1));
      expect(rows.single.id, 'appt-id0');
      expect(p.popped, contains('/appointments'));
    });

    testWidgets(
        'selecting a provider with an address pre-fills the location field',
        (WidgetTester tester) async {
      await _seedProvider(
        db,
        id: 'prov-1',
        name: 'Dr. Ortega',
        address: '250 Bon Air Rd, Greenbrae CA',
      );
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.providerDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dr. Ortega').last);
      await tester.pumpAndSettle();

      final TextFormField loc = tester.widget<TextFormField>(
          find.byKey(AppointmentFormScreen.locationFieldKey));
      expect(loc.controller?.text, '250 Bon Air Rd, Greenbrae CA');
    });

    testWidgets('empty agenda items are dropped before persisting',
        (WidgetTester tester) async {
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.providerDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dr. Ortega').last);
      await tester.pumpAndSettle();

      // Add two agenda rows but only fill one.
      await tester.tap(find.byKey(AppointmentFormScreen.addAgendaButtonKey));
      await tester.pump();
      await tester.tap(find.byKey(AppointmentFormScreen.addAgendaButtonKey));
      await tester.pump();
      await tester.enterText(
        find.byKey(AppointmentFormScreen.agendaItemFieldKey(0)),
        'Ask about new symptoms',
      );

      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final model.Appointment saved =
          (await apptRepo.listAppointments()).single;
      expect(saved.agenda, <String>['Ask about new symptoms']);
    });

    testWidgets('removing an agenda item shifts the remaining rows down',
        (WidgetTester tester) async {
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.providerDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dr. Ortega').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AppointmentFormScreen.addAgendaButtonKey));
      await tester.pump();
      await tester.tap(find.byKey(AppointmentFormScreen.addAgendaButtonKey));
      await tester.pump();
      await tester.enterText(
        find.byKey(AppointmentFormScreen.agendaItemFieldKey(0)),
        'A',
      );
      await tester.enterText(
        find.byKey(AppointmentFormScreen.agendaItemFieldKey(1)),
        'B',
      );

      // Remove the first row; the second should slide up.
      await tester.tap(find.byKey(AppointmentFormScreen.agendaItemRemoveKey(0)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final model.Appointment saved =
          (await apptRepo.listAppointments()).single;
      expect(saved.agenda, <String>['B']);
    });
  });

  group('AppointmentFormScreen — inline provider creation', () {
    testWidgets(
        'with no providers, the empty-state CTA opens the inline form',
        (WidgetTester tester) async {
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      expect(find.text('No providers on file yet. Add the first one below.'),
          findsOneWidget);
      await tester.tap(find.byKey(AppointmentFormScreen.addProviderToggleKey));
      await tester.pumpAndSettle();

      expect(find.byKey(AppointmentFormScreen.newProviderNameFieldKey),
          findsOneWidget);
    });

    testWidgets(
        'saving an inline provider with an empty name surfaces an error '
        'and does not insert', (WidgetTester tester) async {
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.addProviderToggleKey));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(AppointmentFormScreen.newProviderSaveButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Provider name is required.'), findsOneWidget);
      expect(await providerRepo.listProviders(), isEmpty);
    });

    testWidgets(
        'saving an inline provider inserts the row, selects it, and '
        'pre-fills the location', (WidgetTester tester) async {
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.addProviderToggleKey));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(AppointmentFormScreen.newProviderNameFieldKey),
        'Dr. Marquez',
      );
      await tester.enterText(
        find.byKey(AppointmentFormScreen.newProviderPhoneFieldKey),
        '(415) 555-0199',
      );
      await tester.enterText(
        find.byKey(AppointmentFormScreen.newProviderAddressFieldKey),
        '1 Stanyan St, San Francisco CA',
      );
      await tester.enterText(
        find.byKey(AppointmentFormScreen.newProviderNotesFieldKey),
        'Park on the west side.',
      );

      await tester
          .tap(find.byKey(AppointmentFormScreen.newProviderSaveButtonKey));
      await tester.pumpAndSettle();

      // Provider row landed in the repo.
      final List<model.Provider> providers = await providerRepo.listProviders();
      expect(providers, hasLength(1));
      final model.Provider saved = providers.single;
      expect(saved.id, 'prov-id0');
      expect(saved.name, 'Dr. Marquez');
      expect(saved.role, model.ProviderRole.doctor);
      expect(saved.phone, '(415) 555-0199');
      expect(saved.address, '1 Stanyan St, San Francisco CA');
      expect(saved.notes, 'Park on the west side.');

      // The inline form closed; the dropdown is back.
      expect(find.byKey(AppointmentFormScreen.newProviderNameFieldKey),
          findsNothing);
      expect(find.byKey(AppointmentFormScreen.providerDropdownKey),
          findsOneWidget);

      // Location was auto-filled with the new provider's address.
      final TextFormField loc = tester.widget<TextFormField>(
          find.byKey(AppointmentFormScreen.locationFieldKey));
      expect(loc.controller?.text, '1 Stanyan St, San Francisco CA');
    });

    testWidgets(
        'inline provider creation + appointment submit round-trips both rows',
        (WidgetTester tester) async {
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.addProviderToggleKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(AppointmentFormScreen.newProviderNameFieldKey),
        'Sandra Lee, LCSW',
      );
      await tester.enterText(
        find.byKey(AppointmentFormScreen.newProviderAddressFieldKey),
        'Home visit',
      );
      // Change role to social worker.
      await tester.tap(find.byKey(AppointmentFormScreen.newProviderRoleKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Social worker').last);
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(AppointmentFormScreen.newProviderSaveButtonKey));
      await tester.pumpAndSettle();

      // Submit the appointment — duration default 30 is fine.
      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      // Both the provider and the appointment landed; the appointment
      // FKs onto the freshly-minted provider id.
      final List<model.Provider> providers = await providerRepo.listProviders();
      final List<model.Appointment> appts = await apptRepo.listAppointments();
      expect(providers.single.role, model.ProviderRole.socialWorker);
      expect(appts, hasLength(1));
      expect(appts.single.providerId, providers.single.id);
    });

    testWidgets('canceling the inline form leaves no provider behind',
        (WidgetTester tester) async {
      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      await tester.tap(find.byKey(AppointmentFormScreen.addProviderToggleKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(AppointmentFormScreen.newProviderNameFieldKey),
        'Half-typed',
      );
      await tester
          .tap(find.byKey(AppointmentFormScreen.newProviderCancelButtonKey));
      await tester.pumpAndSettle();

      expect(await providerRepo.listProviders(), isEmpty);
      expect(find.byKey(AppointmentFormScreen.newProviderNameFieldKey),
          findsNothing);
    });
  });

  group('AppointmentFormScreen — edit path', () {
    testWidgets('hydrates an existing appointment + persists edits in place',
        (WidgetTester tester) async {
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      await apptRepo.upsertAppointment(model.Appointment(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 15, 14, 30),
        durationMinutes: 30,
        location: 'Marin General — Neurology',
        agenda: const <String>['Ask about agitation'],
        status: model.AppointmentStatus.upcoming,
        notes: 'Bring journal.',
      ));

      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
        editAppointmentId: 'appt-1',
      );

      // Notes hydrated.
      final TextFormField notes = tester.widget<TextFormField>(
          find.byKey(AppointmentFormScreen.notesFieldKey));
      expect(notes.controller?.text, 'Bring journal.');

      // Edit notes and save.
      await tester.enterText(
        find.byKey(AppointmentFormScreen.notesFieldKey),
        'Bring journal AND the med list.',
      );
      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final model.Appointment? loaded = await apptRepo.getAppointment('appt-1');
      expect(loaded?.notes, 'Bring journal AND the med list.');
      expect(loaded?.id, 'appt-1',
          reason: 'edit must reuse the existing id, not mint a new one');
    });

    testWidgets(
        'removing an agenda item drops its corresponding completed index',
        (WidgetTester tester) async {
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      await apptRepo.upsertAppointment(model.Appointment(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 15, 14, 30),
        durationMinutes: 30,
        location: 'Marin General — Neurology',
        agenda: const <String>['First', 'Second', 'Third'],
        completedAgendaIndices: const <int>{1, 2},
        status: model.AppointmentStatus.upcoming,
      ));

      await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
        editAppointmentId: 'appt-1',
      );

      // Remove the first row; "Second" / "Third" should slide up to
      // index 0 / 1 — and the persisted completed-indices set must
      // shift to {0, 1}.
      await tester.tap(find.byKey(AppointmentFormScreen.agendaItemRemoveKey(0)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      final model.Appointment? loaded = await apptRepo.getAppointment('appt-1');
      expect(loaded?.agenda, <String>['Second', 'Third']);
      expect(loaded?.completedAgendaIndices, <int>{0, 1});
    });

    testWidgets(
        'setting status to Canceled and saving cancels the appointment '
        'in the repository', (WidgetTester tester) async {
      // The detail/form screens ship no dedicated "delete" affordance; the
      // status dropdown's "Canceled" option is the supported cancel path
      // (it round-trips through AppointmentRepository.upsertAppointment,
      // leaving the row in place but flipped to canceled). See the report
      // note re: the missing hard-delete UI.
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      await apptRepo.upsertAppointment(model.Appointment(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime(2026, 6, 15, 14, 30),
        durationMinutes: 30,
        location: 'Marin General — Neurology',
        agenda: const <String>['Ask about agitation'],
        status: model.AppointmentStatus.upcoming,
      ));

      final p = await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
        editAppointmentId: 'appt-1',
      );

      // Flip the status dropdown Upcoming → Canceled.
      await tester.ensureVisible(
          find.byKey(AppointmentFormScreen.statusDropdownKey));
      await tester.tap(find.byKey(AppointmentFormScreen.statusDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Canceled').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
          find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.tap(find.byKey(AppointmentFormScreen.submitButtonKey));
      await tester.pumpAndSettle();

      // The row is still on file (id reused) but now canceled — and the
      // repository's past/upcoming split moves it out of "upcoming".
      final model.Appointment? loaded =
          await p.apptRepo.getAppointment('appt-1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 'appt-1');
      expect(loaded.status, model.AppointmentStatus.canceled);
      final List<model.Appointment> upcoming = await p.apptRepo.upcoming();
      expect(
          upcoming.map((model.Appointment a) => a.id), isNot(contains('appt-1')));
    });
  });

  group('AppointmentFormScreen — discard on the add path', () {
    testWidgets(
        'leaving the add form via the breadcrumb writes no appointment row',
        (WidgetTester tester) async {
      await _seedProvider(db, id: 'prov-1', name: 'Dr. Ortega');
      final p = await _pumpForm(
        tester,
        apptRepo: apptRepo,
        providerRepo: providerRepo,
        db: db,
      );

      // Start filling the form: pick a provider + override the location,
      // then abandon it WITHOUT tapping Save.
      await tester.tap(find.byKey(AppointmentFormScreen.providerDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dr. Ortega').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(AppointmentFormScreen.locationFieldKey),
        'Half-typed location',
      );
      await tester.pumpAndSettle();

      // The form's only back affordance is the PathHeader's parent
      // breadcrumb crumb ("Appointments" → context.go('/appointments')) —
      // there is no Cancel button on the form. Tap it to discard.
      await tester.tap(find.text('Appointments'));
      await tester.pumpAndSettle();

      // Back on the list stub, and nothing was persisted.
      expect(find.text('list-stub'), findsOneWidget);
      expect(p.popped, contains('/appointments'));
      expect(await p.apptRepo.listAppointments(), isEmpty);
    });
  });

  group('AppointmentFormScreen — PathHeader back affordance', () {
    // Regression for alpha bug fb_1780932762335231: the breadcrumb back
    // affordance must be present on every branch — including before the
    // hydration future resolves — so the screen is never swipe-only.
    testWidgets('renders the PathHeader breadcrumb on the loading branch',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final GoRouter router = GoRouter(
        initialLocation: '/appointments/new',
        routes: <RouteBase>[
          GoRoute(
            path: '/appointments/new',
            builder: (BuildContext context, GoRouterState state) =>
                const AppointmentFormScreen(),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appointmentRepositoryBackendProvider.overrideWithValue(apptRepo),
            providerRepositoryBackendProvider
                .overrideWithValue(providerRepo),
            appointmentFormClockProvider.overrideWithValue(_fixedNow),
            appointmentFormIdFactoryProvider
                .overrideWithValue(_counterFactory()),
            appointmentListClockProvider.overrideWithValue(_fixedNow),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      // A single pump — the hydration future has NOT resolved yet, so this
      // is the loading branch. The PathHeader must already be on screen.
      await tester.pump();

      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
      expect(find.text('Appointments'), findsOneWidget);
    });
  });
}
