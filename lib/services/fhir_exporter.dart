import 'dart:convert';
import 'dart:typed_data';

import '../models/appointment.dart';
import '../models/health_log_entry.dart';
import '../models/medication.dart';
import '../models/patient.dart';
import 'data_exporter.dart' show DataFileSharer, ExportSources;

/// Exports the care record as a **FHIR-shaped** JSON Bundle.
///
/// ## What this is, and what it is not
///
/// This produces a `Bundle` of `collection` type whose entries use HL7 FHIR
/// R4 resource types and field names, so a clinician or a health system can
/// read a Holdclose record without a bespoke integration.
///
/// It is **not** a conformance-tested FHIR implementation. There is no
/// terminology binding (no RxNorm, LOINC or SNOMED codes — we do not have
/// coded data to bind), no server, and no validation against the R4
/// StructureDefinitions. Describe it as a *FHIR-shaped export*, never as
/// "FHIR-compliant" or "FHIR-certified" — the difference matters to anyone
/// who would actually consume it.
///
/// ## Why it exists
///
/// The care record is already stored as discrete typed rows rather than free
/// text, which is what makes this mapping possible at all:
///
/// | Holdclose            | FHIR resource                    |
/// |----------------------|----------------------------------|
/// | Patient              | `Patient`                        |
/// | Medication + windows | `MedicationStatement` + `Dosage` |
/// | Appointment          | `Appointment`                    |
/// | HealthLogEntry       | `Observation`                    |
/// | diagnosis            | `Condition`                      |
///
/// One-way export only: nothing here reads FHIR back in.
class FhirExporter {
  const FhirExporter({this.clock = DateTime.now});

  /// Wall clock for the bundle timestamp. Injectable so tests pin it.
  final DateTime Function() clock;

  /// FHIR release these resource shapes follow.
  static const String fhirVersion = '4.0.1';

  /// Build the bundle. Pure: takes repositories in, returns a map.
  Future<Map<String, dynamic>> gather(ExportSources sources) async {
    final Patient? patient = await sources.storage.getPatient();
    final List<Medication> medications =
        await sources.medications.listMedications();
    final List<DoseWindow> windows = patient == null
        ? const <DoseWindow>[]
        : await sources.medications.windowsForPatient(patient.id);
    // medication -> the windows it is scheduled into, via the join table.
    final Map<String, List<String>> windowIdsByMed = <String, List<String>>{};
    for (final Medication m in medications) {
      final List<MedicationWindowEntry> entries =
          await sources.medications.entriesForMedication(m.id);
      windowIdsByMed[m.id] =
          entries.map((MedicationWindowEntry e) => e.windowId).toList();
    }
    final List<Appointment> appointments =
        await sources.appointments.listAppointments();
    final List<HealthLogEntry> healthLog = await sources.healthLog.listAll();

    final String subjectRef =
        patient == null ? 'Patient/unknown' : 'Patient/${patient.id}';

    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[
      if (patient != null) _entry(_patient(patient)),
      if (patient != null && patient.diagnosis.trim().isNotEmpty)
        _entry(_condition(patient, subjectRef)),
      for (final Medication m in medications)
        _entry(_medicationStatement(
            m, windows, windowIdsByMed[m.id] ?? const <String>[], subjectRef)),
      for (final Appointment a in appointments)
        _entry(_appointment(a, subjectRef)),
      for (final HealthLogEntry h in healthLog)
        ..._observations(h, subjectRef).map(_entry),
    ];

    return <String, dynamic>{
      'resourceType': 'Bundle',
      'type': 'collection',
      'timestamp': clock().toUtc().toIso8601String(),
      'meta': <String, dynamic>{
        'profile': <String>['http://hl7.org/fhir/StructureDefinition/Bundle'],
        // Stated plainly in the payload itself so a consumer is never misled
        // about what they are holding.
        'tag': <Map<String, dynamic>>[
          <String, dynamic>{
            'code': 'fhir-shaped-export',
            'display':
                'Exported from Holdclose. FHIR R4 $fhirVersion resource '
                    'shapes; not conformance-validated, no terminology bindings.',
          },
        ],
      },
      'entry': entries,
    };
  }

  Map<String, dynamic> _entry(Map<String, dynamic> resource) =>
      <String, dynamic>{'resource': resource};

  Map<String, dynamic> _patient(Patient p) => <String, dynamic>{
        'resourceType': 'Patient',
        'id': p.id,
        'name': <Map<String, dynamic>>[
          <String, dynamic>{'text': p.name},
        ],
        if (p.dateOfBirth != null)
          'birthDate': _date(p.dateOfBirth!)
        else
          'extension': <Map<String, dynamic>>[
            <String, dynamic>{
              'url': 'https://holdclose.app/fhir/StructureDefinition/age-years',
              'valueInteger': p.age,
            },
          ],
      };

  Map<String, dynamic> _condition(Patient p, String subject) =>
      <String, dynamic>{
        'resourceType': 'Condition',
        'id': 'condition-${p.id}',
        'subject': <String, dynamic>{'reference': subject},
        'code': <String, dynamic>{'text': p.diagnosis},
        'recordedDate': _date(p.diagnosedAt),
      };

