import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show TimeOfDay;
// `Provider` from the appointment model collides with riverpod's `Provider`;
// the seeder only needs `ProviderContainer`/`*.read`, so hide riverpod's.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;

import '../models/appointment.dart';
import '../models/care_circle_membership.dart';
import '../models/care_event.dart';
import '../models/care_plan_routine.dart';
import '../models/care_shift.dart';
import '../models/care_task.dart';
import '../models/caregiver.dart';
import '../models/chat.dart';
import '../models/document.dart';
import '../models/expense.dart';
import '../models/forum.dart' show CircleMemberDto;
import '../models/health_log_entry.dart';
import '../models/journal_entry.dart';
import '../models/medication.dart';
import '../providers/care_circle_provider.dart'
    show CareCircleRepository, careCircleRepositoryProvider;
import '../providers/circle_member_cache_provider.dart'
    show CircleMemberCacheRepository, circleMemberCacheRepositoryProvider;
import '../providers/care_events_provider.dart'
    show CareEventsRepository, careEventsRepositoryProvider;
import '../providers/care_plan_provider.dart'
    show CarePlanRepository, carePlanRepositoryProvider;
import '../providers/care_shifts_provider.dart'
    show CareShiftsRepository, careShiftsRepositoryProvider;
import '../providers/care_tasks_provider.dart'
    show CareTasksRepository, careTasksRepositoryProvider, currentCaregiverIdProvider;
import '../providers/documents_provider.dart'
    show DocumentsRepository, documentsRepositoryProvider;
import '../providers/expenses_provider.dart'
    show ExpensesRepository, expensesRepositoryProvider;
import '../providers/health_log_provider.dart'
    show HealthLogRepository, healthLogRepositoryProvider;
import '../providers/storage_provider.dart' show StorageProvider, storageProvider;
import '../services/appointment_repository.dart'
    show AppointmentRepository, appointmentRepositoryProvider;
import '../services/chat_repository.dart'
    show ChatRepository, chatRepositoryProvider;
import '../services/medication_repository.dart'
    show MedicationRepository, medicationRepositoryProvider;
import '../services/provider_repository.dart'
    show ProviderRepository, providerRepositoryProvider;
import 'mary_henderson.dart';

/// The canonical demo loved one's id — every patient-scoped row links to
/// it (matches the `*PatientId` constants the Care Team providers query by).
const String demoPatientId = 'demo-patient-mary';

/// How many days of DENSE daily medication dose-logs to generate back from
/// today. The cheaper data types (appointments, health log, journal,
/// expenses, shifts) span the full [_historyDays]; dose logs are the
/// highest-volume rows, so they're bounded here to keep the one-shot
/// boot-time seed snappy. Bump this if you want a longer adherence history.
const int _doseHistoryDays = 90;

/// How many days of history the broad (low-volume) data types span — six
/// months — and how far forward plans/appointments reach.
const int _historyDays = 182;

/// Seeds a thorough, six-months-back / one-month-forward dataset across
/// EVERY data type the app stores, so an alpha tester can exercise the
/// whole app against realistic volume. Deterministic (fixed PRNG seed) so
/// reruns produce the same shape; all dates are anchored to [_clock] so the
/// data always reads as "recent".
///
/// Construct with concrete repositories (see [seedDemoDataset] for the
/// production wiring that pulls them off a [ProviderContainer]); a unit
/// test builds them against an in-memory database. Call [seedAll] on a
/// freshly-wiped database — this class only writes, it never clears.
class DemoDatasetSeeder {
  DemoDatasetSeeder({
    required this.storage,
    required this.medications,
    required this.appointments,
    required this.providers,
    required this.healthLog,
    required this.carePlan,
    required this.careTasks,
    required this.careShifts,
    required this.expenses,
    required this.careCircle,
    required this.circleMemberCache,
    required this.careEvents,
    required this.documents,
    required this.chat,
    String? currentCaregiverId,
    DateTime Function()? clock,
  })  : currentCaregiverId = currentCaregiverId ?? 'demo-caregiver-me',
        _clock = clock ?? DateTime.now;

  final StorageProvider storage;
  final MedicationRepository medications;
  final AppointmentRepository appointments;
  final ProviderRepository providers;
  final HealthLogRepository healthLog;
  final CarePlanRepository carePlan;
  final CareTasksRepository careTasks;
  final CareShiftsRepository careShifts;
  final ExpensesRepository expenses;
  final CareCircleRepository careCircle;
  final CircleMemberCacheRepository circleMemberCache;
  final CareEventsRepository careEvents;
  final DocumentsRepository documents;
  final ChatRepository chat;

  /// Id of the signed-in caregiver — used as the owner of the circle and the
  /// claimer/payer on a slice of the team data so "you" resolves on screen.
  final String currentCaregiverId;

  final DateTime Function() _clock;
  final math.Random _rng = math.Random(20260610);

  // ---- Provider ids (healthcare) ----------------------------------------
  static const String _provNeuro = 'seed-prov-neuro';
  static const String _provPcp = 'seed-prov-pcp';
  static const String _provSocial = 'seed-prov-social';
  static const String _provDentist = 'seed-prov-dentist';

  // ---- Medication ids ----------------------------------------------------
  static const String _medDonepezil = 'seed-med-donepezil';
  static const String _medMemantine = 'seed-med-memantine';
  static const String _medSertraline = 'seed-med-sertraline';
  static const String _medVitD = 'seed-med-vitd';
  static const String _medMelatonin = 'seed-med-melatonin';
  static const String _medAmoxicillin = 'seed-med-amoxicillin';

  // ---- Dose window ids ---------------------------------------------------
  static const String _winMorning = 'seed-win-morning';
  static const String _winNoon = 'seed-win-noon';
  static const String _winEvening = 'seed-win-evening';
  static const String _winBedtime = 'seed-win-bedtime';
  static const String _winPrn = 'seed-win-prn';

