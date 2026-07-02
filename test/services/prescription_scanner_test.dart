import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/models/medication_draft.dart';
import 'package:holdclose/services/prescription_scanner.dart';

/// Coverage for the AI prescription scanner's pure logic: the fake's
/// deterministic draft, and the reply-parsing helpers that must survive
/// whatever prose/fences a model wraps its JSON in — falling back to null
/// (→ manual entry) rather than throwing.
void main() {
  group('FakePrescriptionScanner', () {
    test('returns a deterministic draft, ignoring the image path', () async {
      const FakePrescriptionScanner scanner = FakePrescriptionScanner();
      final MedicationDraft? d =
          await scanner.extractFromImage(imagePath: 'unused/path.jpg');
      expect(d, isNotNull);
      expect(d!.name, 'Lisinopril');
      expect(d.dosage, '10 mg');
      expect(d.route, MedicationRoute.oral);
    });
  });

  group('draftFromReplyText', () {
    test('parses a bare JSON object', () {
      final MedicationDraft? d = draftFromReplyText(
          '{"name":"Donepezil","dosage":"10 mg","route":"oral"}');
      expect(d, isNotNull);
      expect(d!.name, 'Donepezil');
      expect(d.route, MedicationRoute.oral);
    });

    test('tolerates surrounding prose and code fences', () {
      final MedicationDraft? d = draftFromReplyText(
        'Sure!\n```json\n{"name":"Aspirin","dosage":"81 mg"}\n```\nDone.',
      );
      expect(d, isNotNull);
      expect(d!.name, 'Aspirin');
      expect(d.dosage, '81 mg');
    });

    test('null when no JSON object is present', () {
      expect(draftFromReplyText('I could not read the label.'), isNull);
    });

    test('null on malformed JSON (no throw)', () {
      expect(draftFromReplyText('{name: not valid json}'), isNull);
    });
  });

  group('draftFromResponseBody', () {
    test('reads a decoded {text: ...} map', () {
      final MedicationDraft? d = draftFromResponseBody(
          <String, dynamic>{'text': '{"name":"Metformin"}'});
      expect(d?.name, 'Metformin');
    });

    test('reads a raw string body', () {
      final MedicationDraft? d = draftFromResponseBody('{"name":"Warfarin"}');
      expect(d?.name, 'Warfarin');
    });

    test('null for an error body or an unexpected shape', () {
      expect(draftFromResponseBody(<String, dynamic>{'error': 'boom'}), isNull);
      expect(draftFromResponseBody(42), isNull);
    });
  });
}
