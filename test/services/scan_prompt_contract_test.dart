import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/services/document_scan_transport.dart';

/// Every IMAGE scanner must demand JSON in its USER prompt.
///
/// The vision model ignores a "return only JSON" rule that lives in the SYSTEM
/// prompt. Against the deployed model it answered in prose — "The medication
/// listed on the label is Ibuprofen 400 MG Tablet." — so the app found no
/// `{...}` to parse and every scan silently produced NOTHING. Reported
/// 2026-07-13: "We aren't getting image imports for medications."
///
/// Repeating the instruction in the user turn makes it comply (verified against
/// the live model: name / dosage / route / prescriber / notes all extracted).
/// This test pins the instruction so a future tidy-up can't quietly move it
/// back into the system prompt and break every scan again.
void main() {
  test('the shared instruction demands a bare JSON object', () {
    expect(scanJsonOnlyInstruction, contains('ONLY the JSON object'));
    expect(scanJsonOnlyInstruction, contains('start your reply with {'));
    expect(scanJsonOnlyInstruction.toLowerCase(), contains('no prose'));
  });

  test('a scan reply that is PROSE yields no draft — which is why the '
      'instruction matters', () {
    // Exactly what the model returned before the fix.
    expect(
      jsonMapFromResponseBody(<String, dynamic>{
        'text': 'The medication listed on the label is Ibuprofen 400 MG Tablet.'
      }),
      isNull,
    );
    // ...and what it returns after.
    expect(
      jsonMapFromResponseBody(<String, dynamic>{
        'text': '{"name":"IBUPROFEN","dosage":"400 MG"}'
      }),
      containsPair('name', 'IBUPROFEN'),
    );
  });
}
