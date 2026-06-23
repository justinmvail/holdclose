import 'dart:typed_data';

import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/models/patient.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/services/pdf_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

/// PdfExporter coverage. The rendered PDF stores its text in font-encoded
/// content streams (not plain latin1), so we don't grep the bytes — we
/// assert the behaviors that ARE observable independent of glyph encoding:
/// valid `%PDF` output, no-throw across input variants, the medical-advice
/// footer CONSTANT (a non-negotiable guardrail), and — via byte-length
/// deltas — that a populated entry body enlarges the output and that an
/// OUT-of-range entry doesn't change it while an IN-range one does (the
/// date filter runs before rendering).
void main() {
  final DateTime clock0 = DateTime(2026, 6, 11, 10);
  PdfExporter exporter() => PdfExporter(compress: false, clock: () => clock0);

  bool isPdf(Uint8List bytes) =>
      bytes.length > 4 &&
      bytes[0] == 0x25 && // %
      bytes[1] == 0x50 && // P
      bytes[2] == 0x44 && // D
      bytes[3] == 0x46; // F

  /// Free-text journal entry (the post-decoder model). [at] doubles as the
  /// created/occurred timestamp.
  JournalEntry entry(
    String id,
    DateTime at, {
    String? situationText,
    String? attemptsText,
    String? notes,
  }) =>
      JournalEntry(
        id: id,
        createdAt: at,
        occurredAt: at,
        situationText: situationText,
        attemptsText: attemptsText,
        notes: notes,
      );

  final DateRange june = DateRange(
    start: DateTime(2026, 6, 1),
    end: DateTime(2026, 6, 30),
  );

  group('DateRange.contains', () {
    test('is start-inclusive, end-exclusive', () {
      final DateRange r = DateRange(
        start: DateTime(2026, 6, 1),
        end: DateTime(2026, 6, 8),
      );
      expect(r.contains(DateTime(2026, 6, 1)), isTrue, reason: 'start incl.');
      expect(r.contains(DateTime(2026, 6, 7, 23, 59)), isTrue);
      expect(r.contains(DateTime(2026, 6, 8)), isFalse, reason: 'end excl.');
      expect(r.contains(DateTime(2026, 5, 31, 23, 59)), isFalse);
    });
  });

  group('footer disclaimer (guardrail copy)', () {
    test('states it is not medical advice', () {
      expect(
        PdfExporter.footerDisclaimer.toLowerCase(),
        contains('not a substitute for medical advice'),
      );
    });
  });

  group('exportRange — doctor-visit packet', () {
    test('produces a valid PDF for a populated range (no throw)', () async {
      final Uint8List bytes = await exporter().exportRange(
        entries: <JournalEntry>[
          entry('j1', DateTime(2026, 6, 5, 18),
              situationText: 'Restless in the late afternoon.'),
        ],
        patient: maryHenderson(),
        range: june,
      );
      expect(isPdf(bytes), isTrue);
    });

    test('a populated free-text entry body enlarges the packet', () async {
      final PdfExporter exp = exporter();
      final Patient mary = maryHenderson();
      // Same id + timestamp so only the body fields differ between the two
      // exports — a bigger output proves the situation/attempts/notes lines
      // (the decoder-era "Behavior summary" + "What worked:" are gone) are
      // actually rendered into the entry block.
      final Uint8List bare = await exp.exportRange(
        entries: <JournalEntry>[entry('j1', DateTime(2026, 6, 5, 18))],
        patient: mary,
        range: june,
      );
      final Uint8List populated = await exp.exportRange(
        entries: <JournalEntry>[
          entry(
            'j1',
            DateTime(2026, 6, 5, 18),
            situationText: 'Restless in the late afternoon.',
            attemptsText: 'Dimmed the lights and sat with her.',
            notes: 'Settled after about twenty minutes.',
          ),
        ],
        patient: mary,
        range: june,
      );

      expect(isPdf(populated), isTrue);
      expect(populated.length, greaterThan(bare.length),
          reason: 'the situation/attempts/notes lines add rendered content');
    });

    test('an out-of-range entry does NOT change output; an in-range one '
        'does (date-range filtering runs before rendering)', () async {
      final PdfExporter exp = exporter();
      final Patient mary = maryHenderson();
      final JournalEntry inRange = entry('in', DateTime(2026, 6, 10, 18),
          situationText: 'Restless evening.');
      final JournalEntry outOfRange = entry('out', DateTime(2026, 5, 1, 12),
          situationText: 'Wandered the hallway.');
      final JournalEntry inRange2 = entry('in2', DateTime(2026, 6, 12, 12),
          situationText: 'Paced before lunch.');

      final int base = (await exp.exportRange(
        entries: <JournalEntry>[inRange],
        patient: mary,
        range: june,
      )).length;
      final int withOut = (await exp.exportRange(
        entries: <JournalEntry>[inRange, outOfRange],
        patient: mary,
        range: june,
      )).length;
      final int withIn = (await exp.exportRange(
        entries: <JournalEntry>[inRange, inRange2],
        patient: mary,
        range: june,
      )).length;

      expect(withOut, base,
          reason: 'the May entry is filtered out — output is unchanged');
      expect(withIn, greaterThan(base),
          reason: 'a second June entry adds another entry block');
    });

    test('appends content when medications are supplied', () async {
      final PdfExporter exp = exporter();
      final Patient mary = maryHenderson();
      final int without = (await exp.exportRange(
        entries: const <JournalEntry>[],
        patient: mary,
        range: june,
      )).length;
      final int withMeds = (await exp.exportRange(
        entries: const <JournalEntry>[],
        patient: mary,
        range: june,
        medications: <MedicationWithSchedules>[
          const MedicationWithSchedules(
            medication: Medication(
              id: 'm1',
              name: 'Donepezil',
              dosage: '10 mg',
              route: MedicationRoute.oral,
            ),
            windows: <({DoseWindow window, MedicationWindowEntry entry})>[],
          ),
        ],
      )).length;
      expect(withMeds, greaterThan(without),
          reason: 'the medications section adds a heading + table');
    });

    test('an empty range still yields a valid PDF (no throw)', () async {
      final Uint8List bytes = await exporter().exportRange(
        entries: const <JournalEntry>[],
        patient: maryHenderson(),
        range: june,
      );
      expect(isPdf(bytes), isTrue);
    });

    test('a custom caregiverName renders without throwing', () async {
      final Uint8List bytes = await exporter().exportRange(
        entries: const <JournalEntry>[],
        patient: maryHenderson(),
        range: june,
        caregiverName: 'Dana the Caregiver',
      );
      expect(isPdf(bytes), isTrue);
    });
  });

  group('crisisCard', () {
    test('produces a valid PDF (no throw)', () async {
      final Uint8List bytes = await exporter().crisisCard(maryHenderson());
      expect(isPdf(bytes), isTrue);
    });
  });
}
