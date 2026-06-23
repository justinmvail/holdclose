import 'package:holdclose/models/journal_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  JournalEntry buildEntry({
    String id = 'entry-001',
    String? situationText = 'Restless as the light faded.',
    String? attemptsText = 'Dimmed the lamps and put on the playlist.',
    String? notes,
    String? voiceNotePath,
    String? photoPath,
    DateTime? occurredAt,
  }) =>
      JournalEntry(
        id: id,
        createdAt: DateTime.utc(2026, 5, 29, 19, 42, 30),
        occurredAt: occurredAt ?? DateTime.utc(2026, 5, 29, 19, 42),
        situationText: situationText,
        attemptsText: attemptsText,
        notes: notes,
        voiceNotePath: voiceNotePath,
        photoPath: photoPath,
      );

  group('JournalEntry construction', () {
    test('default constructor holds the free-text fields', () {
      final JournalEntry entry = buildEntry(
        notes: 'Settled within ten minutes.',
      );
      expect(entry.id, 'entry-001');
      expect(entry.situationText, 'Restless as the light faded.');
      expect(entry.attemptsText, 'Dimmed the lamps and put on the playlist.');
      expect(entry.notes, 'Settled within ten minutes.');
      expect(entry.voiceNotePath, isNull);
      expect(entry.photoPath, isNull);
    });

    test('a bare timestamped entry (no body) is valid', () {
      final JournalEntry entry = JournalEntry(
        id: 'bare',
        createdAt: DateTime.utc(2026, 5, 29, 19, 42, 30),
      );
      expect(entry.situationText, isNull);
      expect(entry.attemptsText, isNull);
      expect(entry.notes, isNull);
      expect(entry.occurredAt, isNull);
    });
  });

  group('JournalEntry.wizard factory', () {
    test('builds a caregiver-authored entry from the wizard fields', () {
      final JournalEntry entry = JournalEntry.wizard(
        id: 'wiz-1',
        createdAt: DateTime.utc(2026, 5, 29, 19, 42, 30),
        occurredAt: DateTime.utc(2026, 5, 29, 17, 0),
        situationText: 'Unsettled in the evening.',
        attemptsText: 'Took a slow walk for tea.',
        notes: 'Came around after a snack.',
      );
      expect(entry.id, 'wiz-1');
      expect(entry.occurredAt, DateTime.utc(2026, 5, 29, 17, 0));
      expect(entry.situationText, 'Unsettled in the evening.');
      expect(entry.attemptsText, 'Took a slow walk for tea.');
      expect(entry.notes, 'Came around after a snack.');
      // The wizard factory never sets attachment paths.
      expect(entry.voiceNotePath, isNull);
      expect(entry.photoPath, isNull);
    });
  });

  group('JournalEntry JSON round-trip', () {
    test('round-trips a minimal entry', () {
      final JournalEntry entry = buildEntry();
      expect(JournalEntry.fromJson(entry.toJson()), equals(entry));
    });

    test('round-trips with notes + voice note + photo attachments', () {
      final JournalEntry entry = buildEntry(
        notes: 'Dimming worked instantly.',
        voiceNotePath: 'assets/seed/sample-voice-1.m4a',
        photoPath: 'assets/seed/sample-photo-1.jpg',
      );
      expect(JournalEntry.fromJson(entry.toJson()), equals(entry));
    });

    test('round-trips an entry with no occurredAt', () {
      final JournalEntry entry = JournalEntry(
        id: 'no-occurred',
        createdAt: DateTime.utc(2026, 5, 29, 19, 42, 30),
        situationText: 'Just a quick note.',
      );
      expect(JournalEntry.fromJson(entry.toJson()), equals(entry));
    });

    test('legacy decoder-era JSON deserializes (extra keys ignored)', () {
      // Older rows persisted by the (removed) behavior decoder carried
      // extra `behavior` / `triage` / `result` / `outcome` keys; fromJson
      // must ignore them and yield a clean timestamped entry.
      final Map<String, dynamic> legacy = <String, dynamic>{
        'id': 'legacy-001',
        'createdAt': DateTime.utc(2026, 5, 29, 19, 42, 30).toIso8601String(),
        'notes': 'Dimming worked.',
        'behavior': <String, dynamic>{'id': 'sundowning', 'label': 'Sundowning'},
        'triage': <String, dynamic>{'when': 'lateAfternoonEvening'},
        'result': <String, dynamic>{
          'say': <String>['That sounds hard.'],
          'tweak': <String>['Dim the lights.'],
          'dont_say': <String>['Do not argue.'],
        },
        'outcome': 'positive',
        'attempt': 1,
      };

      final JournalEntry entry = JournalEntry.fromJson(legacy);
      expect(entry.id, 'legacy-001');
      expect(entry.createdAt, DateTime.utc(2026, 5, 29, 19, 42, 30));
      expect(entry.notes, 'Dimming worked.');
      // No body fields were present in the legacy shape.
      expect(entry.situationText, isNull);
      expect(entry.attemptsText, isNull);
    });
  });
}
