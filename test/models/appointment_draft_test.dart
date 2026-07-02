import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/appointment.dart' show ProviderRole;
import 'package:holdclose/models/appointment_draft.dart';

/// Unit coverage for the transient [AppointmentDraft] the appointment scan
/// produces — tolerant parsing + date/time resolution, degrading to null
/// rather than guessing.
void main() {
  group('parseClockTime', () {
    test('parses 12-hour times', () {
      expect(parseClockTime('2:30 PM'), const TimeOfDay(hour: 14, minute: 30));
      expect(parseClockTime('9 AM'), const TimeOfDay(hour: 9, minute: 0));
      expect(parseClockTime('12:00 AM'), const TimeOfDay(hour: 0, minute: 0));
      expect(parseClockTime('12:00 PM'), const TimeOfDay(hour: 12, minute: 0));
    });

    test('parses 24-hour times', () {
      expect(parseClockTime('14:30'), const TimeOfDay(hour: 14, minute: 30));
    });

    test('null on garbage or missing', () {
      expect(parseClockTime(null), isNull);
      expect(parseClockTime('sometime'), isNull);
      expect(parseClockTime('25:00'), isNull);
    });
  });

  group('AppointmentDraft.fromModelJson', () {
    test('parses a full object', () {
      final AppointmentDraft d = AppointmentDraft.fromModelJson(
        <String, dynamic>{
          'providerName': 'Dr. Berger',
          'providerRole': 'neurologist',
          'providerPhone': '843-767-4500',
          'providerAddress': '2135 Ashley Phosphate Rd',
          'location': 'Suite 200',
          'date': '6/15/2026',
          'time': '2:30 PM',
          'duration': '30 minutes',
          'reason': 'Follow-up',
          'notes': 'Arrive early',
        },
      );
      expect(d.providerName, 'Dr. Berger');
      expect(d.providerRole, ProviderRole.neurologist);
      expect(d.providerPhone, '843-767-4500');
      expect(d.location, 'Suite 200');
      expect(d.durationMinutes, 30);
      expect(d.reason, 'Follow-up');
      expect(d.isEmpty, isFalse);
      expect(d.startsAt, DateTime(2026, 6, 15, 14, 30));
    });

    test('accepts synonym keys', () {
      final AppointmentDraft d = AppointmentDraft.fromModelJson(
        <String, dynamic>{'provider': 'Dr. Kim', 'phone': '555-1212'},
      );
      expect(d.providerName, 'Dr. Kim');
      expect(d.providerPhone, '555-1212');
    });

    test('startsAt falls back to 9am when only the date is legible', () {
      final AppointmentDraft d =
          AppointmentDraft.fromModelJson(<String, dynamic>{'date': '6/15/2026'});
      expect(d.startsAt, DateTime(2026, 6, 15, 9, 0));
    });

    test('startsAt null when the date is unreadable; isEmpty when blank', () {
      expect(
        AppointmentDraft.fromModelJson(
            <String, dynamic>{'time': '2:30 PM'}).startsAt,
        isNull,
      );
      expect(AppointmentDraft.fromModelJson(<String, dynamic>{}).isEmpty, isTrue);
    });
  });

  group('AppointmentDraft.parseRole', () {
    test('maps role words', () {
      expect(AppointmentDraft.parseRole('Neurology'), ProviderRole.neurologist);
      expect(AppointmentDraft.parseRole('social worker'),
          ProviderRole.socialWorker);
      expect(AppointmentDraft.parseRole('physician'), ProviderRole.doctor);
      expect(AppointmentDraft.parseRole('acupuncturist'), ProviderRole.other);
      expect(AppointmentDraft.parseRole(null), isNull);
    });
  });
}