  // ---- Caregiver ids -----------------------------------------------------
  static const String _cgSarah = 'seed-cg-sarah';
  static const String _cgDavid = 'seed-cg-david';
  static const String _cgRosa = 'seed-cg-rosa';
  static const String _cgLinda = 'seed-cg-linda';

  /// Run the whole seed. Sections are independent — a failure in one is
  /// logged and the rest still run, so a partial schema change never leaves
  /// the database empty.
  Future<void> seedAll() async {
    final DateTime t0 = _clock();
    await _run('patient', _seedPatient);
    await _run('providers', _seedProviders);
    await _run('medications', _seedMedicationsAndDoses);
    await _run('appointments', _seedAppointments);
    await _run('health-log', _seedHealthLog);
    await _run('care-plan', _seedCarePlan);
    await _run('journal', _seedJournal);
    await _run('care-circle', _seedCareCircle);
    await _run('tasks', _seedTasks);
    await _run('shifts', _seedShifts);
    await _run('expenses', _seedExpenses);
    await _run('care-notes', _seedCareNotes);
    await _run('documents', _seedDocuments);
    await _run('chat', _seedChat);
    final int ms = _clock().difference(t0).inMilliseconds;
    debugPrint('DemoDatasetSeeder: seeded full dataset in ${ms}ms');
  }

  Future<void> _run(String label, Future<void> Function() section) async {
    try {
      await section();
    } catch (e, st) {
      debugPrint('DemoDatasetSeeder: section "$label" failed: $e\n$st');
    }
  }

  // ---- Time helpers ------------------------------------------------------

  DateTime get _now => _clock();
  DateTime get _today {
    final DateTime n = _now;
    return DateTime(n.year, n.month, n.day);
  }

  DateTime _daysAgo(int d) => _today.subtract(Duration(days: d));
  DateTime _daysAhead(int d) => _today.add(Duration(days: d));
  DateTime _at(DateTime day, int hour, int minute) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  int _between(int lo, int hi) => lo + _rng.nextInt(hi - lo + 1);

  // ---- Patient -----------------------------------------------------------

  Future<void> _seedPatient() async {
    await storage.upsertPatient(maryHenderson());
  }

  // ---- Providers ---------------------------------------------------------

  Future<void> _seedProviders() async {
    await providers.upsertProvider(const Provider(
      id: _provNeuro,
      name: 'Dr. Elena Ortega',
      role: ProviderRole.neurologist,
      phone: '(415) 555-0188',
      address: '2200 Bridgeway, Sausalito, CA',
      notes: 'Memory clinic — check in at 3rd-floor desk. Parking validated.',
    ));
    await providers.upsertProvider(const Provider(
      id: _provPcp,
      name: 'Dr. James Park',
      role: ProviderRole.doctor,
      phone: '(415) 555-0142',
      address: '1300 Sir Francis Drake Blvd, San Anselmo, CA',
      notes: 'Primary care. Portal messages answered within a day.',
    ));
    await providers.upsertProvider(const Provider(
      id: _provSocial,
      name: 'Tanya Brooks, LCSW',
      role: ProviderRole.socialWorker,
      phone: '(415) 555-0107',
      address: 'Marin Adult & Aging Services',
      notes: 'Respite-care navigator. Sliding-scale paperwork on file.',
    ));
    await providers.upsertProvider(const Provider(
      id: _provDentist,
      name: 'Dr. Priya Nair, DDS',
      role: ProviderRole.other,
      phone: '(415) 555-0163',
      address: '850 Magnolia Ave, Larkspur, CA',
      notes: 'Gentle-dentistry practice; books a double slot for Mary.',
    ));
  }

  // ---- Medications + dose windows + entries + logs -----------------------

