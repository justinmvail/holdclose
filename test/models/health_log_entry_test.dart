import 'package:careblazers/models/health_log_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---- HealthLogKind enum -----------------------------------------------

  group('HealthLogKind', () {
    test('exposes the three spec values', () {
      expect(HealthLogKind.values, hasLength(3));
      expect(
        HealthLogKind.values,
        containsAll(<HealthLogKind>[
          HealthLogKind.vitals,
          HealthLogKind.symptom,
          HealthLogKind.note,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final HealthLogKind kind in HealthLogKind.values) {
        final HealthLogEntry e = HealthLogEntry(
          id: 'hl-${kind.name}',
          patientId: 'mary',
          recordedAt: DateTime.utc(2026, 6, 1, 9),
          kind: kind,
        );
        expect(e.toJson()['kind'], kind.name);
      }
    });
  });

  // ---- fromJson / toJson round-trip -------------------------------------

  group('HealthLogEntry round-trip', () {
    test('a full vitals row survives toJson -> fromJson unchanged', () {
      final HealthLogEntry vitals = HealthLogEntry(
        id: 'hl-1',
        patientId: 'mary',
        recordedAt: DateTime.utc(2026, 6, 1, 8, 30),
        kind: HealthLogKind.vitals,
        systolic: 128,
        diastolic: 82,
        heartRate: 74,
        temperatureF: 98.6,
        notes: 'Resting, post-breakfast',
      );

      final HealthLogEntry restored =
          HealthLogEntry.fromJson(vitals.toJson());

      expect(restored, equals(vitals));
      expect(restored.temperatureF, 98.6);
      expect(restored.severity, isNull);
    });

    test('a symptom row carries its 1-5 severity through the round-trip', () {
      final HealthLogEntry symptom = HealthLogEntry(
        id: 'hl-2',
        patientId: 'mary',
        recordedAt: DateTime.utc(2026, 6, 1, 16, 45),
        kind: HealthLogKind.symptom,
        severity: 4,
        notes: 'Increased afternoon agitation',
      );

      final HealthLogEntry restored =
          HealthLogEntry.fromJson(symptom.toJson());

      expect(restored, equals(symptom));
      expect(restored.severity, 4);
      expect(restored.systolic, isNull);
    });

    test('a note row leaves every measurement field null', () {
      final HealthLogEntry note = HealthLogEntry(
        id: 'hl-3',
        patientId: 'mary',
        recordedAt: DateTime.utc(2026, 6, 1, 20),
        kind: HealthLogKind.note,
        notes: 'Slept well after dimming the lights early.',
      );

      final Map<String, dynamic> json = note.toJson();
      final HealthLogEntry restored = HealthLogEntry.fromJson(json);

      expect(restored, equals(note));
      expect(restored.severity, isNull);
      expect(restored.systolic, isNull);
      expect(restored.diastolic, isNull);
      expect(restored.heartRate, isNull);
      expect(restored.temperatureF, isNull);
    });

    test('recordedAt preserves its instant across the round-trip', () {
      final DateTime when = DateTime.utc(2026, 6, 1, 23, 59, 30);
      final HealthLogEntry e = HealthLogEntry(
        id: 'hl-4',
        patientId: 'mary',
        recordedAt: when,
        kind: HealthLogKind.note,
      );

      final HealthLogEntry restored = HealthLogEntry.fromJson(e.toJson());
      expect(restored.recordedAt.toUtc(), when);
    });
  });
}
