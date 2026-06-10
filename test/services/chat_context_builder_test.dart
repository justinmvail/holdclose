import 'package:careblazers/models/care_plan_routine.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/services/chat_context_builder.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

Patient _patient({
  String name = 'Mary',
  int age = 78,
  String diagnosis = 'Alzheimer\'s',
  List<String> allergies = const <String>['Penicillin'],
}) =>
    Patient(
      id: 'p1',
      name: name,
      age: age,
      diagnosis: diagnosis,
      diagnosedAt: DateTime.utc(2023, 1, 1),
      medications: const <CrisisMedication>[],
      allergies: allergies,
      calms: const <String>[],
      escalates: const <String>[],
      primaryCaregiver: const Contact(name: 'C', phone: '555-0000'),
      healthcarePOA: const Contact(name: 'P', phone: '555-0001'),
      advanceDirective:
          const AdvanceDirectiveStatus(onFileAt: 'Unknown', dnr: false),
    );

Medication _med(String id, String name, String dosage) => Medication(
      id: id,
      name: name,
      dosage: dosage,
      route: MedicationRoute.oral,
    );

DoseWindow _window(String id, String label, TimeOfDay? at, int sort) =>
    DoseWindow(
      id: id,
      patientId: 'p1',
      label: label,
      anchorTime: at,
      sortOrder: sort,
    );

CarePlanRoutine _routine(String title, TimeOfDay at) => CarePlanRoutine(
      id: 'r-$title',
      patientId: 'p1',
      title: title,
      body: '',
      scheduledTime: at,
      frequencyKind: FrequencyKind.daily,
      daysOfWeek: const <int>{},
      startsOn: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('formatChatContext — seeded data', () {
    test('renders loved one, allergies, meds, windows, appts, routines', () {
      final String out = formatChatContext(ChatContextData(
        patient: _patient(),
        medications: <Medication>[
          _med('m1', 'Donepezil', '10 mg'),
          _med('m2', 'Memantine', '5 mg'),
        ],
        windows: <DoseWindow>[
          _window('w1', 'Morning', const TimeOfDay(hour: 8, minute: 0), 0),
          _window('w2', 'Evening', const TimeOfDay(hour: 20, minute: 0), 1),
        ],
        windowEntries: const <String, List<String>>{
          'w1': <String>['Donepezil'],
          'w2': <String>['Memantine'],
        },
        appointments: <ChatContextAppointment>[
          ChatContextAppointment(
            providerName: 'Neurology',
            startsAt: DateTime(2026, 6, 20, 14, 0),
            location: 'Clinic',
          ),
        ],
        routines: <CarePlanRoutine>[
          _routine('Morning hygiene', const TimeOfDay(hour: 7, minute: 30)),
        ],
        recentHealthNotes: const <String>['vitals: BP 128 over 82'],
      ));

      expect(out, startsWith('CURRENT DATA'));
      expect(out, contains("Loved one: Mary, 78, Alzheimer's."));
      expect(out, contains('Allergies: Penicillin.'));
      expect(out, contains('Medications: Donepezil 10 mg; Memantine 5 mg.'));
      expect(out, contains('Morning 8:00 AM (Donepezil)'));
      expect(out, contains('Evening 8:00 PM (Memantine)'));
      expect(out, contains('Upcoming appointments: Neurology — Jun 20 '
          '2:00 PM at Clinic.'));
      expect(out, contains('Routines: Morning hygiene 7:30 AM.'));
      expect(out, contains('Health log (newest first): vitals: BP 128 over 82.'));
    });

    test('as-needed window renders without a clock time', () {
      final String out = formatChatContext(ChatContextData(
        patient: _patient(),
        windows: <DoseWindow>[_window('w', 'As needed', null, 0)],
      ));
      expect(out, contains('As needed As needed'));
    });

    test('omits allergies line when none on file', () {
      final String out = formatChatContext(ChatContextData(
        patient: _patient(allergies: const <String>[]),
      ));
      expect(out, isNot(contains('Allergies:')));
      expect(out, contains('Loved one: Mary, 78'));
    });

    test('caps medications and shows a +N more tail', () {
      final List<Medication> many = <Medication>[
        for (int i = 0; i < 15; i++) _med('m$i', 'Med$i', '1 mg'),
      ];
      final String out =
          formatChatContext(ChatContextData(medications: many));
      // 12 shown, 3 elided.
      expect(out, contains('+3 more'));
      expect(out, contains('Med0 1 mg'));
      expect(out, contains('Med11 1 mg'));
      expect(out, isNot(contains('Med12 1 mg')));
    });
  });

  group('formatChatContext — empty / degraded', () {
    test('empty data degrades to a short, safe block (no throw)', () {
      final String out = formatChatContext(const ChatContextData());
      expect(out, startsWith('CURRENT DATA'));
      expect(out, contains('Loved one: none on file yet.'));
      expect(out, contains('Medications: none on file.'));
      expect(out, contains('Dose windows: none set.'));
      expect(out, contains('Upcoming appointments: none scheduled.'));
      // Routines / health-log lines are omitted entirely when empty.
      expect(out, isNot(contains('Routines:')));
      expect(out, isNot(contains('Health log')));
    });
  });
}