  Future<void> _seedMedicationsAndDoses() async {
    // Live medications.
    await medications.upsertMedication(const Medication(
      id: _medDonepezil,
      name: 'Lisinopril',
      dosage: '10 mg',
      route: MedicationRoute.oral,
      prescriber: 'Dr. Elena Ortega',
      notes: 'Take in the morning with breakfast. For blood pressure.',
    ));
    await medications.upsertMedication(const Medication(
      id: _medMemantine,
      name: 'Atorvastatin',
      dosage: '20 mg',
      route: MedicationRoute.oral,
      prescriber: 'Dr. Elena Ortega',
      notes: 'Take in the evening.',
    ));
    await medications.upsertMedication(const Medication(
      id: _medSertraline,
      name: 'Aspirin',
      dosage: '81 mg',
      route: MedicationRoute.oral,
      prescriber: 'Dr. James Park',
      notes: 'Low-dose, for stroke prevention.',
    ));
    await medications.upsertMedication(const Medication(
      id: _medVitD,
      name: 'Vitamin D3',
      dosage: '2000 IU',
      route: MedicationRoute.oral,
    ));
    await medications.upsertMedication(const Medication(
      id: _medMelatonin,
      name: 'Melatonin',
      dosage: '3 mg',
      route: MedicationRoute.oral,
      notes: 'As needed at bedtime for restless nights.',
    ));
    // An ENDED course — drops out of the live list, exercises the
    // ended-medication filter. Finished ~5 months ago.
    await medications.upsertMedication(Medication(
      id: _medAmoxicillin,
      name: 'Amoxicillin',
      dosage: '500 mg',
      route: MedicationRoute.oral,
      prescriber: 'Dr. James Park',
      notes: 'UTI — 10-day course (completed).',
      endsAt: _daysAgo(150),
    ));

    // Dose windows (Morning / Noon / Evening / Bedtime / As needed).
    await medications.upsertWindow(const DoseWindow(
      id: _winMorning,
      patientId: demoPatientId,
      label: 'Morning',
      anchorTime: TimeOfDay(hour: 8, minute: 0),
      sortOrder: 0,
    ));
    await medications.upsertWindow(const DoseWindow(
      id: _winNoon,
      patientId: demoPatientId,
      label: 'Noon',
      anchorTime: TimeOfDay(hour: 12, minute: 30),
      sortOrder: 1,
    ));
    await medications.upsertWindow(const DoseWindow(
      id: _winEvening,
      patientId: demoPatientId,
      label: 'Evening',
      anchorTime: TimeOfDay(hour: 18, minute: 0),
      sortOrder: 2,
    ));
    await medications.upsertWindow(const DoseWindow(
      id: _winBedtime,
      patientId: demoPatientId,
      label: 'Bedtime',
      anchorTime: TimeOfDay(hour: 21, minute: 0),
      sortOrder: 3,
    ));
    await medications.upsertWindow(const DoseWindow(
      id: _winPrn,
      patientId: demoPatientId,
      label: 'As needed',
      sortOrder: 4,
    ));

    // Membership: which med fires in which window. (medId, windowId, hour, min)
    final DateTime start = _daysAgo(_historyDays);
    final List<({String med, String win, int hour, int min})> schedule =
        <({String med, String win, int hour, int min})>[
      (med: _medDonepezil, win: _winMorning, hour: 8, min: 0),
      (med: _medSertraline, win: _winMorning, hour: 8, min: 0),
      (med: _medVitD, win: _winMorning, hour: 8, min: 0),
      (med: _medMemantine, win: _winEvening, hour: 18, min: 0),
    ];
    for (final ({String med, String win, int hour, int min}) s in schedule) {
      await medications.upsertEntry(MedicationWindowEntry(
        id: 'seed-mwe-${s.med}-${s.win}',
        medicationId: s.med,
        windowId: s.win,
        daysOfWeek: const <int>{},
        startsOn: start,
      ));
    }
    // Melatonin lives in the as-needed window (never auto-scheduled).
    await medications.upsertEntry(MedicationWindowEntry(
      id: 'seed-mwe-melatonin-prn',
      medicationId: _medMelatonin,
      windowId: _winPrn,
      daysOfWeek: const <int>{},
      startsOn: start,
    ));

    // Daily dose logs for the scheduled meds over the recent window, with a
    // realistic adherence mix (mostly taken, some late / missed / skipped).
    for (final ({String med, String win, int hour, int min}) s in schedule) {
      for (int d = _doseHistoryDays; d >= 0; d--) {
        final DateTime slot = _at(_daysAgo(d), s.hour, s.min);
        // Don't log a dose whose window hasn't arrived yet today.
        if (slot.isAfter(_now)) continue;
        await medications.upsertDoseLog(_doseLogFor(s.med, s.win, slot));
      }
    }

    // A handful of ad-hoc Melatonin doses on restless nights.
    for (int i = 0; i < 12; i++) {
      final DateTime night = _at(_daysAgo(_between(1, 60)), 21, _between(0, 45));
      await medications.upsertDoseLog(DoseLog(
        id: 'seed-dose-melatonin-$i',
        medicationId: _medMelatonin,
        scheduledFor: night,
        takenAt: night,
        status: DoseStatus.taken,
        notes: i.isEven ? 'Restless — gave at bedtime.' : null,
      ));
    }
  }

  DoseLog _doseLogFor(String medId, String winId, DateTime slot) {
    final double roll = _rng.nextDouble();
    final String id =
        'seed-dose-$medId-$winId-${slot.year}${_pad(slot.month)}${_pad(slot.day)}';
    if (roll < 0.86) {
      return DoseLog(
        id: id,
        medicationId: medId,
        scheduledFor: slot,
        takenAt: slot.add(Duration(minutes: _between(0, 20))),
        status: DoseStatus.taken,
      );
    }
    if (roll < 0.92) {
      return DoseLog(
        id: id,
        medicationId: medId,
        scheduledFor: slot,
        takenAt: slot.add(Duration(minutes: _between(90, 240))),
        status: DoseStatus.late,
      );
    }
    if (roll < 0.97) {
      return DoseLog(
        id: id,
        medicationId: medId,
        scheduledFor: slot,
        status: DoseStatus.missed,
      );
    }
    return DoseLog(
      id: id,
      medicationId: medId,
      scheduledFor: slot,
      status: DoseStatus.skipped,
      notes: 'Asleep — held the dose.',
    );
  }

  // ---- Appointments ------------------------------------------------------

