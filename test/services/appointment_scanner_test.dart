import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/appointment.dart' show ProviderRole;
import 'package:holdclose/models/appointment_draft.dart';
import 'package:holdclose/services/appointment_scanner.dart';
import 'package:holdclose/services/document_scan_transport.dart';

/// Coverage for the appointment scanner's fake + the shared scan transport's
/// pure JSON parsing (used by every document-scan feature).
void main() {
  group('FakeAppointmentScanner', () {
    test('returns a deterministic draft', () async {
      const FakeAppointmentScanner scanner = FakeAppointmentScanner();
      final AppointmentDraft? d =
          await scanner.extractFromImage(imagePath: 'unused.jpg');
      expect(d, isNotNull);
      expect(d!.providerName, 'Dr. Berger');
      expect(d.providerRole, ProviderRole.neurologist);
      expect(d.startsAt, isNotNull);
    });
  });

  group('shared transport JSON parsing', () {
    test('jsonMapFromText finds an object amid prose / fences', () {
      final Map<String, dynamic>? m = jsonMapFromText(
        'Sure!\n```json\n{"providerName":"Dr. Kim","time":"9 AM"}\n```',
      );
      expect(m, isNotNull);
      expect(m!['providerName'], 'Dr. Kim');
    });

    test('jsonMapFromText null on no object / malformed', () {
      expect(jsonMapFromText('no json here'), isNull);
      expect(jsonMapFromText('{nope: bad}'), isNull);
    });

    test('a malformed-JSON parse leaves a breadcrumb (not a silent null)', () {
      // The 2026-07-13 scan bug: the vision model answered in PROSE, the parse
      // failed, and this returned null SILENTLY — so a tester's "scan isn't
      // working" report carried no clue. It must now log why.
      final List<String> lines = <String>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
      try {
        // A `{...}` span that is NOT valid JSON — reaches json.decode and throws.
        expect(jsonMapFromText('here: {this is not, valid: json}'), isNull);
      } finally {
        debugPrint = original;
      }
      expect(lines.join('\n'), contains('scan.jsonParse'));
    });

    test('jsonMapFromResponseBody reads {text:...} map and raw string', () {
      expect(
        jsonMapFromResponseBody(
            <String, dynamic>{'text': '{"providerName":"Dr. A"}'})?['providerName'],
        'Dr. A',
      );
      expect(
        jsonMapFromResponseBody('{"providerName":"Dr. B"}')?['providerName'],
        'Dr. B',
      );
    });

    test('jsonMapFromResponseBody null for error / unexpected bodies', () {
      expect(jsonMapFromResponseBody(<String, dynamic>{'error': 'x'}), isNull);
      expect(jsonMapFromResponseBody(7), isNull);
    });
  });
}
