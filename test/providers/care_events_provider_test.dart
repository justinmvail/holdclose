import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart';
import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/models/care_task.dart';
import 'package:holdclose/providers/active_patient_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

CareEvent _note({
  required String id,
  required DateTime start,
  String title = 'Pick up prescription',
  String patientId = _patientId,
}) =>
    CareEvent(
      id: id,
      kind: CareEventKind.note,
      title: title,
      start: start,
      patientId: patientId,
    );

/// Pins the active loved one for the display-scoped [careEvents] (notes
/// portion) + [calendarTaskEvents] providers without hitting the on-device
/// SQLite file (the default `activePatientIdProvider` reads storage). Tests
/// pass the same id their seeded rows carry so the calendar sees them.
Override _activePatient([String id = _patientId]) =>
    activePatientIdProvider.overrideWith((Ref ref) async => id);

Appointment _appointment({
  required String id,
  required String providerId,
  required DateTime startsAt,
  int durationMinutes = 30,
  String location = 'Clinic',
}) =>
    Appointment(
      id: id,
      providerId: providerId,
      startsAt: startsAt,
      durationMinutes: durationMinutes,
      location: location,
      agenda: const <String>[],
      status: AppointmentStatus.upcoming,
    );

Provider _provider({required String id, required String name}) => Provider(
      id: id,
      name: name,
      role: ProviderRole.doctor,
      phone: '555-0100',
      address: '1 Main St',
    );