  Map<String, dynamic> _medicationStatement(
    Medication m,
    List<DoseWindow> windows,
    List<String> windowIds,
    String subject,
  ) {
    // Dose windows are the schedule: each is a labelled time of day the
    // medication is meant to be taken. FHIR expresses that as Dosage.timing.
    final List<DoseWindow> mine =
        windows.where((DoseWindow w) => windowIds.contains(w.id)).toList();
    return <String, dynamic>{
      'resourceType': 'MedicationStatement',
      'id': m.id,
      'status': 'active',
      'subject': <String, dynamic>{'reference': subject},
      'medicationCodeableConcept': <String, dynamic>{'text': m.name},
      if (m.prescriber != null && m.prescriber!.trim().isNotEmpty)
        'informationSource': <String, dynamic>{'display': m.prescriber},
      'dosage': <Map<String, dynamic>>[
        <String, dynamic>{
          'text': m.dosage,
          'route': <String, dynamic>{'text': _route(m.route)},
          if (mine.isNotEmpty)
            'timing': <String, dynamic>{
              'repeat': <String, dynamic>{
                'frequency': mine.length,
                'period': 1,
                'periodUnit': 'd',
                if (mine.any((DoseWindow w) => w.anchorTime != null))
                  'timeOfDay': <String>[
                    for (final DoseWindow w in mine)
                      if (w.anchorTime != null)
                        '${w.anchorTime!.hour.toString().padLeft(2, '0')}:'
                            '${w.anchorTime!.minute.toString().padLeft(2, '0')}:00',
                  ],
              },
              'code': <String, dynamic>{
                'text': mine.map((DoseWindow w) => w.label).join(', '),
              },
            },
        },
      ],
    };
  }

  Map<String, dynamic> _appointment(Appointment a, String subject) {
    final DateTime end = a.startsAt.add(Duration(minutes: a.durationMinutes));
    return <String, dynamic>{
      'resourceType': 'Appointment',
      'id': a.id,
      'status': a.status == AppointmentStatus.canceled ? 'cancelled' : 'booked',
      'start': a.startsAt.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'minutesDuration': a.durationMinutes,
      if (a.location.trim().isNotEmpty)
        'description': a.location,
      if (a.agenda.isNotEmpty) 'comment': a.agenda.join('; '),
      'participant': <Map<String, dynamic>>[
        <String, dynamic>{
          'actor': <String, dynamic>{'reference': subject},
          'status': 'accepted',
        },
      ],
    };
  }

  /// A health-log row can carry several readings; FHIR models each as its
  /// own Observation, so one row may fan out into several resources.
  List<Map<String, dynamic>> _observations(HealthLogEntry h, String subject) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final String when = h.recordedAt.toUtc().toIso8601String();

    Map<String, dynamic> base(String suffix, String text) => <String, dynamic>{
          'resourceType': 'Observation',
          'id': '${h.id}-$suffix',
          'status': 'final',
          'subject': <String, dynamic>{'reference': subject},
          'effectiveDateTime': when,
          'code': <String, dynamic>{'text': text},
        };

    if (h.systolic != null && h.diastolic != null) {
      out.add(<String, dynamic>{
        ...base('bp', 'Blood pressure'),
        'component': <Map<String, dynamic>>[
          <String, dynamic>{
            'code': <String, dynamic>{'text': 'Systolic blood pressure'},
            'valueQuantity': _mmHg(h.systolic!),
          },
          <String, dynamic>{
            'code': <String, dynamic>{'text': 'Diastolic blood pressure'},
            'valueQuantity': _mmHg(h.diastolic!),
          },
        ],
      });
    }
    if (h.heartRate != null) {
      out.add(<String, dynamic>{
        ...base('hr', 'Heart rate'),
        'valueQuantity': <String, dynamic>{
          'value': h.heartRate,
          'unit': 'beats/minute',
        },
      });
    }
    // A symptom or note with no numeric reading still belongs in the record.
    if (out.isEmpty) {
      out.add(<String, dynamic>{
        ...base('note', _kind(h.kind)),
        'valueString': h.notes ?? '',
      });
    }
    return out;
  }

  Map<String, dynamic> _mmHg(int v) =>
      <String, dynamic>{'value': v, 'unit': 'mm[Hg]'};

  String _route(MedicationRoute r) => switch (r) {
        MedicationRoute.oral => 'Oral',
        MedicationRoute.topical => 'Topical',
        MedicationRoute.injection => 'Injection',
        MedicationRoute.other => 'Other',
      };

  String _kind(HealthLogKind k) => switch (k) {
        HealthLogKind.vitals => 'Vital signs',
        HealthLogKind.symptom => 'Symptom',
        HealthLogKind.note => 'Note',
      };

  String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Pretty-printed bytes, ready to share.
  Future<Uint8List> exportJson(ExportSources sources) async {
    final Map<String, dynamic> bundle = await gather(sources);
    return Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(bundle)),
    );
  }

  /// Gather → encode → hand to the OS share sheet.
  Future<void> exportAndShare(
    ExportSources sources,
    DataFileSharer sharer,
  ) async {
    final Uint8List bytes = await exportJson(sources);
    final DateTime now = clock();
    final String stamp = '${_date(now)}'.replaceAll('-', '');
    await sharer.shareFile(
      bytes,
      filename: 'holdclose-fhir-$stamp.json',
      mimeType: 'application/fhir+json',
    );
  }
}