  Future<void> _seedAppointments() async {
    // Past, completed visits across the six months.
    final List<({String id, String prov, int daysAgo, int dur, String loc,
            List<String> agenda, Set<int> done, String? notes})> past =
        <({String id, String prov, int daysAgo, int dur, String loc,
            List<String> agenda, Set<int> done, String? notes})>[
      (
        id: 'seed-appt-neuro-1', prov: _provNeuro, daysAgo: 168, dur: 45,
        loc: 'Memory Clinic, 3rd floor',
        agenda: <String>['Review MMSE trend', 'Ask about sundowning',
            'Renew Lisinopril'],
        done: <int>{0, 1, 2},
        notes: 'MMSE stable. Keep evening routine consistent. Refill sent.',
      ),
      (
        id: 'seed-appt-pcp-1', prov: _provPcp, daysAgo: 132, dur: 30,
        loc: 'San Anselmo office',
        agenda: <String>['Blood pressure check', 'Flu shot', 'Review meds'],
        done: <int>{0, 1, 2},
        notes: 'BP a touch high; recheck at home. Flu shot given.',
      ),
      (
        id: 'seed-appt-social-1', prov: _provSocial, daysAgo: 96, dur: 60,
        loc: 'Aging Services (phone)',
        agenda: <String>['Respite options', 'Adult day program tour'],
        done: <int>{0},
        notes: 'Day program has a Tuesday opening — touring next month.',
      ),
      (
        id: 'seed-appt-neuro-2', prov: _provNeuro, daysAgo: 54, dur: 45,
        loc: 'Memory Clinic, 3rd floor',
        agenda: <String>['Discuss Atorvastatin dose', 'Sleep concerns'],
        done: <int>{0, 1},
        notes: 'Holding Atorvastatin at 20mg. Try melatonin as needed.',
      ),
      (
        id: 'seed-appt-pcp-2', prov: _provPcp, daysAgo: 21, dur: 30,
        loc: 'San Anselmo office',
        agenda: <String>['Lab review', 'Vitamin D level'],
        done: <int>{0},
        notes: 'Vitamin D low-normal; continue supplement.',
      ),
    ];
    for (final p in past) {
      await appointments.upsertAppointment(Appointment(
        id: p.id,
        providerId: p.prov,
        startsAt: _at(_daysAgo(p.daysAgo), 10, 30),
        durationMinutes: p.dur,
        location: p.loc,
        agenda: p.agenda,
        status: AppointmentStatus.completed,
        completedAgendaIndices: p.done,
        notes: p.notes,
      ));
    }

    // Upcoming visits in the next month.
    await appointments.upsertAppointment(Appointment(
      id: 'seed-appt-neuro-next',
      providerId: _provNeuro,
      startsAt: _at(_daysAhead(9), 11, 0),
      durationMinutes: 45,
      location: 'Memory Clinic, 3rd floor',
      agenda: const <String>['Six-month follow-up', 'Ask about agitation',
          'Caregiver support resources'],
      status: AppointmentStatus.upcoming,
      driverName: 'Sarah',
    ));
    await appointments.upsertAppointment(Appointment(
      id: 'seed-appt-dentist-next',
      providerId: _provDentist,
      startsAt: _at(_daysAhead(16), 9, 30),
      durationMinutes: 60,
      location: 'Larkspur office',
      agenda: const <String>['Cleaning', 'Check sore spot lower-left'],
      status: AppointmentStatus.upcoming,
      driverName: 'Rosa',
    ));
    await appointments.upsertAppointment(Appointment(
      id: 'seed-appt-pcp-next',
      providerId: _provPcp,
      startsAt: _at(_daysAhead(27), 14, 15),
      durationMinutes: 30,
      location: 'San Anselmo office',
      agenda: const <String>['BP recheck', 'Medication review'],
      status: AppointmentStatus.upcoming,
    ));
  }

  // ---- Health log --------------------------------------------------------

  Future<void> _seedHealthLog() async {
    int n = 0;
    // An entry roughly every three days across the six months.
    for (int d = _historyDays; d >= 0; d -= 3) {
      final DateTime when = _at(_daysAgo(d), _between(7, 20), _between(0, 59));
      final int kindRoll = n % 3;
      if (kindRoll == 0) {
        // Vitals.
        await healthLog.upsert(HealthLogEntry(
          id: 'seed-health-$n',
          patientId: demoPatientId,
          recordedAt: when,
          kind: HealthLogKind.vitals,
          systolic: _between(118, 148),
          diastolic: _between(68, 92),
          heartRate: _between(58, 86),
          temperatureF:
              n % 6 == 0 ? 97.4 + _rng.nextInt(22) / 10.0 : null,
          glucoseMgDl: n % 9 == 0 ? _between(92, 134) : null,
          notes: n % 6 == 0 ? 'Took readings after breakfast.' : null,
        ));
      } else if (kindRoll == 1) {
        // Symptom.
        const List<String> symptoms = <String>[
          'More confused in the late afternoon.',
          'Restless and pacing before dinner.',
          'Good day — chatty and calm.',
          'Poor appetite at lunch.',
          'Slept poorly, up twice overnight.',
          'Tearful in the morning, settled after a walk.',
        ];
        await healthLog.upsert(HealthLogEntry(
          id: 'seed-health-$n',
          patientId: demoPatientId,
          recordedAt: when,
          kind: HealthLogKind.symptom,
          severity: _between(1, 5),
          notes: symptoms[n % symptoms.length],
        ));
      } else {
        // Free-text note.
        const List<String> notes = <String>[
          'Enjoyed looking through the photo album together.',
          'Refused lunch but ate a good dinner.',
          'Daughter visited — lifted her spirits.',
          'New aide started; Mary warmed up by the afternoon.',
          'Quiet day. Watched the garden for a long while.',
        ];
        await healthLog.upsert(HealthLogEntry(
          id: 'seed-health-$n',
          patientId: demoPatientId,
          recordedAt: when,
          kind: HealthLogKind.note,
          notes: notes[n % notes.length],
        ));
      }
      n++;
    }
  }

  // ---- Care plan routines ------------------------------------------------

