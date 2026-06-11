import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_events_provider.dart';
import 'package:careblazers/providers/care_plan_provider.dart';
import 'package:careblazers/providers/care_shifts_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/providers/circle_member_cache_provider.dart';
import 'package:careblazers/providers/documents_provider.dart';
import 'package:careblazers/providers/expenses_provider.dart';
import 'package:careblazers/providers/health_log_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/seed/demo_dataset.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A fixed "now" so the relative-dated seed is deterministic.
  DateTime clock() => DateTime(2026, 6, 10, 9, 0);

  late CareblazersDatabase db;
  late DemoDatasetSeeder seeder;
  late StorageProvider storage;
  late MedicationRepository medications;
  late AppointmentRepository appointments;
  late ProviderRepository providers;
  late HealthLogRepository healthLog;
  late CarePlanRepository carePlan;
  late CareTasksRepository careTasks;
  late CareShiftsRepository careShifts;
  late ExpensesRepository expenses;
  late CareCircleRepository careCircle;
  late CircleMemberCacheRepository circleMemberCache;
  late CareEventsRepository careEvents;
  late DocumentsRepository documents;
  late ChatRepository chat;

  setUp(() async {
    db = CareblazersDatabase(NativeDatabase.memory());
    storage = DriftStorageProvider(db);
    medications = MedicationRepository(db, clock: clock);
    appointments = AppointmentRepository(db, clock: clock);
    providers = ProviderRepository(db);
    healthLog = HealthLogRepository(db);
    carePlan = CarePlanRepository(db);
    careTasks = CareTasksRepository(db);
    careShifts = CareShiftsRepository(db);
    expenses = ExpensesRepository(db);
    careCircle = CareCircleRepository(db);
    circleMemberCache = CircleMemberCacheRepository(db);
    careEvents = CareEventsRepository(db);
    documents = DocumentsRepository(db);
    chat = ChatRepository(db);
    seeder = DemoDatasetSeeder(
      storage: storage,
      medications: medications,
      appointments: appointments,
      providers: providers,
      healthLog: healthLog,
      carePlan: carePlan,
      careTasks: careTasks,
      careShifts: careShifts,
      expenses: expenses,
      careCircle: careCircle,
      circleMemberCache: circleMemberCache,
      careEvents: careEvents,
      documents: documents,
      chat: chat,
      currentCaregiverId: 'me-test',
      clock: clock,
    );
    await seeder.seedAll();
  });

  tearDown(() async {
    await db.close();
  });

  test('seeds the loved one', () async {
    final patient = await storage.getPatient();
    expect(patient, isNotNull);
    expect(patient!.id, demoPatientId);
  });

  test('seeds providers, medications, windows, and a dose history', () async {
    expect(await providers.listProviders(), hasLength(4));

    final List<Medication> meds = await medications.listMedications();
    // The ended Amoxicillin course is filtered out of the live list.
    expect(meds.map((Medication m) => m.name), contains('Donepezil'));
    expect(meds.map((Medication m) => m.name), isNot(contains('Amoxicillin')));

    expect(await medications.windowsForPatient(demoPatientId), hasLength(5));

    final Medication donepezil =
        meds.firstWhere((Medication m) => m.name == 'Donepezil');
    final List<DoseLog> logs =
        await medications.logsFor(donepezil.id);
    expect(logs.length, greaterThan(60),
        reason: 'expected a dense daily dose history');
    // Adherence is a realistic mix, not all taken.
    expect(logs.any((DoseLog l) => l.status == DoseStatus.taken), isTrue);
    expect(logs.any((DoseLog l) => l.status != DoseStatus.taken), isTrue);
    // No dose is logged in the future.
    expect(logs.every((DoseLog l) => !l.scheduledFor.isAfter(clock())), isTrue);
  });

  test('seeds past + upcoming appointments', () async {
    final List<Appointment> appts = await appointments.listAppointments();
    expect(appts.length, greaterThanOrEqualTo(8));
    expect(
        appts.any((Appointment a) => a.status == AppointmentStatus.completed),
        isTrue);
    expect(
        appts.any((Appointment a) => a.status == AppointmentStatus.upcoming),
        isTrue);
  });

  test('seeds six months of health-log entries of every kind', () async {
    final entries = await healthLog.listAll();
    expect(entries.length, greaterThan(30));
    expect(entries.any((e) => e.kind.name == 'vitals'), isTrue);
    expect(entries.any((e) => e.kind.name == 'symptom'), isTrue);
    expect(entries.any((e) => e.kind.name == 'note'), isTrue);
  });

  test('seeds care-plan routines (daily + weekly)', () async {
    expect(await carePlan.listAll(), hasLength(5));
  });

  test('seeds a journal with a recent sundowning cluster + wizard entries',
      () async {
    final List<JournalEntry> entries = await storage.listAllJournalEntries();
    expect(entries.length, greaterThan(15));

    final DateTime weekAgo = clock().subtract(const Duration(days: 7));
    final int recentSundowning = entries
        .where((JournalEntry e) =>
            e.behavior.id == 'sundowning' && e.createdAt.isAfter(weekAgo))
        .length;
    expect(recentSundowning, greaterThanOrEqualTo(3),
        reason: 'the pattern detector needs 3 in the trailing 7 days');

    expect(entries.any((JournalEntry e) => e.wizardKind), isTrue);
  });

  test('seeds the care circle with an accepted roster + a pending invite',
      () async {
    expect(await careCircle.listCaregivers(), hasLength(5));
    final List<CareCircleMembership> mems = await careCircle.listMemberships();
    expect(mems, hasLength(5));
    expect(mems.any((CareCircleMembership m) => m.acceptedAt == null), isTrue,
        reason: 'one invite should still be pending');
    expect(
        mems.any((CareCircleMembership m) =>
            m.permissionLevel == PermissionLevel.owner),
        isTrue);

    // The backend-circle CACHE (what the local-first Care Circle screen reads)
    // is also populated, so seeded members show on that screen.
    final cached = await circleMemberCache.list();
    expect(cached.length, greaterThanOrEqualTo(4));
    expect(cached.any((m) => m.role == 'owner'), isTrue);
  });

  test('seeds tasks across open / claimed / done', () async {
    final List<CareTask> tasks = await careTasks.listTasks();
    expect(tasks, hasLength(10));
    expect(tasks.any((CareTask t) => t.isOpen), isTrue);
    expect(tasks.any((CareTask t) => t.isClaimed), isTrue);
    expect(tasks.any((CareTask t) => t.isDone), isTrue);
  });

  test('seeds shifts and expenses', () async {
    expect((await careShifts.listShifts()).isNotEmpty, isTrue);
    expect((await expenses.listExpenses()).length, greaterThan(20));
  });

  test('seeds native calendar notes', () async {
    final events = await careEvents.listEvents();
    expect(events.where((e) => e.kind.name == 'note').length, 5);
  });

  test('seeds every document kind', () async {
    expect(await documents.listEmergencyCards(), hasLength(1));
    expect(await documents.listPoa(), hasLength(1));
    expect(await documents.listIds(), hasLength(2));
  });

  test('seeds chat threads with messages', () async {
    final convos = await chat.listConversations();
    expect(convos, hasLength(3));
    final msgs = await chat.loadMessages(convos.first.id);
    expect(msgs.isNotEmpty, isTrue);
  });
}
