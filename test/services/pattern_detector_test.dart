import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/services/pattern_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed wall-clock anchor for every fixture in this file. Pinned at
/// midday so "now − 7 days" / "now − 14 days" subtractions can't roll
/// into a daylight-saving boundary on the host.
final DateTime _now = DateTime(2026, 5, 29, 12);

const Behavior _sundowning =
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');
const Behavior _accusing =
    Behavior(id: 'accusing', label: 'Accusing me', glyph: '💸');
const Behavior _wandering =
    Behavior(id: 'wandering', label: 'Wandering / pacing', glyph: '🚶');
const Behavior _upset =
    Behavior(id: 'upset', label: 'Upset / crying', glyph: '💔');
const Behavior _wantsHome =
    Behavior(id: 'wants_home', label: '"I want to go home"', glyph: '🏠');
const Behavior _refusing =
    Behavior(id: 'refusing_care', label: 'Refusing care', glyph: '🚪');

const TriageAnswers _triage = TriageAnswers(
  when: TriageWhen.lateAfternoonEvening,
  whatChanged: TriageWhatChanged.nothing,
  whatTried: TriageWhatTried.talked,
);

JournalEntry _entry({
  required String id,
  required Behavior behavior,
  required DateTime createdAt,
  List<String> tweak = const <String>['dim the lights'],
  String? notes,
}) {
  return JournalEntry(
    id: id,
    behavior: behavior,
    triage: _triage,
    result: DecoderResult(
      say: const <String>['line 1'],
      tweak: tweak,
      dontSay: const <String>["don't argue"],
      generatedAt: createdAt,
    ),
    outcome: JournalOutcome.positive,
    attempt: 0,
    createdAt: createdAt,
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
      final List<JournalEntry> entries = <JournalEntry>[
        _entry(
          id: 'f1',
          behavior: _upset,
          createdAt: _ago(days: 1),
          tweak: const <String>['Make sure the rug is taped down so she '
              "doesn't fall on the way to the bathroom."],
        ),
        _entry(
          id: 'f2',
          behavior: _wandering,
          createdAt: _ago(days: 3),
          notes: 'She fell while reaching for the phone.',
        ),
        _entry(
          id: 'f3',
          behavior: _upset,
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

    test('falls outside the 7-day window do not count', () {
      final List<JournalEntry> entries = <JournalEntry>[
        _entry(
          id: 'old1',
          behavior: _upset,
          createdAt: _ago(days: 8),
          notes: 'fell',
        ),
        _entry(
          id: 'old2',
          behavior: _upset,
          createdAt: _ago(days: 10),
          notes: 'fell',
        ),
        // One recent fall — below threshold.
        _entry(
          id: 'recent',
          behavior: _upset,
          createdAt: _ago(days: 2),
          notes: 'she fell',
        ),
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
            behavior: _upset,
            createdAt: _ago(days: i + 1),
            tweak: const <String>['dim the lights'],
            notes: 'Calm conversation. No incident.',
          ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts, isEmpty);
    });
  });

  group('PatternDetector — sundowning rule', () {
    test('5 sundowning entries within 7 days fires the sundowning alert', () {
      final List<JournalEntry> entries = <JournalEntry>[
        for (int i = 0; i < 5; i++)
          _entry(
            id: 's$i',
            behavior: _sundowning,
            createdAt: _ago(days: i, hours: i),
          ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts, hasLength(1));
      expect(alerts.single.kind, 'sundowning_5plus_7d');
      expect(alerts.single.severity, PatternSeverity.warning);
      expect(alerts.single.text, contains('Sundowning'));
    });

    test('4 sundowning entries within 7 days does not fire', () {
      final List<JournalEntry> entries = <JournalEntry>[
        for (int i = 0; i < 4; i++)
          _entry(
            id: 's$i',
            behavior: _sundowning,
            createdAt: _ago(days: i),
          ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts, isEmpty);
    });

    test('sundowning entries older than 7 days do not count', () {
      final List<JournalEntry> entries = <JournalEntry>[
        // 5 entries, but spread across 14 days — only 2 fall inside the
        // 7-day window.
        for (int i = 0; i < 5; i++)
          _entry(
            id: 's$i',
            behavior: _sundowning,
            createdAt: _ago(days: i * 3),
          ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts.where((PatternAlert a) => a.kind == 'sundowning_5plus_7d'),
          isEmpty);
    });
  });

  group('PatternDetector — new behaviors rule', () {
    test('3 distinct new behaviors within 14 days fires the alert', () {
      // Three behaviors, each first appearing inside the 14-day window.
      final List<JournalEntry> entries = <JournalEntry>[
        _entry(
          id: 'n1',
          behavior: _accusing,
          createdAt: _ago(days: 2),
        ),
        _entry(
          id: 'n2',
          behavior: _wandering,
          createdAt: _ago(days: 5),
        ),
        _entry(
          id: 'n3',
          behavior: _wantsHome,
          createdAt: _ago(days: 10),
        ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(
        alerts.where((PatternAlert a) => a.kind == 'new_behaviors_3plus_14d'),
        hasLength(1),
      );
    });

    test('behaviors whose first appearance predates 14 days are not "new"',
        () {
      final List<JournalEntry> entries = <JournalEntry>[
        // Sundowning's first appearance is 20 days ago — NOT new even
        // though it also appears within the window.
        _entry(
          id: 'old',
          behavior: _sundowning,
          createdAt: _ago(days: 20),
        ),
        _entry(
          id: 'recent',
          behavior: _sundowning,
          createdAt: _ago(days: 2),
        ),
        // Two genuinely new behaviors — below the 3-distinct threshold.
        _entry(
          id: 'n1',
          behavior: _accusing,
          createdAt: _ago(days: 4),
        ),
        _entry(
          id: 'n2',
          behavior: _wandering,
          createdAt: _ago(days: 6),
        ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(
        alerts.where((PatternAlert a) => a.kind == 'new_behaviors_3plus_14d'),
        isEmpty,
      );
    });

    test('the same new behavior repeated does not double-count', () {
      final List<JournalEntry> entries = <JournalEntry>[
        for (int i = 0; i < 6; i++)
          _entry(
            id: 'n$i',
            behavior: _accusing,
            createdAt: _ago(days: i),
          ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      // Only 1 distinct new behavior — below the 3-distinct threshold.
      expect(
        alerts.where((PatternAlert a) => a.kind == 'new_behaviors_3plus_14d'),
        isEmpty,
      );
    });
  });

  group('PatternDetector — mixed and below-threshold fixtures', () {
    test('mixed fixture triggers multiple alerts in stable order', () {
      // Falls rule: 3 entries within 7 days mentioning "fall" / "fell".
      // Sundowning rule: 5 sundowning entries within 7 days.
      // New behaviors rule: accusing + wandering + wants_home first
      //   appear within 14 days.
      final List<JournalEntry> entries = <JournalEntry>[
        // Five sundowning entries within 7 days — last one also
        // mentions a fall.
        for (int i = 0; i < 5; i++)
          _entry(
            id: 'sd$i',
            behavior: _sundowning,
            createdAt: _ago(days: i, hours: 1),
            notes: i == 0 ? 'she fell on the way to the couch' : null,
          ),
        // Two more fall mentions on different days.
        _entry(
          id: 'fall-1',
          behavior: _refusing,
          createdAt: _ago(days: 2),
          notes: 'Nearly fell when she stood up too fast.',
        ),
        _entry(
          id: 'fall-2',
          behavior: _upset,
          createdAt: _ago(days: 4),
          tweak: const <String>['Move the chair so she does not fall '
              'reaching for the lamp.'],
        ),
        // Three genuinely new behaviors first seen within 14 days.
        _entry(
          id: 'new-accusing',
          behavior: _accusing,
          createdAt: _ago(days: 3),
        ),
        _entry(
          id: 'new-wandering',
          behavior: _wandering,
          createdAt: _ago(days: 8),
        ),
        _entry(
          id: 'new-wants-home',
          behavior: _wantsHome,
          createdAt: _ago(days: 12),
        ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts.map((PatternAlert a) => a.kind).toList(), <String>[
        'falls_3plus_7d',
        'sundowning_5plus_7d',
        'new_behaviors_3plus_14d',
      ]);
      // Returned list is unmodifiable so callers can't accidentally
      // mutate the alert set the journal screen renders.
      expect(() => alerts.add(alerts.first), throwsUnsupportedError);
    });

    test('below-threshold fixture returns an empty list', () {
      // 4 sundowning entries within 7 days (rule needs 5), two
      // mentioning "fell" (rule needs 3), and just the one distinct
      // behavior id (rule needs 3) — none of the three rules cross
      // their threshold.
      final List<JournalEntry> entries = <JournalEntry>[
        _entry(
          id: 'a',
          behavior: _sundowning,
          createdAt: _ago(days: 1),
        ),
        _entry(
          id: 'b',
          behavior: _sundowning,
          createdAt: _ago(days: 3),
          notes: 'she fell while standing up',
        ),
        _entry(
          id: 'c',
          behavior: _sundowning,
          createdAt: _ago(days: 5),
          notes: 'another fall near the bedroom',
        ),
        _entry(
          id: 'd',
          behavior: _sundowning,
          createdAt: _ago(days: 6),
        ),
      ];

      final List<PatternAlert> alerts =
          const PatternDetector().detect(entries, now: _now);

      expect(alerts, isEmpty);
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