void main() {
  group('careEventFromAppointment — projection', () {
    test('projects to a kind=appointment event routing to the source', () {
      final Appointment appt = _appointment(
        id: 'a1',
        providerId: 'p1',
        startsAt: DateTime(2026, 6, 3, 14, 30),
        durationMinutes: 45,
      );

      final CareEvent event =
          careEventFromAppointment(appt, providerName: 'Dr. Patel');

      expect(event.kind, CareEventKind.appointment);
      expect(event.title, 'Dr. Patel');
      expect(event.externalRef, 'a1');
      expect(event.detailRoute, '/appointments/a1');
      // end = start + duration.
      expect(event.end, DateTime(2026, 6, 3, 15, 15));
      expect(event.patientId, fallbackPatientId);
    });

    test('falls back to the location, then a bare label, for the title', () {
      final CareEvent withLocation = careEventFromAppointment(
        _appointment(
          id: 'a1',
          providerId: 'p1',
          startsAt: DateTime(2026, 6, 3, 9),
          location: 'Telehealth',
        ),
      );
      expect(withLocation.title, 'Telehealth');

      final CareEvent bare = careEventFromAppointment(
        _appointment(
          id: 'a2',
          providerId: 'p1',
          startsAt: DateTime(2026, 6, 3, 9),
          location: '',
        ),
        providerName: '   ',
      );
      expect(bare.title, 'Appointment');
    });
  });

  group('CareEvent — routing + duration', () {
    test('detailRoute is derived per kind from externalRef', () {
      CareEvent base(CareEventKind kind, {String? ref}) => CareEvent(
            id: 'e',
            kind: kind,
            title: 't',
            start: DateTime(2026, 6, 1),
            patientId: _patientId,
            externalRef: ref,
          );

      expect(base(CareEventKind.appointment, ref: 'a1').detailRoute,
          '/appointments/a1');
      // Tasks have no per-id detail page; a tapped block opens the list.
      expect(base(CareEventKind.task, ref: 't1').detailRoute, '/team/tasks');
      expect(base(CareEventKind.shift, ref: 's1').detailRoute,
          '/team/shifts/s1');
      // Health-log entries route into the edit form (the only entry-level
      // route) — there is no bare `health-log/:id`, so a timeline/calendar
      // tap must not dead-end on "Page Not Found".
      expect(base(CareEventKind.healthLogEntry, ref: 'hl1').detailRoute,
          '/medical/health-log/hl1/edit');
      // Notes have no detail page; a missing ref is non-tappable.
      expect(base(CareEventKind.note, ref: 'n1').detailRoute, isNull);
      expect(base(CareEventKind.appointment).detailRoute, isNull);
    });

    test('blockDuration falls back to one hour without (or with bad) end', () {
      final DateTime start = DateTime(2026, 6, 1, 8);
      expect(
        _note(id: 'n', start: start).blockDuration,
        const Duration(hours: 1),
      );
      expect(
        CareEvent(
          id: 'n2',
          kind: CareEventKind.note,
          title: 't',
          start: start,
          end: start.subtract(const Duration(hours: 1)),
          patientId: _patientId,
        ).blockDuration,
        const Duration(hours: 1),
      );
      expect(
        CareEvent(
          id: 'n3',
          kind: CareEventKind.note,
          title: 't',
          start: start,
          end: start.add(const Duration(minutes: 90)),
          patientId: _patientId,
        ).blockDuration,
        const Duration(minutes: 90),
      );
    });

    test('round-trips through JSON', () {
      final CareEvent event = CareEvent(
        id: 'e1',
        kind: CareEventKind.shift,
        title: 'Morning shift',
        start: DateTime.utc(2026, 6, 2, 8),
        end: DateTime.utc(2026, 6, 2, 12),
        ownerCaregiverId: 'c1',
        patientId: _patientId,
        externalRef: 's1',
      );
      expect(CareEvent.fromJson(event.toJson()), event);
    });
  });

  group('CareEventsRepository — native notes CRUD', () {
    late HoldcloseDatabase db;
    late CareEventsRepository repo;

    setUp(() {
      db = HoldcloseDatabase(NativeDatabase.memory());
      repo = CareEventsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('note round-trips and lists chronologically', () async {
      await repo.upsertEvent(_note(id: 'n2', start: DateTime(2026, 6, 3, 10)));
      await repo.upsertEvent(_note(id: 'n1', start: DateTime(2026, 6, 1, 10)));

      final List<CareEvent> all = await repo.listEvents();
      expect(all.map((CareEvent e) => e.id), <String>['n1', 'n2']);
      expect(await repo.getEvent('n1'), isNotNull);
    });

    test('deleteEvent removes the row; wipeAll truncates the table', () async {
      await repo.upsertEvent(_note(id: 'n1', start: DateTime(2026, 6, 1, 10)));
      await repo.deleteEvent('n1');
      expect(await repo.getEvent('n1'), isNull);

      await repo.upsertEvent(_note(id: 'n2', start: DateTime(2026, 6, 1, 10)));
      await db.wipeAll();
      expect(await repo.listEvents(), isEmpty);
    });

    test(
        'listEventsForPatient filters to one patient; listEvents stays '
        'unfiltered (for sync)', () async {
      await repo.upsertEvent(_note(
        id: 'mine',
        start: DateTime(2026, 6, 1, 10),
        patientId: _patientId,
      ));
      await repo.upsertEvent(_note(
        id: 'theirs',
        start: DateTime(2026, 6, 1, 10),
        patientId: 'other-patient',
      ));

      expect(
        (await repo.listEventsForPatient(_patientId))
            .map((CareEvent e) => e.id),
        <String>['mine'],
      );
      expect(
        (await repo.listEvents()).map((CareEvent e) => e.id).toSet(),
        <String>{'mine', 'theirs'},
      );
    });

    test('restampPatient re-files legacy notes and is a no-op when from==to',
        () async {
      await repo.upsertEvent(_note(
        id: 'legacy',
        start: DateTime(2026, 6, 1, 10),
        patientId: 'demo-patient-mary',
      ));

      expect(
        await repo.restampPatient('demo-patient-mary', 'patient-new'),
        1,
      );
      expect(await repo.listEventsForPatient('demo-patient-mary'), isEmpty);
      expect(
        (await repo.listEventsForPatient('patient-new'))
            .map((CareEvent e) => e.id),
        <String>['legacy'],
      );
      expect(await repo.restampPatient('patient-new', 'patient-new'), 0);
    });
  });

  group('careEvents — four-source unification', () {
    late HoldcloseDatabase db;
    late AppointmentRepository appointmentRepo;
    late ProviderRepository providerRepo;
    late CareEventsRepository careEventsRepo;
    late CareTasksRepository careTasksRepo;

    setUp(() {
      db = HoldcloseDatabase(NativeDatabase.memory());
      appointmentRepo = AppointmentRepository(db);
      providerRepo = ProviderRepository(db);
      careEventsRepo = CareEventsRepository(db);
      careTasksRepo = CareTasksRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    ProviderContainer makeContainer({
      List<CareEvent> taskEvents = const <CareEvent>[],
      List<CareEvent> shiftEvents = const <CareEvent>[],
    }) {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appointmentRepositoryProvider.overrideWithValue(appointmentRepo),
          careEventsRepositoryProvider.overrideWithValue(careEventsRepo),
          calendarTaskEventsProvider.overrideWith((Ref ref) async => taskEvents),
          calendarShiftEventsProvider
              .overrideWith((Ref ref) async => shiftEvents),
          _activePatient(),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('merges appointments, tasks, shifts, and notes, sorted by start',
        () async {
      await providerRepo.upsertProvider(_provider(id: 'p1', name: 'Dr. Patel'));
      await appointmentRepo.upsertAppointment(_appointment(
        id: 'a1',
        providerId: 'p1',
        startsAt: DateTime(2026, 6, 3, 14),
      ));
      await careEventsRepo
          .upsertEvent(_note(id: 'n1', start: DateTime(2026, 6, 3, 9)));

      final CareEvent task = CareEvent(
        id: 'task-t1',
        kind: CareEventKind.task,
        title: 'Refill meds',
        start: DateTime(2026, 6, 3, 11),
        patientId: _patientId,
        externalRef: 't1',
      );
      final CareEvent shift = CareEvent(
        id: 'shift-s1',
        kind: CareEventKind.shift,
        title: 'Evening shift',
        start: DateTime(2026, 6, 3, 18),
        patientId: _patientId,
        externalRef: 's1',
      );

      final ProviderContainer container = makeContainer(
        taskEvents: <CareEvent>[task],
        shiftEvents: <CareEvent>[shift],
      );
      final List<CareEvent> events =
          await container.read(careEventsProvider.future);

      // One per source, sorted chronologically: note 9, task 11, appt 14,
      // shift 18.
      expect(
        events.map((CareEvent e) => e.kind),
        <CareEventKind>[
          CareEventKind.note,
          CareEventKind.task,
          CareEventKind.appointment,
          CareEventKind.shift,
        ],
      );
      // The projected appointment carries the resolved provider name + a
      // route back to its source.
      final CareEvent appt =
          events.firstWhere((CareEvent e) => e.kind == CareEventKind.appointment);
      expect(appt.title, 'Dr. Patel');
      expect(appt.detailRoute, '/appointments/a1');
    });

    test('a note filed under another loved one is hidden from the calendar',
        () async {
      // Two notes under two different loved ones; the active patient is
      // _patientId (pinned by makeContainer's _activePatient override).
      await careEventsRepo.upsertEvent(_note(
        id: 'mine',
        start: DateTime(2026, 6, 3, 9),
        patientId: _patientId,
      ));
      await careEventsRepo.upsertEvent(_note(
        id: 'theirs',
        start: DateTime(2026, 6, 3, 9),
        patientId: 'other-patient',
      ));

      final List<CareEvent> events =
          await makeContainer().read(careEventsProvider.future);

      final Iterable<String> noteIds = events
          .where((CareEvent e) => e.kind == CareEventKind.note)
          .map((CareEvent e) => e.id);
      expect(noteIds, <String>['mine']);
    });

    test('the task + shift seams contribute nothing with no tasks', () async {
      await providerRepo.upsertProvider(_provider(id: 'p1', name: 'Dr. Patel'));
      await appointmentRepo.upsertAppointment(_appointment(
        id: 'a1',
        providerId: 'p1',
        startsAt: DateTime(2026, 6, 3, 14),
      ));

      // The shift seam is still empty by default; the task seam now reads
      // the (empty) tasks repo, so neither contributes — only the
      // appointment surfaces.
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appointmentRepositoryProvider.overrideWithValue(appointmentRepo),
          careEventsRepositoryProvider.overrideWithValue(careEventsRepo),
          careTasksRepositoryProvider.overrideWithValue(careTasksRepo),
          _activePatient(),
        ],
      );
      addTearDown(container.dispose);

      final List<CareEvent> events =
          await container.read(careEventsProvider.future);
      expect(events, hasLength(1));
      expect(events.single.kind, CareEventKind.appointment);
    });

    test(
        'calendarTaskEvents projects standalone-with-dueAt tasks and '
        'excludes routine-bound tasks', () async {
      // Standalone with a due time → projects.
      await careTasksRepo.upsertTask(CareTask(
        id: 'standalone',
        title: 'Refill meds',
        dueAt: DateTime(2026, 6, 3, 11),
        patientId: _patientId,
      ));
      // Standalone with no due time → no schedule block.
      await careTasksRepo.upsertTask(const CareTask(
        id: 'no-due',
        title: 'Someday',
        patientId: _patientId,
      ));
      // Routine-bound (even with a due time) → bundled under its routine,
      // never a loose calendar block.
      await careTasksRepo.upsertTask(CareTask(
        id: 'bundled',
        title: 'Brush teeth',
        dueAt: DateTime(2026, 6, 3, 8),
        routineId: 'r-1',
        patientId: _patientId,
      ));

      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          careTasksRepositoryProvider.overrideWithValue(careTasksRepo),
          _activePatient(),
        ],
      );
      addTearDown(container.dispose);

      final List<CareEvent> events =
          await container.read(calendarTaskEventsProvider.future);
      expect(events, hasLength(1));
      final CareEvent event = events.single;
      expect(event.kind, CareEventKind.task);
      expect(event.id, 'task-standalone');
      expect(event.title, 'Refill meds');
      expect(event.externalRef, 'standalone');
      expect(event.start, DateTime(2026, 6, 3, 11));
      expect(event.detailRoute, '/team/tasks');
    });

    test('careEventFromTask maps task fields onto the calendar event', () {
      final CareTask task = CareTask(
        id: 't1',
        title: 'Refill meds',
        body: 'From the pharmacy',
        dueAt: DateTime(2026, 6, 3, 11),
        assigneeCaregiverId: 'c1',
        patientId: _patientId,
      );

      final CareEvent event = careEventFromTask(task);

      expect(event.id, 'task-t1');
      expect(event.kind, CareEventKind.task);
      expect(event.title, 'Refill meds');
      expect(event.subtitle, 'From the pharmacy');
      expect(event.start, DateTime(2026, 6, 3, 11));
      expect(event.ownerCaregiverId, 'c1');
      expect(event.patientId, _patientId);
      expect(event.externalRef, 't1');
    });
  });
}
