import 'dart:typed_data';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/services/pdf_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pinned anchor for every fixture in this file. Midday so subtracting
/// "N days" can't roll a date across a DST boundary on the host.
final DateTime _now = DateTime(2026, 5, 29, 12);

const Behavior _sundowning =
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');
const Behavior _accusing =
    Behavior(id: 'accusing', label: 'Accusing me', glyph: '💸');
const Behavior _wantsHome =
    Behavior(id: 'wants_home', label: '"I want to go home"', glyph: '🏠');

const TriageAnswers _triage = TriageAnswers(
  when: TriageWhen.lateAfternoonEvening,
  whatChanged: TriageWhatChanged.nothing,
  whatTried: TriageWhatTried.talked,
);

JournalEntry _entry({
  required String id,
  required Behavior behavior,
  required DateTime createdAt,
  JournalOutcome outcome = JournalOutcome.positive,
  List<String> tweak = const <String>['Dim the lights'],
  List<String> say = const <String>['I am right here with you.'],
  String? notes,
}) {
  return JournalEntry(
    id: id,
    behavior: behavior,
    triage: _triage,
    result: DecoderResult(
      say: say,
      tweak: tweak,
      dontSay: const <String>["Don't argue"],
      generatedAt: createdAt,
    ),
    outcome: outcome,
    attempt: 0,
    createdAt: createdAt,
    notes: notes,
  );
}

Patient _maryHenderson() => Patient(
      id: 'demo-patient-mary',
      name: 'Mary Henderson',
      age: 78,
      diagnosis: "Alzheimer's disease, stage 5 (moderately severe)",
      diagnosedAt: DateTime.utc(2022, 4, 15),
      medications: const <Medication>[
        Medication(
            name: 'Donepezil', dose: '10 mg', schedule: 'every morning'),
        Medication(
            name: 'Memantine', dose: '10 mg', schedule: 'every evening'),
        Medication(
            name: 'Sertraline', dose: '50 mg', schedule: 'every morning'),
      ],
      allergies: const <String>['Penicillin'],
      calms: const <String>[
        'Sitting on her left side.',
        'The phrase Mom it is okay.',
        'Showing her a photo of Dad.',
      ],
      escalates: const <String>[
        'Strangers leaning over her.',
        'Loud beeping.',
        'Being asked many questions in a row.',
      ],
      primaryCaregiver:
          const Contact(name: 'Sarah Henderson', phone: '(415) 555-0142'),
      healthcarePOA:
          const Contact(name: 'Sarah Henderson', phone: '(415) 555-0142'),
      advanceDirective: const AdvanceDirectiveStatus(
        onFileAt: 'Marin General Hospital',
        dnr: false,
      ),
    );

/// Read [bytes] as Latin-1 so byte-level substring assertions work even
/// when the buffer contains binary-looking sections — text drawn with
/// the pdf package's default Helvetica encoding lands as plain ASCII in
/// the content stream as long as compression is disabled.
String _asLatin1(Uint8List bytes) => String.fromCharCodes(bytes);

/// Pull every `[(text)]TJ` glyph run out of the uncompressed PDF stream
/// and join them with spaces so multi-word assertions like
/// `contains('Mary Henderson')` succeed.
///
/// The `pdf` package emits one `Tj` operation per whitespace-separated
/// word (each word is positioned individually so kerning is preserved),
/// so raw substring matching across word boundaries can't see them. This
/// helper reverses that segmentation for the test layer.
String _extractText(Uint8List bytes) {
  final String raw = _asLatin1(bytes);
  final RegExp tj = RegExp(r'\[\(((?:\\.|[^)])*)\)\]\s*TJ');
  final List<String> tokens = <String>[];
  for (final RegExpMatch m in tj.allMatches(raw)) {
    tokens.add(_unescapePdfString(m.group(1)!));
  }
  return tokens.join(' ');
}

/// Reverse the minimal PostScript-string escaping the `pdf` package uses
/// inside `(...)` literals: `\(`, `\)`, and `\\`.
String _unescapePdfString(String s) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    final String c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      out.write(s[i + 1]);
      i += 1;
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

