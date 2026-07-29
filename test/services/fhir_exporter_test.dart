import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart';
import 'package:holdclose/models/health_log_entry.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/seed/demo_dataset.dart' show demoPatientId;
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/documents_provider.dart';
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/data_exporter.dart';
import 'package:holdclose/services/fhir_exporter.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';

/// The FHIR-shaped export is the one artefact a clinician or health system
/// could consume without a bespoke integration, so the mapping from our
/// models onto FHIR resource types is worth pinning.
///
/// NOTE: these assertions check resource SHAPE, not conformance. There is no
/// terminology binding and no StructureDefinition validation — see the class
/// doc on [FhirExporter]. Do not let this test grow into an implied
/// conformance claim.
ExportSources _sourcesFor(HoldcloseDatabase db, StorageProvider storage) => (
      storage: storage,
      medications: MedicationRepository(db),
      appointments: AppointmentRepository(db),
      providers: ProviderRepository(db),
      healthLog: HealthLogRepository(db),
      carePlan: CarePlanRepository(db),
      documents: DocumentsRepository(db),
      careCircle: CareCircleRepository(db),
      careEvents: CareEventsRepository(db),
      careTasks: CareTasksRepository(db),
      careShifts: CareShiftsRepository(db),
      expenses: ExpensesRepository(db),
      chat: ChatRepository(db),
    );

Map<String, dynamic>? _first(Map<String, dynamic> bundle, String type) {
  for (final dynamic e in bundle['entry'] as List<dynamic>) {
    final Map<String, dynamic> r =
        (e as Map<String, dynamic>)['resource'] as Map<String, dynamic>;
    if (r['resourceType'] == type) return r;
  }
  return null;
}