  Future<void> _seedCarePlan() async {
    final DateTime start = _daysAgo(_historyDays);
    await carePlan.upsert(CarePlanRoutine(
      id: 'seed-routine-morning',
      patientId: demoPatientId,
      title: 'Morning routine',
      body: 'Calm, unhurried start to the day.',
      scheduledTime: const TimeOfDay(hour: 7, minute: 30),
      frequencyKind: FrequencyKind.daily,
      daysOfWeek: const <int>{},
      startsOn: start,
      subtasks: const <String>['Bathroom', 'Wash face & brush teeth',
          'Get dressed', 'Breakfast + morning meds'],
    ));
    await carePlan.upsert(CarePlanRoutine(
      id: 'seed-routine-lunch',
      patientId: demoPatientId,
      title: 'Lunch & midday check-in',
      body: 'Lunch, hydration, and a short rest.',
      scheduledTime: const TimeOfDay(hour: 12, minute: 30),
      frequencyKind: FrequencyKind.daily,
      daysOfWeek: const <int>{},
      startsOn: start,
      subtasks: const <String>['Lunch', 'Glass of water', 'Short rest'],
    ));
    await carePlan.upsert(CarePlanRoutine(
      id: 'seed-routine-walk',
      patientId: demoPatientId,
      title: 'Afternoon walk',
      body: 'Gentle walk around the block before the late-day restlessness.',
      scheduledTime: const TimeOfDay(hour: 15, minute: 0),
      frequencyKind: FrequencyKind.weekly,
      daysOfWeek: const <int>{1, 3, 5},
      startsOn: start,
    ));
    await carePlan.upsert(CarePlanRoutine(
      id: 'seed-routine-winddown',
      patientId: demoPatientId,
      title: 'Evening wind-down',
      body: 'Head off sundowning with a predictable, soothing evening.',
      scheduledTime: const TimeOfDay(hour: 20, minute: 0),
      frequencyKind: FrequencyKind.daily,
      daysOfWeek: const <int>{},
      startsOn: start,
      subtasks: const <String>['Dim the lights', 'Calming playlist',
          'Herbal tea', 'Bedtime meds'],
    ));
    await carePlan.upsert(CarePlanRoutine(
      id: 'seed-routine-bath',
      patientId: demoPatientId,
      title: 'Bath',
      body: 'Warm towel first, then the rest of the routine.',
      scheduledTime: const TimeOfDay(hour: 18, minute: 30),
      frequencyKind: FrequencyKind.weekly,
      daysOfWeek: const <int>{2, 6},
      startsOn: start,
    ));
  }

  // ---- Journal -----------------------------------------------------------

  Future<void> _seedJournal() async {
    // A recent cluster (last 7 days) so the journal opens populated, plus
    // a spread of caregiver-authored entries back through the months.
    await _journalEntry('seed-j-1',
        _now.subtract(const Duration(days: 1, hours: 4)),
        situation: 'Restless and anxious as the light faded — kept getting '
            'up and pacing the hallway.',
        attempts: 'Dimmed the lamps and put on the Sunday playlist.',
        notes: 'Settled within ten minutes.');
    await _journalEntry('seed-j-2',
        _now.subtract(const Duration(days: 3, hours: 5)),
        situation: 'Unsettled in the evening after the visitors left.',
        attempts: 'Took a slow walk to the kitchen for tea and a snack.');
    await _journalEntry('seed-j-3',
        _now.subtract(const Duration(days: 5, hours: 6)),
        situation: 'Agitated late in the day and didn\'t want company.',
        attempts: 'Gave her quiet space, then checked back in.');

    // A rotating spread of realistic moments back through the months.
    const List<({String situation, String attempts})> spread =
        <({String situation, String attempts})>[
      (
        situation: 'Refused help with the morning routine.',
        attempts: 'Offered the warm-towel-first detour; she came around.',
      ),
      (
        situation: 'Kept saying she wanted to "go home" even though she was.',
        attempts: 'Validated the feeling, then redirected to a cup of tea.',
      ),
      (
        situation: 'Asked for her mother several times.',
        attempts: 'Sat with her and the old photo album.',
      ),
      (
        situation: 'Convinced I had hidden her purse and got upset.',
        attempts: 'Didn\'t argue — helped her look and we found it together.',
      ),
      (
        situation: 'Wandered toward the front door after dark.',
        attempts: 'Walked with her and gently looped back to the kitchen.',
      ),
      (
        situation: 'Said she could see people in the garden who weren\'t there.',
        attempts: 'Stayed calm, drew the curtains, changed the subject.',
      ),
      (
        situation: 'Teary and overwhelmed for no clear reason.',
        attempts: 'Held her hand and just stayed close for a while.',
      ),
    ];
    for (int i = 0; i < 14; i++) {
      final ({String situation, String attempts}) m =
          spread[i % spread.length];
      final int daysAgo = 10 + i * 12;
      await _journalEntry('seed-j-spread-$i',
          _at(_daysAgo(daysAgo), _between(8, 19), _between(0, 59)),
          situation: m.situation, attempts: m.attempts);
    }

    // A few entries that lean on the optional notes field / small wins.
    const List<({String situation, String attempts, String? notes})> extra =
        <({String situation, String attempts, String? notes})>[
      (
        situation: 'Mom kept asking to call her mother this afternoon.',
        attempts: 'Sat with her and looked at old photos instead of correcting.',
        notes: 'Calmed down after a few minutes.',
      ),
      (
        situation: 'She did not recognize the living room and got frightened.',
        attempts: 'Spoke softly, opened the curtains, made tea.',
        notes: null,
      ),
      (
        situation: 'Good morning — she sang along to the radio.',
        attempts: 'Just enjoyed it with her.',
        notes: 'Worth remembering the small wins.',
      ),
    ];
    for (int i = 0; i < extra.length; i++) {
      final DateTime when = _at(_daysAgo(8 + i * 30), 11, 0);
      await _journalEntry('seed-j-extra-$i', when,
          situation: extra[i].situation,
          attempts: extra[i].attempts,
          notes: extra[i].notes);
    }
  }

  Future<void> _journalEntry(
    String id,
    DateTime createdAt, {
    String? situation,
    String? attempts,
    String? notes,
  }) async {
    await storage.insertJournalEntry(JournalEntry.wizard(
      id: id,
      createdAt: createdAt,
      occurredAt: createdAt,
      situationText: situation,
      attemptsText: attempts,
      notes: notes,
    ));
  }

  // ---- Care circle -------------------------------------------------------

