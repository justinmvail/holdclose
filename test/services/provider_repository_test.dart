import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Provider _provider({
  required String id,
  String name = 'Dr. Ortega',
  ProviderRole role = ProviderRole.neurologist,
  String phone = '(415) 555-0188',
  String address = '250 Bon Air Rd, Greenbrae CA',
  String? notes,
}) =>
    Provider(
      id: id,
      name: name,
      role: role,
      phone: phone,
      address: address,
      notes: notes,
    );

void main() {
  group('ProviderRepository — TASKS.md Phase 12.7', () {
    late HoldcloseDatabase db;
    late ProviderRepository repo;

    setUp(() {
      db = HoldcloseDatabase(NativeDatabase.memory());
      repo = ProviderRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('upsertProvider + getProvider round-trips the model', () async {
      final Provider p = _provider(
        id: 'prov-1',
        notes: 'Use side entrance after 4pm.',
      );
      await repo.upsertProvider(p);

      final Provider? loaded = await repo.getProvider('prov-1');
      expect(loaded, equals(p));
    });

    test('getProvider returns null for an unknown id', () async {
      expect(await repo.getProvider('never-existed'), isNull);
    });

    test('upsertProvider overwrites an existing row', () async {
      await repo.upsertProvider(_provider(id: 'prov-1'));
      final Provider edited = _provider(
        id: 'prov-1',
        phone: '(415) 555-9999',
        notes: 'New parking instructions.',
      );
      await repo.upsertProvider(edited);

      final Provider? loaded = await repo.getProvider('prov-1');
      expect(loaded, equals(edited));
      expect(loaded?.phone, '(415) 555-9999');
      expect(loaded?.notes, 'New parking instructions.');
    });

    test('listProviders sorts alphabetically by name', () async {
      await repo.upsertProvider(_provider(id: 'prov-z', name: 'Dr. Zhao'));
      await repo.upsertProvider(_provider(id: 'prov-a', name: 'Dr. Adler'));
      await repo.upsertProvider(_provider(id: 'prov-m', name: 'Dr. Marquez'));

      final List<Provider> rows = await repo.listProviders();
      expect(rows.map((Provider p) => p.name).toList(),
          <String>['Dr. Adler', 'Dr. Marquez', 'Dr. Zhao']);
    });

    test('listProviders returns an empty list when none are stored', () async {
      expect(await repo.listProviders(), isEmpty);
    });

    test('deleteProvider drops the row', () async {
      await repo.upsertProvider(_provider(id: 'prov-1'));
      await repo.deleteProvider('prov-1');

      expect(await repo.getProvider('prov-1'), isNull);
      expect(await repo.listProviders(), isEmpty);
    });

    test(
        'deleteProvider cascades through its appointments via the FK',
        () async {
      // Cascade is only honored when PRAGMA foreign_keys = ON, which
      // HoldcloseDatabase.beforeOpen turns on for every connection.
      await repo.upsertProvider(_provider(id: 'prov-1'));
      final AppointmentRepository appts = AppointmentRepository(db);
      await appts.upsertAppointment(Appointment(
        id: 'appt-1',
        providerId: 'prov-1',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        durationMinutes: 30,
        location: 'Marin General — Neurology',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      ));

      await repo.deleteProvider('prov-1');

      expect(await appts.getAppointment('appt-1'), isNull,
          reason: 'CASCADE should wipe child appointments');
      expect(await repo.getProvider('prov-1'), isNull);
    });

    test('notes round-trips as null when stored as null', () async {
      await repo.upsertProvider(_provider(id: 'prov-1'));
      final Provider? loaded = await repo.getProvider('prov-1');
      expect(loaded?.notes, isNull);
    });
  });
}
