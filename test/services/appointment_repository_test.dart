import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed clock so the [AppointmentRepository.upcoming] / `past` split is
/// deterministic against the seeded appointment dates below.
DateTime _fixedNow() => DateTime.utc(2026, 6, 1, 12);

Appointment _appt({
  required String id,
  required DateTime startsAt,
  String providerId = 'prov-1',
  AppointmentStatus status = AppointmentStatus.upcoming,
  List<String> agenda = const <String>[],
  String? notes,
}) =>
    Appointment(
      id: id,
      providerId: providerId,
      startsAt: startsAt,
      durationMinutes: 30,
      location: 'Marin General — Neurology',
      agenda: agenda,
      status: status,
      notes: notes,
    );

void main() {
  group('AppointmentRepository — TASKS.md Phase 12.6', () {
    late HoldcloseDatabase db;
    late AppointmentRepository repo;

    setUp(() async {
      db = HoldcloseDatabase(NativeDatabase.memory());
      repo = AppointmentRepository(db, clock: _fixedNow);
      // Seed a provider for the FK so appointment inserts succeed.
      await db.into(db.providersTable).insertOnConflictUpdate(
            ProvidersTableCompanion.insert(
              id: 'prov-1',
              name: 'Dr. Ortega',
              payload:
                  '{"id":"prov-1","name":"Dr. Ortega","role":"neurologist",'
                  '"phone":"(415) 555-0188","address":"250 Bon Air Rd"}',
            ),
          );
    });

    tearDown(() async {
      await db.close();
    });

    // ---- Appointment CRUD ---------------------------------------------------

    test('upsertAppointment + getAppointment round-trips the model', () async {
      final Appointment a = _appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        agenda: const <String>['Ask about evening agitation', 'Med refill'],
        notes: 'Bring journal',
      );
      await repo.upsertAppointment(a);

      final Appointment? loaded = await repo.getAppointment('appt-1');
      expect(loaded, equals(a));
    });

    test('getAppointment returns null for an unknown id', () async {
      expect(await repo.getAppointment('never-existed'), isNull);
    });

    test('upsertAppointment overwrites an existing row', () async {
      final Appointment a = _appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
      );
      await repo.upsertAppointment(a);
      // Toggle status + add an agenda item — the detail screen flow.
      final Appointment edited = a.copyWith(
        status: AppointmentStatus.completed,
        agenda: const <String>['Med refill', 'Discuss sleep'],
        notes: 'Went well',
      );
      await repo.upsertAppointment(edited);

      final Appointment? loaded = await repo.getAppointment('appt-1');
      expect(loaded, equals(edited));
      expect(loaded?.status, AppointmentStatus.completed);
    });

    test('deleteAppointment drops the row but leaves the provider', () async {
      await repo.upsertAppointment(_appt(
        id: 'appt-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
      ));
      await repo.deleteAppointment('appt-1');

      expect(await repo.getAppointment('appt-1'), isNull);
      expect(await repo.getProvider('prov-1'), isNotNull);
    });

    test('listAppointments returns every row chronologically', () async {
      await repo.upsertAppointment(_appt(
        id: 'appt-late',
        startsAt: DateTime.utc(2026, 6, 20, 9),
      ));
      await repo.upsertAppointment(_appt(
        id: 'appt-early',
        startsAt: DateTime.utc(2026, 5, 20, 9),
      ));
      await repo.upsertAppointment(_appt(
        id: 'appt-mid',
        startsAt: DateTime.utc(2026, 6, 1, 9),
      ));

      final List<Appointment> rows = await repo.listAppointments();
      expect(rows.map((Appointment a) => a.id).toList(),
          <String>['appt-early', 'appt-mid', 'appt-late']);
    });

    // ---- Provider reads -----------------------------------------------------

    test('getProvider returns the seeded provider', () async {
      final Provider? loaded = await repo.getProvider('prov-1');
      expect(loaded, isNotNull);
      expect(loaded!.name, 'Dr. Ortega');
      expect(loaded.role, ProviderRole.neurologist);
    });

    test('getProvider returns null for an unknown id', () async {
      expect(await repo.getProvider('never-existed'), isNull);
    });

    test('listProviders sorts alphabetically by name', () async {
      // Insert a second provider out-of-order so the sort must do work.
      await db.into(db.providersTable).insertOnConflictUpdate(
            ProvidersTableCompanion.insert(
              id: 'prov-2',
              name: 'Dr. Adler',
              payload:
                  '{"id":"prov-2","name":"Dr. Adler","role":"doctor",'
                  '"phone":"(415) 555-0100","address":"123 Main St"}',
            ),
          );

      final List<Provider> rows = await repo.listProviders();
      expect(rows.map((Provider p) => p.name).toList(),
          <String>['Dr. Adler', 'Dr. Ortega']);
    });

    // ---- Grouped views (upcoming / past) ------------------------------------

    test('upcoming returns only future, status=upcoming, chronological',
        () async {
      // Past + upcoming status — belongs in `past`.
      await repo.upsertAppointment(_appt(
        id: 'past-upcoming',
        startsAt: DateTime.utc(2026, 5, 15, 9),
      ));
      // Future + completed — belongs in `past`.
      await repo.upsertAppointment(_appt(
        id: 'future-completed',
        startsAt: DateTime.utc(2026, 6, 10, 9),
        status: AppointmentStatus.completed,
      ));
      // Future + upcoming — belongs in `upcoming`.
      await repo.upsertAppointment(_appt(
        id: 'soon',
        startsAt: DateTime.utc(2026, 6, 2, 9),
      ));
      await repo.upsertAppointment(_appt(
        id: 'later',
        startsAt: DateTime.utc(2026, 6, 20, 9),
      ));
      // Right at the clock — counts as upcoming (>= now).
      await repo.upsertAppointment(_appt(
        id: 'right-now',
        startsAt: DateTime.utc(2026, 6, 1, 12),
      ));

      final List<Appointment> rows = await repo.upcoming();
      expect(rows.map((Appointment a) => a.id).toList(),
          <String>['right-now', 'soon', 'later']);
    });

    test(
        'past returns completed + canceled + slipped-upcoming, '
        'most-recent first', () async {
      await repo.upsertAppointment(_appt(
        id: 'old-completed',
        startsAt: DateTime.utc(2026, 4, 1, 9),
        status: AppointmentStatus.completed,
      ));
      await repo.upsertAppointment(_appt(
        id: 'newer-canceled',
        startsAt: DateTime.utc(2026, 5, 25, 9),
        status: AppointmentStatus.canceled,
      ));
      // Future + completed → past.
      await repo.upsertAppointment(_appt(
        id: 'future-completed',
        startsAt: DateTime.utc(2026, 7, 1, 9),
        status: AppointmentStatus.completed,
      ));
      // Past + upcoming → past (slipped off the calendar).
      await repo.upsertAppointment(_appt(
        id: 'slipped',
        startsAt: DateTime.utc(2026, 5, 1, 9),
      ));
      // Future + upcoming → NOT past.
      await repo.upsertAppointment(_appt(
        id: 'future-upcoming',
        startsAt: DateTime.utc(2026, 6, 15, 9),
      ));

      final List<Appointment> rows = await repo.past();
      expect(
        rows.map((Appointment a) => a.id).toList(),
        <String>[
          'future-completed', // 2026-07-01
          'newer-canceled', // 2026-05-25
          'slipped', // 2026-05-01
          'old-completed', // 2026-04-01
        ],
      );
    });

    test('upcoming + past partition every row exactly once', () async {
      await repo.upsertAppointment(_appt(
        id: 'a',
        startsAt: DateTime.utc(2026, 6, 15, 9),
      ));
      await repo.upsertAppointment(_appt(
        id: 'b',
        startsAt: DateTime.utc(2026, 4, 1, 9),
        status: AppointmentStatus.completed,
      ));
      await repo.upsertAppointment(_appt(
        id: 'c',
        startsAt: DateTime.utc(2026, 5, 25, 9),
        status: AppointmentStatus.canceled,
      ));

      final Set<String> upcoming =
          (await repo.upcoming()).map((Appointment a) => a.id).toSet();
      final Set<String> past =
          (await repo.past()).map((Appointment a) => a.id).toSet();

      expect(upcoming.intersection(past), isEmpty,
          reason: 'no appointment belongs to both groups');
      expect(upcoming.union(past), <String>{'a', 'b', 'c'},
          reason: 'every appointment lands in exactly one group');
    });
  });
}