  Future<void> _seedCareCircle() async {
    // "Me" — the signed-in caregiver, circle owner.
    await careCircle.upsertCaregiver(Caregiver(
      id: currentCaregiverId,
      displayName: 'You',
      role: CaregiverRole.primary,
      phone: '(415) 555-0100',
    ));
    await careCircle.upsertMembership(CareCircleMembership(
      id: 'seed-mem-me',
      caregiverId: currentCaregiverId,
      patientId: demoPatientId,
      permissionLevel: PermissionLevel.owner,
      invitedAt: _daysAgo(_historyDays),
      acceptedAt: _daysAgo(_historyDays),
    ));

    await careCircle.upsertCaregiver(const Caregiver(
      id: _cgSarah,
      displayName: 'Sarah Henderson',
      role: CaregiverRole.child,
      phone: '(415) 555-0142',
      email: 'sarah.h@example.com',
    ));
    await careCircle.upsertMembership(CareCircleMembership(
      id: 'seed-mem-sarah',
      caregiverId: _cgSarah,
      patientId: demoPatientId,
      permissionLevel: PermissionLevel.editor,
      invitedAt: _daysAgo(170),
      acceptedAt: _daysAgo(169),
    ));

    await careCircle.upsertCaregiver(const Caregiver(
      id: _cgDavid,
      displayName: 'David Henderson',
      role: CaregiverRole.sibling,
      phone: '(415) 555-0155',
    ));
    await careCircle.upsertMembership(CareCircleMembership(
      id: 'seed-mem-david',
      caregiverId: _cgDavid,
      patientId: demoPatientId,
      permissionLevel: PermissionLevel.viewer,
      invitedAt: _daysAgo(120),
      acceptedAt: _daysAgo(118),
    ));

    await careCircle.upsertCaregiver(const Caregiver(
      id: _cgRosa,
      displayName: 'Rosa Diaz',
      role: CaregiverRole.aide,
      phone: '(415) 555-0176',
      email: 'rosa.diaz@example.com',
    ));
    await careCircle.upsertMembership(CareCircleMembership(
      id: 'seed-mem-rosa',
      caregiverId: _cgRosa,
      patientId: demoPatientId,
      permissionLevel: PermissionLevel.editor,
      invitedAt: _daysAgo(60),
      acceptedAt: _daysAgo(59),
    ));

    // A still-pending invite.
    await careCircle.upsertCaregiver(const Caregiver(
      id: _cgLinda,
      displayName: 'Linda Park',
      role: CaregiverRole.friend,
      email: 'linda.park@example.com',
    ));
    await careCircle.upsertMembership(CareCircleMembership(
      id: 'seed-mem-linda',
      caregiverId: _cgLinda,
      patientId: demoPatientId,
      permissionLevel: PermissionLevel.viewer,
      invitedAt: _daysAgo(4),
    ));

    // Mirror the accepted roster into the local backend-circle CACHE so the
    // (local-first) Care Circle "People" screen shows them too — that screen
    // reads the cache, not the local caregiver table (which only resolves
    // names on shifts/tasks/expenses).
    await circleMemberCache.replaceForCircle('seed-circle', <CircleMemberDto>[
      CircleMemberDto(
        profileId: currentCaregiverId,
        username: 'you',
        displayName: 'You',
        role: 'owner',
      ),
      const CircleMemberDto(
        profileId: _cgSarah,
        username: 'sarah_h',
        displayName: 'Sarah Henderson',
        role: 'member',
      ),
      const CircleMemberDto(
        profileId: _cgDavid,
        displayName: 'David Henderson',
        role: 'member',
      ),
      const CircleMemberDto(
        profileId: _cgRosa,
        username: 'rosa_d',
        displayName: 'Rosa Diaz',
        role: 'member',
      ),
    ], clock: _clock);
  }

  List<String> get _allCaregiverIds =>
      <String>[currentCaregiverId, _cgSarah, _cgDavid, _cgRosa];

  // ---- Tasks -------------------------------------------------------------

  Future<void> _seedTasks() async {
    // A mix of open / claimed / done, some dated, some bundled under a
    // routine, spread before + after today.
    final List<({String title, String? body, int dueDelta, String? assignee,
            int? claimedAgo, int? completedAgo, String? routine})> rows =
        <({String title, String? body, int dueDelta, String? assignee,
            int? claimedAgo, int? completedAgo, String? routine})>[
      (title: 'Refill Lisinopril prescription', body: 'Call pharmacy — 1 refill left.',
          dueDelta: 3, assignee: null, claimedAgo: null, completedAgo: null,
          routine: null),
      (title: 'Pick up incontinence supplies', body: null,
          dueDelta: 1, assignee: _cgRosa, claimedAgo: 1, completedAgo: null,
          routine: null),
      (title: 'Schedule day-program tour', body: 'Tanya said Tuesdays are open.',
          dueDelta: 6, assignee: currentCaregiverId, claimedAgo: 2,
          completedAgo: null, routine: null),
      (title: 'Buy non-slip bath mat', body: null,
          dueDelta: -2, assignee: _cgSarah, claimedAgo: 5, completedAgo: 2,
          routine: null),
      (title: 'Update emergency contact list', body: 'Add Rosa.',
          dueDelta: -10, assignee: currentCaregiverId, claimedAgo: 12,
          completedAgo: 9, routine: null),
      (title: 'Label kitchen cabinets', body: 'Pictures + words.',
          dueDelta: 4, assignee: null, claimedAgo: null, completedAgo: null,
          routine: null),
      (title: 'Set up medication lockbox', body: null,
          dueDelta: -30, assignee: _cgDavid, claimedAgo: 33, completedAgo: 28,
          routine: null),
      (title: 'Morning: lay out clothes', body: null,
          dueDelta: 0, assignee: _cgRosa, claimedAgo: 0, completedAgo: null,
          routine: 'seed-routine-morning'),
      (title: 'Evening: prep herbal tea', body: null,
          dueDelta: 0, assignee: null, claimedAgo: null, completedAgo: null,
          routine: 'seed-routine-winddown'),
      (title: 'Confirm ride for neurology visit', body: 'Sarah driving.',
          dueDelta: 9, assignee: _cgSarah, claimedAgo: 1, completedAgo: null,
          routine: null),
    ];
    for (int i = 0; i < rows.length; i++) {
      final r = rows[i];
      await careTasks.upsertTask(CareTask(
        id: 'seed-task-$i',
        title: r.title,
        body: r.body,
        routineId: r.routine,
        dueAt: r.routine == null ? _at(_daysAhead(r.dueDelta), 12, 0) : null,
        assigneeCaregiverId: r.assignee,
        claimedAt: r.claimedAgo == null ? null : _daysAgo(r.claimedAgo!),
        completedAt: r.completedAgo == null ? null : _daysAgo(r.completedAgo!),
        patientId: demoPatientId,
      ));
    }
  }

