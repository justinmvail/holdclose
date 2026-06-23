import 'dart:convert';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Appointment tracker tables (TASKS.md Phase 12.5)', () {
    late HoldcloseDatabase db;

    setUp(() {
      db = HoldcloseDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    // ---- Helpers --------------------------------------------------------

    Future<void> insertProvider(Provider p) async {
      await db.into(db.providersTable).insert(
            ProvidersTableCompanion.insert(
              id: p.id,
              name: p.name,
              payload: jsonEncode(p.toJson()),
            ),
          );
    }

    Future<void> insertAppointment(Appointment a) async {
      await db.into(db.appointmentsTable).insert(
            AppointmentsTableCompanion.insert(
              id: a.id,
              providerId: a.providerId,
              startsAtMs: a.startsAt.millisecondsSinceEpoch,
              payload: jsonEncode(a.toJson()),
            ),
          );
    }

    Provider buildProvider({String id = 'prov-001'}) => Provider(
          id: id,
          name: 'Dr. Ortega',
          role: ProviderRole.neurologist,
          phone: '(415) 555-0188',
          address: '250 Bon Air Rd, Greenbrae CA',
        );

    Appointment buildAppointment({
      required String id,
      required String providerId,
      DateTime? startsAt,
      AppointmentStatus status = AppointmentStatus.upcoming,
    }) =>
        Appointment(
          id: id,
          providerId: providerId,
          startsAt: startsAt ?? DateTime.utc(2026, 6, 15, 14, 30),
          durationMinutes: 30,
          location: 'Marin General — Neurology',
          agenda: const <String>['Ask about evening agitation'],
          status: status,
        );

    // ---- Round-trip via the lifted columns ------------------------------

    test('Provider round-trips through the lifted name column', () async {
      await insertProvider(buildProvider());

      final List<ProvidersTableData> rows =
          await db.select(db.providersTable).get();
      expect(rows, hasLength(1));
      expect(rows.single.name, 'Dr. Ortega');

      final Provider parsed = Provider.fromJson(
        jsonDecode(rows.single.payload) as Map<String, dynamic>,
      );
      expect(parsed, equals(buildProvider()));
    });

    test('Appointment round-trips with startsAtMs lifted out', () async {
      await insertProvider(buildProvider());
      final Appointment a =
          buildAppointment(id: 'appt-1', providerId: 'prov-001');
      await insertAppointment(a);

      final List<AppointmentsTableData> rows =
          await db.select(db.appointmentsTable).get();
      expect(rows, hasLength(1));
      expect(rows.single.startsAtMs, a.startsAt.millisecondsSinceEpoch);
      final Appointment parsed = Appointment.fromJson(
        jsonDecode(rows.single.payload) as Map<String, dynamic>,
      );
      expect(parsed, equals(a));
    });

    // ---- Cascade-delete invariants (the task acceptance) ----------------

    test(
        'deleting a Provider cascades through its appointments '
        '— zero orphans survive', () async {
      await insertProvider(buildProvider(id: 'will-die'));
      await insertProvider(buildProvider(id: 'will-live'));

      // Three appointments on the doomed provider, one on the survivor.
      for (int i = 0; i < 3; i++) {
        await insertAppointment(buildAppointment(
          id: 'appt-doomed-$i',
          providerId: 'will-die',
          startsAt: DateTime.utc(2026, 6, 15, 9 + i),
        ));
      }
      await insertAppointment(buildAppointment(
        id: 'appt-survivor',
        providerId: 'will-live',
      ));

      // Sanity: rows wired to their providers.
      expect(await db.select(db.appointmentsTable).get(), hasLength(4));

      await (db.delete(db.providersTable)
            ..where((t) => t.id.equals('will-die')))
          .go();

      // The provider row is gone.
      final List<ProvidersTableData> provs =
          await db.select(db.providersTable).get();
      expect(provs.map((ProvidersTableData r) => r.id).toList(),
          <String>['will-live']);

      // Its appointments cascaded — only the survivor's remains.
      final List<AppointmentsTableData> appts =
          await db.select(db.appointmentsTable).get();
      expect(appts.map((AppointmentsTableData r) => r.id).toList(),
          <String>['appt-survivor']);

      // And cross-check the orphan count via direct scan, so a stale
      // ORDER BY can't hide a stuck row.
      final int orphanAppts = appts
          .where((AppointmentsTableData r) => r.providerId == 'will-die')
          .length;
      expect(orphanAppts, 0,
          reason: 'ON DELETE CASCADE must remove every appointment row');
    });

    test('FK pragma is on — insert with an unknown providerId fails',
        () async {
      // The cascade test above only proves the FK action fires; this one
      // pins that the constraint is even being enforced. Without
      // `PRAGMA foreign_keys = ON`, the insert would silently succeed.
      expect(
        () => insertAppointment(buildAppointment(
            id: 'orphan-appt', providerId: 'never-existed')),
        throwsA(isA<Exception>()),
      );
    });

    // ---- wipeAll() includes the new tables (Phase 12.5) -----------------

    test('wipeAll() truncates providers + appointments', () async {
      await insertProvider(buildProvider());
      await insertAppointment(
          buildAppointment(id: 'appt-1', providerId: 'prov-001'));

      await db.wipeAll();

      expect(await db.select(db.providersTable).get(), isEmpty);
      expect(await db.select(db.appointmentsTable).get(), isEmpty);
    });
  });
}
