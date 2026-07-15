/// EVERY chat action, driven by the LIVE model against the REAL executors.
///
/// This is the test that the scripted-marker unit tests cannot be: it sends a
/// caregiver's actual phrasing to the DEPLOYED coach, takes whatever marker the
/// model really writes, runs it through the app's real parser and its real
/// executors, and then checks the DATABASE.
///
/// It exists because the unit tests were green while the feature was broken.
/// The model was writing `name="Ibuprofen dosage=400 mg"` — the dose stuffed
/// inside the name — so nothing was ever added, and no scripted test could see
/// it, because I was the one writing the markers (2026-07-13).
///
///   tools/live_chat_actions_test.sh
///
/// Skips unless FORUM_API_URL + LIVE_JWT are set. Costs one real inference per
/// action.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart' hide Provider;
import 'package:holdclose/models/appointment.dart' as appt show Provider, ProviderRole;
import 'package:holdclose/models/care_task.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/services/api_chat_backend.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_actions.dart';
import 'package:holdclose/services/chat_context_builder.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/chat_service.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _baseUrl = String.fromEnvironment('FORUM_API_URL');
const String _liveJwt = String.fromEnvironment('LIVE_JWT');
bool get _configured => _baseUrl.isNotEmpty && _liveJwt.isNotEmpty;

DateTime _clock() => DateTime(2026, 7, 13, 9);

final Provider<Map<String, ChatActionExecutor>> _actionsProvider =
    Provider<Map<String, ChatActionExecutor>>(
  (Ref ref) => buildChatActions(ref, clock: _clock),
);

/// The CURRENT DATA snapshot production sends with every turn — reached through
/// a Ref exactly as `chatServiceProvider` does.
final Provider<Future<String> Function()> _snapshotProvider =
    Provider<Future<String> Function()>(
  (Ref ref) => () async => formatChatContext(await gatherChatContext(ref)),
);