  // ---- Shifts ------------------------------------------------------------

  Future<void> _seedShifts() async {
    // Coverage for the last three weeks and the next two — daytime aide,
    // evening family, with the odd gap to exercise the gap finder.
    final List<String> rotation = <String>[_cgRosa, _cgSarah, currentCaregiverId,
        _cgDavid];
    int n = 0;
    for (int d = 21; d >= -14; d--) {
      final DateTime day = _daysAgo(d);
      // Daytime aide shift most weekdays.
      if (day.weekday <= 5) {
        await careShifts.upsertShift(CareShift(
          id: 'seed-shift-day-$n',
          caregiverId: _cgRosa,
          start: _at(day, 9, 0),
          end: _at(day, 15, 0),
          patientId: demoPatientId,
          notes: n % 4 == 0 ? 'Lunch + afternoon walk.' : null,
        ));
        n++;
      }
      // Evening family shift, rotating, not every night (leaves gaps).
      if (d % 2 == 0) {
        await careShifts.upsertShift(CareShift(
          id: 'seed-shift-eve-$n',
          caregiverId: rotation[n % rotation.length],
          start: _at(day, 17, 0),
          end: _at(day, 22, 0),
          patientId: demoPatientId,
        ));
        n++;
      }
    }
  }

  // ---- Expenses ----------------------------------------------------------

  Future<void> _seedExpenses() async {
    const List<({String desc, int cents, ExpenseKind kind})> kinds =
        <({String desc, int cents, ExpenseKind kind})>[
      (desc: 'Pharmacy — monthly medications', cents: 8400, kind: ExpenseKind.meds),
      (desc: 'Groceries + soft foods', cents: 11250, kind: ExpenseKind.groceries),
      (desc: 'Ride to neurology', cents: 3200, kind: ExpenseKind.transport),
      (desc: 'Grab bars for bathroom', cents: 6500, kind: ExpenseKind.equipment),
      (desc: 'Home aide — week', cents: 42000, kind: ExpenseKind.aide),
      (desc: 'Incontinence supplies', cents: 5400, kind: ExpenseKind.other),
      (desc: 'Non-slip mat & nightlights', cents: 4300, kind: ExpenseKind.equipment),
      (desc: 'Day program deposit', cents: 15000, kind: ExpenseKind.other),
    ];
    final List<String> payers = _allCaregiverIds;
    int n = 0;
    // Roughly weekly across the six months.
    for (int d = _historyDays; d >= 0; d -= 5) {
      final ({String desc, int cents, ExpenseKind kind}) k = kinds[n % kinds.length];
      await expenses.upsertExpense(Expense(
        id: 'seed-expense-$n',
        amountCents: k.cents + _between(0, 1500),
        description: k.desc,
        paidByCaregiverId: payers[n % payers.length],
        paidAt: _at(_daysAgo(d), _between(9, 18), _between(0, 59)),
        kind: k.kind,
        patientId: demoPatientId,
      ));
      n++;
    }
  }

  // ---- Native calendar notes --------------------------------------------

  Future<void> _seedCareNotes() async {
    const List<({String title, int dayDelta, int hour, String? subtitle})> notes =
        <({String title, int dayDelta, int hour, String? subtitle})>[
      (title: 'Hospice info session', dayDelta: 12, hour: 13,
          subtitle: 'Optional — learning about options early.'),
      (title: 'Daughter visiting from Portland', dayDelta: 5, hour: 10,
          subtitle: 'Sarah here Fri–Sun.'),
      (title: 'New aide orientation', dayDelta: -3, hour: 9, subtitle: null),
      (title: 'Family check-in call', dayDelta: 2, hour: 19,
          subtitle: 'Weekly Sunday call.'),
      (title: 'Pick up walker from rental', dayDelta: 8, hour: 11, subtitle: null),
    ];
    for (int i = 0; i < notes.length; i++) {
      final n = notes[i];
      final DateTime start = _at(_daysAhead(n.dayDelta), n.hour, 0);
      await careEvents.upsertEvent(CareEvent(
        id: 'seed-note-$i',
        kind: CareEventKind.note,
        title: n.title,
        start: start,
        end: start.add(const Duration(hours: 1)),
        patientId: demoPatientId,
        subtitle: n.subtitle,
      ));
    }
  }

  // ---- Documents ---------------------------------------------------------

