import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/models/care_task.dart';
import 'package:holdclose/providers/active_patient_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/patient_timeline_provider.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Coverage for the unified task/routine projection onto the patient
/// timeline (2026-06-06). A standalone task with a due time rides the
/// schedule the way a routine occurrence does; a routine-bound task is
/// bundled under its routine and never surfaces as a loose event.
///
/// The merger reads several per-source providers; the non-task sources are
/// overridden to empty so the assertions isolate the task projection. The
/// appointment source reads its repository directly, so an empty in-memory
/// repo stands in. Tasks come from the real [calendarTaskEventsProvider] /
/// [patientTaskEventsProvider] path against an in-memory tasks repo.

const String _patientId = 'demo-patient-mary';

CareTask _task({
  required String id,
  String title = 'Refill meds',
  DateTime? dueAt,
  String? routineId,
  String patientId = _patientId,
}) =>
    CareTask(
      id: id,
      title: title,
      dueAt: dueAt,
      routineId: routineId,
      patientId: patientId,
    );

void main() {
  late HoldcloseDatabase db;
  late AppointmentRepository appointmentRepo;
  late CareTasksRepository tasksRepo;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    appointmentRepo = AppointmentRepository(db);
    tasksRepo = CareTasksRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        appointmentRepositoryProvider.overrideWithValue(appointmentRepo),
        careTasksRepositoryProvider.overrideWithValue(tasksRepo),
        // Pin the active loved one so the task projection is scoped without
        // touching the on-device SQLite file (the default
        // activePatientIdProvider reads storage); the seeded tasks carry the
        // same id so they surface.
        activePatientIdProvider.overrideWith((Ref ref) async => _patientId),
        // Isolate the task projection — every other patient-scoped source
        // contributes nothing.
        patientDoseEventsProvider.overrideWith((Ref ref) async =>
            const <CareEvent>[]),
        patientHealthLogEventsProvider.overrideWith((Ref ref) async =>
            const <CareEvent>[]),
        patientJournalEventsProvider.overrideWith((Ref ref) async =>
            const <CareEvent>[]),
        patientCarePlanEventsProvider.overrideWith((Ref ref) async =>
            const <CareEvent>[]),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('patientTaskEvents — standalone projection', () {
    test('projects a standalone task that carries a due time', () async {
      await tasksRepo.upsertTask(
          _task(id: 's1', dueAt: DateTime(2026, 6, 3, 11)));

      final List<CareEvent> events =
          await makeContainer().read(patientTaskEventsProvider.future);

      expect(events, hasLength(1));
      expect(events.single.kind, CareEventKind.task);
      expect(events.single.externalRef, 's1');
    });

    test('excludes a standalone task with no due time', () async {
      await tasksRepo.upsertTask(_task(id: 'no-due'));

      final List<CareEvent> events =
          await makeContainer().read(patientTaskEventsProvider.future);

      expect(events, isEmpty);
    });

    test('excludes a routine-bound task even when it has a due time',
        () async {
      await tasksRepo.upsertTask(_task(
        id: 'bundled',
        dueAt: DateTime(2026, 6, 3, 8),
        routineId: 'r-1',
      ));

      final List<CareEvent> events =
          await makeContainer().read(patientTaskEventsProvider.future);

      expect(events, isEmpty);
    });

    test('excludes a standalone task filed under another loved one', () async {
      // Active patient is _patientId; this task belongs to someone else, so
      // it must not ride the active person's timeline.
      await tasksRepo.upsertTask(_task(
        id: 'theirs',
        dueAt: DateTime(2026, 6, 3, 11),
        patientId: 'other-patient',
      ));

      final List<CareEvent> events =
          await makeContainer().read(patientTaskEventsProvider.future);

      expect(events, isEmpty);
    });
  });

  group('patientTimelineEvents — task merge', () {
    test('a standalone task with a due time appears as a loose event',
        () async {
      await tasksRepo.upsertTask(
          _task(id: 's1', dueAt: DateTime(2026, 6, 3, 11)));

      final List<CareEvent> events =
          await makeContainer().read(patientTimelineEventsProvider.future);

      final Iterable<CareEvent> tasks =
          events.where((CareEvent e) => e.kind == CareEventKind.task);
      expect(tasks, hasLength(1));
      expect(tasks.single.externalRef, 's1');
    });

    test('a routine-bound task does NOT appear as a loose event', () async {
      await tasksRepo.upsertTask(_task(
        id: 'bundled',
        dueAt: DateTime(2026, 6, 3, 8),
        routineId: 'r-1',
      ));

      final List<CareEvent> events =
          await makeContainer().read(patientTimelineEventsProvider.future);

      expect(
        events.where((CareEvent e) => e.kind == CareEventKind.task),
        isEmpty,
      );
    });
  });
}