void main() {
  late HoldcloseDatabase db;
  late MedicationRepository meds;
  late AppointmentRepository appts;
  late ProviderRepository providers;
  late CareTasksRepository tasks;
  late CarePlanRepository routines;
  late HealthLogRepository healthLog;
  late ChatRepository chat;
  late ProviderContainer container;
  late ChatService service;

  setUp(() async {
    db = HoldcloseDatabase(NativeDatabase.memory());
    meds = MedicationRepository(db, clock: _clock);
    appts = AppointmentRepository(db);
    providers = ProviderRepository(db);
    tasks = CareTasksRepository(db);
    routines = CarePlanRepository(db);
    healthLog = HealthLogRepository(db);
    chat = ChatRepository(db);
    final InMemoryStorageProvider storage = InMemoryStorageProvider();
    await storage.upsertPatient(maryHenderson());

    container = ProviderContainer(
      overrides: <Override>[
        medicationRepositoryProvider.overrideWithValue(meds),
        appointmentRepositoryProvider.overrideWithValue(appts),
        providerRepositoryProvider.overrideWithValue(providers),
        careTasksRepositoryProvider.overrideWithValue(tasks),
        carePlanRepositoryProvider.overrideWithValue(routines),
        healthLogRepositoryProvider.overrideWithValue(healthLog),
        storageProvider.overrideWithValue(storage),
      ],
    );

    await chat.createConversation(
      id: 'c1',
      title: 'live',
      createdAt: _clock(),
    );

    service = ChatService(
      repository: chat,
      // THE REAL COACH — the deployed Worker, the real model.
      backend: ApiChatBackend(
        baseUrl: _baseUrl,
        tokenLoader: () async => _liveJwt,
      ),
      actions: container.read(_actionsProvider),
      // The snapshot of the caregiver's CURRENT data that production sends —
      // without it the model invents names ("Pick up the new prescription")
      // instead of matching the task/med/appointment that actually exists.
      // Omitting it made this suite test something the app never does.
      contextSnapshot: container.read(_snapshotProvider),
      clock: _clock,
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Say [text] to the live coach, then CONFIRM every action it parked (the
  /// mutating ones all gate behind the in-thread confirm card).
  ///
  /// Returns the marker(s) the model actually produced, so a failure report can
  /// show what it wrote rather than just "nothing happened".
  Future<List<String>> say(String text) async {
    await service
        .sendMessage(conversationId: 'c1', userText: text)
        .drain<void>();
    final List<Message> msgs = await chat.loadMessages('c1');
    final Message assistant = msgs.last;
    final List<String> pending = assistant.citations
        .where((String c) =>
            c.startsWith(ChatService.pendingActionCitationPrefix))
        .toList();
    for (final String citation in pending) {
      await service.confirmPendingAction(
        conversationId: 'c1',
        messageId: assistant.id,
        citation: citation,
      );
    }
    return <String>[
      ...pending.map((String c) =>
          c.substring(ChatService.pendingActionCitationPrefix.length)),
      if (pending.isEmpty) '(no action marker — body: ${assistant.body})',
    ];
  }

  final bool skip = !_configured;
  const String needs = 'needs FORUM_API_URL + LIVE_JWT';

  group('medications', () {
    test('add_medication', () async {
      final List<String> markers =
          await say('Add ibuprofen 400 mg, morning and evening.');
      final List<Medication> list = await meds.listMedications();
      expect(list, hasLength(1), reason: 'model wrote: $markers');
      expect(list.single.name.toLowerCase(), contains('ibuprofen'));
      expect(list.single.dosage, contains('400'));
      // ...and it was actually scheduled.
      expect(await meds.entriesForMedication(list.single.id), hasLength(2),
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);

    test('update_medication (change the dose)', () async {
      await meds.upsertMedication(Medication(
        id: 'm1',
        name: 'Lisinopril',
        dosage: '10 mg',
        route: MedicationRoute.oral,
      ));

      final List<String> markers =
          await say('Change Lisinopril to 20 mg please.');

      final Medication m = (await meds.listMedications()).single;
      expect(m.dosage, contains('20'), reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);

    test('delete_medication', () async {
      await meds.upsertMedication(Medication(
        id: 'm1',
        name: 'Aspirin',
        dosage: '81 mg',
        route: MedicationRoute.oral,
      ));

      final List<String> markers = await say('Remove aspirin from the list.');

      expect(await meds.listMedications(), isEmpty,
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);

    test('log_dose', () async {
      await meds.upsertMedication(Medication(
        id: 'm1',
        name: 'Donepezil',
        dosage: '10 mg',
        route: MedicationRoute.oral,
      ));

      final List<String> markers =
          await say('She took her donepezil this morning.');

      expect(await meds.logsFor('m1'), isNotEmpty,
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);
  });

  group('appointments', () {
    test('add_appointment', () async {
      final List<String> markers = await say(
          'Add an appointment with Dr. Ortega on 2026-08-03 at 2:30 pm.');

      final List<Appointment> list = await appts.listAppointments();
      expect(list, hasLength(1), reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);

    test('add_appointment with a RELATIVE date ("tomorrow at noon")', () async {
      // The 2026-07-14 regression: the model mangles a computed date
      // ("2026-0712:00"), so ChatService re-resolves it from the caregiver's own
      // words before parking the confirm card. _clock = 2026-07-13 → "tomorrow"
      // is 07-14. Whatever the model writes, the appointment must land on 07-14.
      final List<String> markers =
          await say('Add an appointment tomorrow at noon for Dr. Ortega.');

      final List<Appointment> list = await appts.listAppointments();
      expect(list, hasLength(1),
          reason: 'a relative date must still schedule — model wrote: $markers');
      expect(list.single.startsAt.day, 14,
          reason: '"tomorrow" from 07-13 is 07-14 — model wrote: $markers');
      expect(list.single.startsAt.hour, 12, reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);

    test('cancel_appointment', () async {
      await providers.upsertProvider(const appt.Provider(
        id: 'p-ortega',
        name: 'Dr. Ortega',
        role: appt.ProviderRole.doctor,
        phone: '',
        address: '',
      ));
      await appts.upsertAppointment(Appointment(
        id: 'a1',
        providerId: 'p-ortega',
        startsAt: DateTime(2026, 8, 3, 14, 30),
        durationMinutes: 60,
        location: '',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      ));

      final List<String> markers =
          await say('Cancel the appointment with Dr. Ortega.');

      final Appointment a = (await appts.listAppointments()).single;
      expect(a.status, AppointmentStatus.canceled,
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);
  });

  group('care team', () {
    test('add_task', () async {
      final List<String> markers =
          await say('Add a task: pick up her prescription refill.');

      expect(await tasks.listTasksForPatient(maryHenderson().id), isNotEmpty,
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);

    test('complete_task', () async {
      await tasks.upsertTask(CareTask(
        id: 't1',
        title: 'Pick up refill',
        patientId: maryHenderson().id,
      ));

      final List<String> markers = await say('I picked up the refill — done.');

      final List<CareTask> list =
          await tasks.listTasksForPatient(maryHenderson().id);
      expect(list.single.completedAt, isNotNull,
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);
  });

  group('journal, health log, routines', () {
    test('log_journal', () async {
      final List<String> markers = await say(
          'Log this: she got upset at dinner and I stepped outside to breathe.');

      expect(await container.read(storageProvider).listAllJournalEntries(),
          isNotEmpty,
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);

    test('add_health_log', () async {
      final List<String> markers = await say('Her weight today was 148 lbs.');

      expect(await healthLog.byPatient(maryHenderson().id), isNotEmpty,
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);

    test('add_routine', () async {
      final List<String> markers =
          await say('Add a routine: a short walk every day at 4 pm.');

      expect(await routines.listAll(), isNotEmpty,
          reason: 'model wrote: $markers');
    }, skip: skip ? needs : false);
  });
}
