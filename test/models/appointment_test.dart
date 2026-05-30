import 'package:careblazers/models/appointment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---- ProviderRole enum -------------------------------------------------

  group('ProviderRole', () {
    test('exposes the four spec values', () {
      expect(ProviderRole.values, hasLength(4));
      expect(
        ProviderRole.values,
        containsAll(<ProviderRole>[
          ProviderRole.doctor,
          ProviderRole.neurologist,
          ProviderRole.socialWorker,
          ProviderRole.other,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final ProviderRole role in ProviderRole.values) {
        final Provider p = Provider(
          id: 'prov-${role.name}',
          name: 'Test',
          role: role,
          phone: '555-0100',
          address: '1 Main St',
        );
        expect(p.toJson()['role'], role.name);
      }
    });
  });

  // ---- AppointmentStatus enum -------------------------------------------

  group('AppointmentStatus', () {
    test('exposes the three spec values', () {
      expect(AppointmentStatus.values, hasLength(3));
      expect(
        AppointmentStatus.values,
        containsAll(<AppointmentStatus>[
          AppointmentStatus.upcoming,
          AppointmentStatus.completed,
          AppointmentStatus.canceled,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final AppointmentStatus status in AppointmentStatus.values) {
        final Appointment a = Appointment(
          id: 'appt-${status.name}',
          providerId: 'prov-001',
          startsAt: DateTime.utc(2026, 6, 1, 9),
          durationMinutes: 30,
          location: 'Marin General Hospital',
          agenda: const <String>[],
          status: status,
        );
        expect(a.toJson()['status'], status.name);
      }
    });
  });

  // ---- Provider JSON round-trip -----------------------------------------

  group('Provider JSON round-trip', () {
    test('round-trips with every optional field populated', () {
      const Provider p = Provider(
        id: 'prov-001',
        name: 'Dr. Ortega',
        role: ProviderRole.neurologist,
        phone: '(415) 555-0188',
        address: '250 Bon Air Rd, Greenbrae CA',
        notes: 'Park in the side lot — front lot fills by 9am.',
      );
      expect(Provider.fromJson(p.toJson()), equals(p));
    });

    test('round-trips with notes null', () {
      const Provider p = Provider(
        id: 'prov-002',
        name: 'Sandra Lee, LCSW',
        role: ProviderRole.socialWorker,
        phone: '(415) 555-0144',
        address: '',
      );
      final Provider parsed = Provider.fromJson(p.toJson());
      expect(parsed.notes, isNull);
      expect(parsed, equals(p));
    });

    test('round-trips every role variant', () {
      for (final ProviderRole role in ProviderRole.values) {
        final Provider p = Provider(
          id: 'prov-${role.name}',
          name: 'Test',
          role: role,
          phone: '555-0100',
          address: '1 Main St',
        );
        expect(Provider.fromJson(p.toJson()), equals(p));
      }
    });
  });

  // ---- Appointment JSON round-trip --------------------------------------

  group('Appointment JSON round-trip', () {
    test('round-trips an upcoming appointment with a populated agenda', () {
      final Appointment a = Appointment(
        id: 'appt-001',
        providerId: 'prov-001',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        durationMinutes: 45,
        location: 'Marin General — Neurology, 2nd floor',
        agenda: const <String>[
          'Ask about evening agitation pattern',
          'Refill Donepezil',
          'Review Memantine side effects',
        ],
        status: AppointmentStatus.upcoming,
      );
      expect(Appointment.fromJson(a.toJson()), equals(a));
    });

    test('round-trips a completed appointment with post-visit notes', () {
      final Appointment a = Appointment(
        id: 'appt-002',
        providerId: 'prov-001',
        startsAt: DateTime.utc(2026, 5, 20, 10),
        durationMinutes: 30,
        location: 'Telehealth',
        agenda: const <String>['Discuss sundowning'],
        status: AppointmentStatus.completed,
        notes: 'Dr. suggested trazodone trial — pharmacy will call.',
      );
      expect(Appointment.fromJson(a.toJson()), equals(a));
    });

    test('round-trips a canceled appointment with notes null', () {
      final Appointment a = Appointment(
        id: 'appt-003',
        providerId: 'prov-002',
        startsAt: DateTime.utc(2026, 6, 1, 11),
        durationMinutes: 60,
        location: 'Home visit',
        agenda: const <String>[],
        status: AppointmentStatus.canceled,
      );
      final Appointment parsed = Appointment.fromJson(a.toJson());
      expect(parsed.notes, isNull);
      expect(parsed.agenda, isEmpty);
      expect(parsed.status, AppointmentStatus.canceled);
      expect(parsed, equals(a));
    });

    test('persists startsAt as an ISO-8601 string in the JSON shape', () {
      final Appointment a = Appointment(
        id: 'appt-004',
        providerId: 'prov-001',
        startsAt: DateTime.utc(2026, 6, 15, 14, 30),
        durationMinutes: 30,
        location: 'Telehealth',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      );
      final Map<String, dynamic> json = a.toJson();
      expect(json['startsAt'], isA<String>());
      expect(json['startsAt'], contains('2026-06-15'));
    });

    test('agenda round-trips an empty list as an empty JSON array', () {
      final Appointment a = Appointment(
        id: 'appt-005',
        providerId: 'prov-001',
        startsAt: DateTime.utc(2026, 6, 15, 9),
        durationMinutes: 30,
        location: 'Telehealth',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      );
      expect(a.toJson()['agenda'], isEmpty);
      expect(Appointment.fromJson(a.toJson()), equals(a));
    });
  });
}
