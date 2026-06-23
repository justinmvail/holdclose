import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/services/pattern_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed wall-clock anchor for every fixture in this file. Pinned at
/// midday so "now − 7 days" subtractions can't roll into a daylight-saving
/// boundary on the host.
final DateTime _now = DateTime(2026, 5, 29, 12);

/// Build a free-text journal entry. The decoder-era fixtures keyed off a
/// structured [Behavior]; entries are now free text, so the falls rule
/// scans [situationText] / [attemptsText] / [notes] for "fall" / "fell".
JournalEntry _entry({
  required String id,
  required DateTime createdAt,
  String? situationText,
  String? attemptsText,
  String? notes,
}) {
  return JournalEntry(
    id: id,
    createdAt: createdAt,
    situationText: situationText,
    attemptsText: attemptsText,
    notes: notes,
  );
}

/// Convenience: `_now - days * 24h - hours`. Keeps the fixtures readable
/// — "3 days ago at noon-minus-one-hour" vs. raw `DateTime` arithmetic.
DateTime _ago({int days = 0, int hours = 0}) =>
    _now.subtract(Duration(days: days, hours: hours));

void main() {
  group('PatternDetector — falls rule', () {
    test('3 falls within 7 days fires the falls alert', () {
      // One "fall" token in each of the three scanned fields — situation,
      // attempts, notes — to prove the scan covers all three.
      final List<JournalEntry> entries = <JournalEntry>[
        _entry(
          id: 'f1',
          createdAt: _ago(days: 1),
          attemptsText: 'Make sure the rug is taped down so she '
              "doesn't fall on the way to the bathroom.",
        ),
        _entry(
          id: 'f2',
          createdAt: _ago(days: 3),
          situationText: 'She fell while reaching for the phone.',
        ),
        _entry(
          id: 'f3',
          createdAt: _ago(days: 5),
          notes: 'Another FALL near the kitchen step.',
        ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts, hasLength(1));
      expect(alerts.single.kind, 'falls_3plus_7d');
      expect(alerts.single.severity, PatternSeverity.warning);
      expect(alerts.single.text, contains('3+ falls'));
    });

    test('2 falls within 7 days is below threshold (no alert)', () {
      final List<JournalEntry> entries = <JournalEntry>[
        _entry(id: 'f1', createdAt: _ago(days: 1), notes: 'she fell'),
        _entry(id: 'f2', createdAt: _ago(days: 3), notes: 'fell again'),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts, isEmpty);
    });

    test('falls outside the 7-day window do not count', () {
      final List<JournalEntry> entries = <JournalEntry>[
        _entry(id: 'old1', createdAt: _ago(days: 8), notes: 'fell'),
        _entry(id: 'old2', createdAt: _ago(days: 10), notes: 'fell'),
        // One recent fall — below threshold.
        _entry(id: 'recent', createdAt: _ago(days: 2), notes: 'she fell'),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts.where((PatternAlert a) => a.kind == 'falls_3plus_7d'),
          isEmpty);
    });

    test('entries without "fall" / "fell" text are not counted', () {
      final List<JournalEntry> entries = <JournalEntry>[
        for (int i = 0; i < 4; i++)
          _entry(
            id: 'no-fall-$i',
            createdAt: _ago(days: i + 1),
            notes: 'Calm conversation. No incident.',
          ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts, isEmpty);
    });

    test('returned alert list is unmodifiable', () {
      final List<JournalEntry> entries = <JournalEntry>[
        for (int i = 0; i < 3; i++)
          _entry(id: 'f$i', createdAt: _ago(days: i), notes: 'she fell'),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts, hasLength(1));
      // Callers can't accidentally mutate the alert set the journal screen
      // renders.
      expect(() => alerts.add(alerts.first), throwsUnsupportedError);
    });

    test('empty input returns no alerts', () {
      final List<PatternAlert> alerts = const PatternDetector()
          .detect(const <JournalEntry>[], now: _now);
      expect(alerts, isEmpty);
    });
  });

  group('PatternAlert', () {
    test('value equality holds across identical fields', () {
      const PatternAlert a = PatternAlert(
        kind: 'falls_3plus_7d',
        text: 'msg',
        severity: PatternSeverity.warning,
      );
      const PatternAlert b = PatternAlert(
        kind: 'falls_3plus_7d',
        text: 'msg',
        severity: PatternSeverity.warning,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('value inequality on any differing field', () {
      const PatternAlert base = PatternAlert(
        kind: 'k',
        text: 't',
        severity: PatternSeverity.info,
      );
      expect(
        base,
        isNot(equals(const PatternAlert(
          kind: 'k2',
          text: 't',
          severity: PatternSeverity.info,
        ))),
      );
      expect(
        base,
        isNot(equals(const PatternAlert(
          kind: 'k',
          text: 't2',
          severity: PatternSeverity.info,
        ))),
      );
      expect(
        base,
        isNot(equals(const PatternAlert(
          kind: 'k',
          text: 't',
          severity: PatternSeverity.warning,
        ))),
      );
    });
  });
}