  Future<void> _seedDocuments() async {
    await documents.upsertEmergencyCard(EmergencyCard(
      id: 'seed-doc-emergency',
      patientId: demoPatientId,
      updatedAt: _daysAgo(20),
      conditions: const <String>['Stroke recovery (ischemic, 2024)',
          'High blood pressure', 'High cholesterol'],
      medications: const <String>['Lisinopril 10 mg', 'Atorvastatin 20 mg',
          'Aspirin 81 mg', 'Vitamin D3 2000 IU'],
      allergies: const <String>['Penicillin'],
      emergencyContacts: const <EmergencyContact>[
        EmergencyContact(name: 'Sarah Henderson', relation: 'Daughter',
            phone: '(415) 555-0142'),
        EmergencyContact(name: 'David Henderson', relation: 'Son',
            phone: '(415) 555-0155'),
      ],
      insurance: const Insurance(carrier: 'Medicare + Blue Shield',
          policyNumber: '1EG4-TE5-MK72', groupNumber: 'CA-0098'),
      donorStatus: DonorStatus.donor,
    ));
    await documents.upsertPoa(PowerOfAttorneyDoc(
      id: 'seed-doc-poa',
      patientId: demoPatientId,
      updatedAt: _daysAgo(40),
      agentName: 'Sarah Henderson',
      scope: PoaScope.medical,
      effectiveDate: _daysAgo(400),
      alternateName: 'David Henderson',
    ));
    await documents.upsertId(IdentificationDoc(
      id: 'seed-doc-id-dl',
      patientId: demoPatientId,
      updatedAt: _daysAgo(40),
      kind: IdKind.driverLicense,
      idNumber: 'D1234567',
      expiresOn: _daysAhead(120),
    ));
    await documents.upsertId(IdentificationDoc(
      id: 'seed-doc-id-medicare',
      patientId: demoPatientId,
      updatedAt: _daysAgo(40),
      kind: IdKind.medicare,
      idNumber: '1EG4-TE5-MK72',
    ));
  }

  // ---- Chat --------------------------------------------------------------

  Future<void> _seedChat() async {
    await _conversation(
      'seed-convo-sundowning',
      'Sundowning at dinner',
      _daysAgo(2),
      <({bool user, String body})>[
        (user: true, body: 'Mom gets really agitated every evening around '
            'dinnertime. What can I do?'),
        (user: false, body: "That late-day restlessness is so common it has a "
            "name — sundowning. A few things help: keep the evening calm and "
            "predictable, turn lamps on before dusk so shadows don't confuse "
            "her, and offer a simple, soothing activity. Try not to start big "
            "tasks late in the day."),
        (user: true, body: 'She keeps saying she needs to "go pick up the kids."'),
        (user: false, body: "Step into her reality rather than correcting it. "
            "You might say, “The kids are taken care of — let's have a cup "
            "of tea while we wait.” Comfort the feeling behind the words; "
            "the facts matter less than her sense of safety."),
      ],
    );
    await _conversation(
      'seed-convo-bathing',
      'Refusing to bathe',
      _daysAgo(9),
      <({bool user, String body})>[
        (user: true, body: 'She refuses to take a bath. It turns into a fight '
            'every time.'),
        (user: false, body: "Bathing can feel cold, exposing, and confusing. "
            "Warm the room first, have towels ready, and try a warm-towel "
            "wash instead of a full bath on hard days. Offer choices — "
            "“washcloth or shower?” — so she keeps some control."),
      ],
    );
    await _conversation(
      'seed-convo-night',
      'Wandering at night',
      _daysAgo(15),
      <({bool user, String body})>[
        (user: true, body: 'I found her trying to leave the house at 2am. '
            "I'm scared."),
        (user: false, body: "That's frightening — you're right to take it "
            "seriously. A few safety steps: a door chime or alarm, motion "
            "nightlights to the bathroom, and keeping keys out of sight. "
            "During the day, more activity and light can improve nighttime "
            "sleep. If it keeps happening, mention it at the next neurology "
            "visit."),
      ],
    );
  }

  Future<void> _conversation(
    String id,
    String title,
    DateTime startedAt,
    List<({bool user, String body})> turns,
  ) async {
    await chat.createConversation(id: id, title: title, createdAt: startedAt);
    await chat.renameConversation(id, title);
    for (int i = 0; i < turns.length; i++) {
      final ({bool user, String body}) t = turns[i];
      await chat.appendMessage(Message(
        id: '$id-msg-$i',
        conversationId: id,
        role: t.user ? MessageRole.user : MessageRole.assistant,
        body: t.body,
        citations: const <String>[],
        createdAt: startedAt.add(Duration(minutes: i * 2)),
        streamingDone: true,
      ));
    }
  }

  String _pad(int v) => v.toString().padLeft(2, '0');
}

/// Production wiring: pull every repository off [container] and seed a full
/// demo dataset. Anchors all dates to the wall clock at call time. Call
/// AFTER the database has been wiped (see `maybeSeedDemoDataset` in main).
Future<void> seedDemoDataset(
  ProviderContainer container, {
  DateTime Function()? clock,
}) async {
  final DemoDatasetSeeder seeder = DemoDatasetSeeder(
    storage: container.read(storageProvider),
    medications: container.read(medicationRepositoryProvider),
    appointments: container.read(appointmentRepositoryProvider),
    providers: container.read(providerRepositoryProvider),
    healthLog: container.read(healthLogRepositoryProvider),
    carePlan: container.read(carePlanRepositoryProvider),
    careTasks: container.read(careTasksRepositoryProvider),
    careShifts: container.read(careShiftsRepositoryProvider),
    expenses: container.read(expensesRepositoryProvider),
    careCircle: container.read(careCircleRepositoryProvider),
    circleMemberCache: container.read(circleMemberCacheRepositoryProvider),
    careEvents: container.read(careEventsRepositoryProvider),
    documents: container.read(documentsRepositoryProvider),
    chat: container.read(chatRepositoryProvider),
    currentCaregiverId: container.read(currentCaregiverIdProvider),
    clock: clock,
  );
  await seeder.seedAll();
}