Iterable<Map<String, dynamic>> _all(Map<String, dynamic> bundle, String type) =>
    (bundle['entry'] as List<dynamic>)
        .map((dynamic e) =>
            (e as Map<String, dynamic>)['resource'] as Map<String, dynamic>)
        .where((Map<String, dynamic> r) => r['resourceType'] == type);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HoldcloseDatabase db;
  late InMemoryStorageProvider storage;
  late ExportSources sources;
  final FhirExporter exporter =
      FhirExporter(clock: () => DateTime.utc(2026, 7, 29, 12));

  setUp(() async {
    db = HoldcloseDatabase(NativeDatabase.memory());
    storage = InMemoryStorageProvider();
    sources = _sourcesFor(db, storage);
    await storage.upsertPatient(maryHenderson());
  });

  tearDown(() async => db.close());

  test('bundle is a FHIR collection and says what it is', () async {
    final Map<String, dynamic> b = await exporter.gather(sources);
    expect(b['resourceType'], 'Bundle');
    expect(b['type'], 'collection');
    expect(b['timestamp'], '2026-07-29T12:00:00.000Z');
    // The payload must disclose that it is not conformance-validated, so a
    // consumer is never misled by the resource shapes alone.
    final String tag = ((b['meta'] as Map<String, dynamic>)['tag']
        as List<dynamic>)[0]['display'] as String;
    expect(tag, contains('not conformance-validated'));
  });

  test('patient maps to Patient with a birth date', () async {
    final Map<String, dynamic> p =
        _first(await exporter.gather(sources), 'Patient')!;
    expect(p['id'], demoPatientId);
    expect((p['name'] as List<dynamic>)[0]['text'], 'Mary Henderson');
    expect(p['birthDate'], '1948-03-04');
  });

  test('diagnosis maps to a Condition referencing the patient', () async {
    final Map<String, dynamic> c =
        _first(await exporter.gather(sources), 'Condition')!;
    expect(c['code']['text'],
        'Stroke recovery (ischemic, 2024); high blood pressure');
    expect(c['subject']['reference'], 'Patient/$demoPatientId');
    expect(c['recordedDate'], '2024-02-10');
  });

  test('a medication scheduled into two windows becomes a MedicationStatement '
      'with a twice-daily Dosage', () async {
    const Medication m = Medication(
      id: 'm1',
      name: 'Lisinopril',
      dosage: '10 mg',
      route: MedicationRoute.oral,
      prescriber: 'Dr. Ortega',
    );
    await sources.medications.upsertMedication(m);
    const List<DoseWindow> ws = <DoseWindow>[
      DoseWindow(
        id: 'w-am',
        patientId: demoPatientId,
        label: 'Morning',
        anchorTime: TimeOfDay(hour: 8, minute: 0),
        sortOrder: 0,
      ),
      DoseWindow(
        id: 'w-pm',
        patientId: demoPatientId,
        label: 'Evening',
        anchorTime: TimeOfDay(hour: 20, minute: 0),
        sortOrder: 1,
      ),
    ];
    for (final DoseWindow w in ws) {
      await sources.medications.upsertWindow(w);
      await sources.medications.upsertEntry(MedicationWindowEntry(
        id: 'e-${w.id}',
        medicationId: m.id,
        windowId: w.id,
        daysOfWeek: const <int>{},
        startsOn: DateTime.utc(2026, 1, 1),
      ));
    }

    final Map<String, dynamic> ms =
        _first(await exporter.gather(sources), 'MedicationStatement')!;
    expect(ms['medicationCodeableConcept']['text'], 'Lisinopril');
    expect(ms['informationSource']['display'], 'Dr. Ortega');
    final Map<String, dynamic> dosage =
        (ms['dosage'] as List<dynamic>)[0] as Map<String, dynamic>;
    expect(dosage['text'], '10 mg');
    expect(dosage['route']['text'], 'Oral');
    final Map<String, dynamic> repeat =
        dosage['timing']['repeat'] as Map<String, dynamic>;
    expect(repeat['frequency'], 2, reason: 'two windows = twice daily');
    expect(repeat['periodUnit'], 'd');
    expect(repeat['timeOfDay'], containsAll(<String>['08:00:00', '20:00:00']));
  });

  test('a blood-pressure reading becomes an Observation with two components',
      () async {
    await sources.healthLog.upsert(HealthLogEntry(
      id: 'h1',
      patientId: demoPatientId,
      recordedAt: DateTime.utc(2026, 7, 1, 9),
      kind: HealthLogKind.vitals,
      systolic: 138,
      diastolic: 86,
    ));
    final Map<String, dynamic> o =
        _first(await exporter.gather(sources), 'Observation')!;
    expect(o['status'], 'final');
    expect(o['subject']['reference'], 'Patient/$demoPatientId');
    final List<dynamic> parts = o['component'] as List<dynamic>;
    expect(parts, hasLength(2));
    expect(parts[0]['valueQuantity']['value'], 138);
    expect(parts[0]['valueQuantity']['unit'], 'mm[Hg]');
    expect(parts[1]['valueQuantity']['value'], 86);
  });

  test('a cancelled appointment maps to FHIR status "cancelled"', () async {
    await ProviderRepository(db).upsertProvider(const Provider(
      id: 'pr1',
      name: 'Dr. Ortega',
      role: ProviderRole.neurologist,
      phone: '(415) 555-0188',
      address: '250 Bon Air Rd',
    ));
    await sources.appointments.upsertAppointment(Appointment(
      id: 'a1',
      providerId: 'pr1',
      startsAt: DateTime.utc(2026, 8, 14, 10, 30),
      durationMinutes: 45,
      location: 'Neurology clinic',
      agenda: const <String>['Ask about dizziness'],
      status: AppointmentStatus.canceled,
    ));
    final Map<String, dynamic> a =
        _first(await exporter.gather(sources), 'Appointment')!;
    expect(a['status'], 'cancelled');
    expect(a['start'], '2026-08-14T10:30:00.000Z');
    expect(a['minutesDuration'], 45);
    expect(a['comment'], 'Ask about dizziness');
  });

  test('exportJson is valid, pretty-printed JSON', () async {
    final String text = utf8.decode(await exporter.exportJson(sources));
    expect(text, contains('\n  '), reason: 'indented for a human reader');
    expect(jsonDecode(text), isA<Map<String, dynamic>>());
  });

  test('an empty record still produces a well-formed bundle', () async {
    final InMemoryStorageProvider empty = InMemoryStorageProvider();
    final HoldcloseDatabase db2 =
        HoldcloseDatabase(NativeDatabase.memory());
    addTearDown(() async => db2.close());
    final Map<String, dynamic> b =
        await exporter.gather(_sourcesFor(db2, empty));
    expect(b['resourceType'], 'Bundle');
    expect(_all(b, 'Patient'), isEmpty);
  });
}