void main() {
  group('PdfExporter.exportRange', () {
    test('produces a valid non-empty PDF for fixture entries', () async {
      const PdfExporter exporter = PdfExporter();
      final Uint8List bytes = await exporter.exportRange(
        entries: <JournalEntry>[
          _entry(
            id: 'e1',
            behavior: _sundowning,
            createdAt: _now.subtract(const Duration(days: 1)),
          ),
          _entry(
            id: 'e2',
            behavior: _accusing,
            createdAt: _now.subtract(const Duration(days: 3)),
          ),
        ],
        patient: _maryHenderson(),
        range: DateRange(
          start: _now.subtract(const Duration(days: 30)),
          end: _now,
        ),
        caregiverName: 'Sarah Henderson',
      );

      expect(bytes, isNotEmpty);
      // PDF magic — every real PDF starts with `%PDF-1.x`.
      expect(_asLatin1(bytes.sublist(0, 5)), '%PDF-');
    });

    test('rendered text includes patient, behaviors, and disclaimer',
        () async {
      // `compress: false` keeps the content streams uncompressed so the
      // Tj operators carrying the on-page text land as searchable ASCII
      // inside the byte buffer.
      const PdfExporter exporter = PdfExporter(compress: false);
      final Uint8List bytes = await exporter.exportRange(
        entries: <JournalEntry>[
          _entry(
            id: 'e1',
            behavior: _sundowning,
            createdAt: _now.subtract(const Duration(days: 1)),
            notes: 'Settled within ten minutes.',
          ),
          _entry(
            id: 'e2',
            behavior: _accusing,
            createdAt: _now.subtract(const Duration(days: 3)),
          ),
          _entry(
            id: 'e3',
            behavior: _wantsHome,
            createdAt: _now.subtract(const Duration(days: 5)),
          ),
        ],
        patient: _maryHenderson(),
        range: DateRange(
          start: _now.subtract(const Duration(days: 30)),
          end: _now,
        ),
        caregiverName: 'Sarah Henderson',
      );
      final String text = _extractText(bytes);

      expect(text, contains('Doctor visit packet'));
      expect(text, contains('Mary Henderson'));
      expect(text, contains('Sarah Henderson'));
      expect(text, contains('Behavior summary'));
      expect(text, contains('Sundowning'));
      expect(text, contains('Accusing me'));
      expect(text, contains('Dim the lights'));
      expect(text, contains('Settled within ten minutes.'));
      expect(text, contains(PdfExporter.footerDisclaimer));
    });

    test('entries outside the range are filtered out', () async {
      const PdfExporter exporter = PdfExporter(compress: false);
      final Uint8List bytes = await exporter.exportRange(
        entries: <JournalEntry>[
          _entry(
            id: 'inside',
            behavior: _sundowning,
            createdAt: _now.subtract(const Duration(days: 2)),
          ),
          _entry(
            id: 'outside',
            behavior: _accusing,
            createdAt: _now.subtract(const Duration(days: 60)),
          ),
        ],
        patient: _maryHenderson(),
        range: DateRange(
          start: _now.subtract(const Duration(days: 30)),
          end: _now,
        ),
      );
      final String text = _extractText(bytes);

      expect(text, contains('Sundowning'));
      // The accusing entry is outside the 30-day window so its row
      // should not appear in either the summary table or the chronology.
      expect(text, isNot(contains('Accusing me')));
    });

    test('empty entries list still produces a valid PDF', () async {
      const PdfExporter exporter = PdfExporter(compress: false);
      final Uint8List bytes = await exporter.exportRange(
        entries: const <JournalEntry>[],
        patient: _maryHenderson(),
        range: DateRange(
          start: _now.subtract(const Duration(days: 30)),
          end: _now,
        ),
      );
      expect(bytes, isNotEmpty);
      final String text = _extractText(bytes);
      expect(text, contains('Mary Henderson'));
      expect(text, contains('No entries to show for this date range.'));
    });

    test('caregiver name falls back to the patient.primaryCaregiver name',
        () async {
      const PdfExporter exporter = PdfExporter(compress: false);
      final Uint8List bytes = await exporter.exportRange(
        entries: const <JournalEntry>[],
        patient: _maryHenderson(),
        range: DateRange(
          start: _now.subtract(const Duration(days: 30)),
          end: _now,
        ),
      );
      expect(_extractText(bytes), contains('Sarah Henderson'));
    });

    test('entries with non-positive outcomes render fallback "what worked"',
        () async {
      const PdfExporter exporter = PdfExporter(compress: false);
      final Uint8List bytes = await exporter.exportRange(
        entries: <JournalEntry>[
          _entry(
            id: 'pending',
            behavior: _sundowning,
            createdAt: _now.subtract(const Duration(days: 1)),
            outcome: JournalOutcome.pending,
          ),
          _entry(
            id: 'tried',
            behavior: _accusing,
            createdAt: _now.subtract(const Duration(days: 2)),
            outcome: JournalOutcome.triedDifferent,
          ),
          _entry(
            id: 'err',
            behavior: _wantsHome,
            createdAt: _now.subtract(const Duration(days: 3)),
            outcome: JournalOutcome.error,
          ),
        ],
        patient: _maryHenderson(),
        range: DateRange(
          start: _now.subtract(const Duration(days: 30)),
          end: _now,
        ),
      );
      final String text = _extractText(bytes);
      expect(text, contains('Tried a different approach.'));
      expect(text, contains("Couldn't reach the coach."));
    });
  });

  group('PdfExporter.crisisCard', () {
    test('returns valid non-empty PDF bytes', () async {
      const PdfExporter exporter = PdfExporter();
      final Uint8List bytes = await exporter.crisisCard(_maryHenderson());
      expect(bytes, isNotEmpty);
      expect(_asLatin1(bytes.sublist(0, 5)), '%PDF-');
    });

    test('contains every §9.1 patient field on the page', () async {
      // Pin the clock so the "Updated <date>" footer is deterministic.
      final PdfExporter exporter = PdfExporter(
        compress: false,
        clock: () => DateTime(2026, 5, 29, 9),
      );
      final Patient mary = _maryHenderson();
      final Uint8List bytes = await exporter.crisisCard(mary);
      final String text = _extractText(bytes);

      // Header + identity.
      expect(text, contains('Hospital handoff card'));
      expect(text, contains('Mary Henderson'));
      expect(text, contains('Age 78'));

      // Diagnosis + diagnosis date.
      expect(text, contains("Alzheimer's disease"));
      expect(text, contains('Apr 15, 2022'));

      // Every medication (name + dose + schedule).
      for (final Medication m in mary.medications) {
        expect(text, contains(m.name));
        expect(text, contains(m.dose));
        expect(text, contains(m.schedule));
      }

      // Allergies, calms, escalates.
      for (final String a in mary.allergies) {
        expect(text, contains(a));
      }
      for (final String c in mary.calms) {
        expect(text, contains(c));
      }
      for (final String e in mary.escalates) {
        expect(text, contains(e));
      }

      // Contacts.
      expect(text, contains(mary.primaryCaregiver.name));
      expect(text, contains(mary.primaryCaregiver.phone));
      expect(text, contains(mary.healthcarePOA.name));
      expect(text, contains(mary.healthcarePOA.phone));

      // Advance directive on-file status + DNR.
      expect(text, contains(mary.advanceDirective.onFileAt));
      expect(text, contains('DNR: No'));

      // Footer + medical-advice disclaimer.
      expect(text, contains('Updated May 29, 2026'));
      expect(text, contains(PdfExporter.footerDisclaimer));
    });

    test('reflects DNR true when set', () async {
      const PdfExporter exporter = PdfExporter(compress: false);
      final Patient mary = _maryHenderson().copyWith(
        advanceDirective: const AdvanceDirectiveStatus(
          onFileAt: 'Marin General Hospital',
          dnr: true,
        ),
      );
      final Uint8List bytes = await exporter.crisisCard(mary);
      expect(_extractText(bytes), contains('DNR: Yes'));
    });
  });

  group('DateRange', () {
    test('contains is half-open [start, end)', () {
      final DateRange r = DateRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 30),
      );
      expect(r.contains(DateTime(2026, 5, 1)), isTrue);
      expect(r.contains(DateTime(2026, 5, 15)), isTrue);
      expect(r.contains(DateTime(2026, 5, 30)), isFalse);
      expect(r.contains(DateTime(2026, 4, 30)), isFalse);
    });

    test('equality + hash treat same endpoints as equal', () {
      final DateRange a = DateRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 30),
      );
      final DateRange b = DateRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 30),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
