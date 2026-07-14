/// Every IMAGE IMPORT, driven by the LIVE vision model through the app's REAL
/// scanners. The unit tests fake the model; this is what the caregiver gets.
///
/// Reported 2026-07-13 ("We aren't getting image imports for medications"):
/// the model ignored the system prompt's JSON rule and answered in prose, so
/// every scan produced nothing. Only a live run can catch that.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/appointment_draft.dart';
import 'package:holdclose/models/document.dart' show Insurance;
import 'package:holdclose/models/medication_draft.dart';
import 'package:holdclose/services/appointment_scanner.dart';
import 'package:holdclose/services/insurance_card_scanner.dart';
import 'package:holdclose/services/prescription_scanner.dart';

const String _baseUrl = String.fromEnvironment('FORUM_API_URL');
const String _jwt = String.fromEnvironment('LIVE_JWT');
const String _rx = String.fromEnvironment('RX_IMAGE');
const String _appt = String.fromEnvironment('APPT_IMAGE');
const String _ins = String.fromEnvironment('INS_IMAGE');

bool get _configured => _baseUrl.isNotEmpty && _jwt.isNotEmpty;
Future<String> _token() async => _jwt;

void main() {
  final Object? skip = _configured ? false : 'needs FORUM_API_URL + LIVE_JWT';

  test('prescription label → medication draft', () async {
    final MedicationDraft? d = await ApiPrescriptionScanner(
      baseUrl: _baseUrl,
      tokenLoader: _token,
    ).extractFromImage(imagePath: _rx);

    // ignore: avoid_print
    print('RX: name=${d?.name} dosage=${d?.dosage} route=${d?.route} '
        'prescriber=${d?.prescriber} notes=${d?.notes}');
    expect(d, isNotNull, reason: 'the scan produced nothing');
    // "Medication didn't import correctly" (2026-07-13): the label prints
    // IBUPROFEN 400 MG TABLET and the model copies it verbatim, so the draft
    // offered that as the NAME. The caregiver must get the drug, not the line.
    expect(d!.name, 'Ibuprofen',
        reason: 'the name must be the drug alone — no strength, no form');
    expect(d.dosage, '400 mg', reason: 'the dose must be the strength alone');
  }, skip: skip);

  test('appointment card → appointment draft', () async {
    final AppointmentDraft? d = await ApiAppointmentScanner(
      baseUrl: _baseUrl,
      tokenLoader: _token,
    ).extractFromImage(imagePath: _appt);

    // ignore: avoid_print
    print('APPT: provider=${d?.providerName} startsAt=${d?.startsAt} '
        'location=${d?.location} phone=${d?.providerPhone}');
    expect(d, isNotNull, reason: 'the scan produced nothing');
    expect(d!.providerName, isNotNull, reason: 'who the visit is with');
    // The one that actually matters: a dateless appointment is useless.
    expect(d.startsAt, isNotNull,
        reason: 'the card prints "August 3, 2026 / 2:30 PM" — it must parse');
    expect(d.startsAt!.month, 8);
    expect(d.startsAt!.day, 3);
    expect(d.startsAt!.hour, 14);
  }, skip: skip);

  test('insurance card → insurance draft', () async {
    final Insurance? d = await ApiInsuranceCardScanner(
      baseUrl: _baseUrl,
      tokenLoader: _token,
    ).extractFromImage(imagePath: _ins);

    // ignore: avoid_print
    print('INS: $d');
    expect(d, isNotNull, reason: 'the scan produced nothing');
  }, skip: skip);
}
