import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/services/pdf_exporter.dart';

/// The care-summary PDF renders without throwing and produces a real
/// document, including when the meds/appointments lists are empty.
void main() {
  test('careSummary builds a real PDF from conditions/allergies', () async {
    const PdfExporter exporter = PdfExporter();
    final List<int> bytes = await exporter.careSummary(
      patient: maryHenderson(),
      conditions: const <String>['Post-stroke', 'Hypertension'],
      allergies: const <String>['Penicillin'],
    );
    // A valid PDF starts with "%PDF" and is more than a trivial buffer.
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('careSummary tolerates an empty summary (no meds/appointments)',
      () async {
    const PdfExporter exporter = PdfExporter();
    final List<int> bytes =
        await exporter.careSummary(patient: maryHenderson());
    expect(bytes.length, greaterThan(500));
  });
}
