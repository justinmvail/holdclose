import 'dart:convert' show jsonDecode;

import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_circle_membership.dart';
import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/models/care_plan_routine.dart';
import 'package:careblazers/models/care_shift.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/models/expense.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/models/health_log_entry.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/auth_provider.dart';
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
import 'package:careblazers/providers/sync_state_provider.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/services/fake_forum_api_client.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/services/provider_repository.dart';
import 'package:careblazers/services/sync_service.dart';
import 'package:careblazers/services/sync_sink.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Unit coverage for the server-authoritative [SyncController]
/// (server-authoritative sync). Exercises enqueue→push, pull→apply,
/// tombstones, the no-circle no-op contract, LWW-rejection tolerance, the
/// echo-loop guard, and a "two device" cross-container round-trip — all
/// against the in-memory [FakeForumApiClient] + an in-memory drift db +
/// [InMemoryStorageProvider].

Patient _patient({String id = 'p1', String name = 'Mary'}) => Patient(
      id: id,
      name: name,
      age: 78,
      diagnosis: 'Alzheimer',
      diagnosedAt: DateTime.utc(2022, 4, 15),
      medications: const <CrisisMedication>[],
      allergies: const <String>['Penicillin'],
      calms: const <String>[],
      escalates: const <String>[],
      primaryCaregiver: const Contact(name: 'Sarah', phone: '555'),
      healthcarePOA: const Contact(name: 'Sarah', phone: '555'),
      advanceDirective:
          const AdvanceDirectiveStatus(onFileAt: 'Hospital', dnr: false),
    );

Medication _med(String id, String name) => Medication(
      id: id,
      name: name,
      dosage: '10 mg',
      route: MedicationRoute.oral,
    );

DoseWindow _window(String id, {String patientId = 'p1'}) => DoseWindow(
      id: id,
      patientId: patientId,
      label: 'Morning',
      anchorTime: const TimeOfDay(hour: 8, minute: 0),
      sortOrder: 0,
    );

/// One self-contained sync "device": its own drift db + med repo +
/// in-memory storage + state store, wired to a [ForumApiClient]. Mirrors
/// the production `syncControllerProvider` wiring (the sink registration +
/// the post-write scheduling are exercised here through enqueue directly).
class _Device {
  _Device(this.client, {DateTime Function()? clock}) {
    db = CareblazersDatabase(NativeDatabase.memory());
    medications = MedicationRepository(db, clock: clock);
    chat = ChatRepository(db);
    appointments = AppointmentRepository(db, clock: clock);
    providers = ProviderRepository(db);
    healthLog = HealthLogRepository(db);
    carePlan = CarePlanRepository(db);
    careEvents = CareEventsRepository(db);
    careTasks = CareTasksRepository(db);
    careShifts = CareShiftsRepository(db);
    expenses = ExpensesRepository(db);
    careCircle = CareCircleRepository(db);
    documents = DocumentsRepository(db);
    circleMemberCache = CircleMemberCacheRepository(db);
    storage = InMemoryStorageProvider();
    stateStore = const SyncStateStore();
    controller = SyncController(
      outbox: SyncOutbox(db),
      client: client,
      stateStore: stateStore,
      storage: storage,
      medications: medications,
      chat: chat,
      appointments: appointments,
      providers: providers,
      healthLog: healthLog,
      carePlan: carePlan,
      careEvents: careEvents,
      careTasks: careTasks,
      careShifts: careShifts,
      expenses: expenses,
      careCircle: careCircle,
      documents: documents,
      circleMemberCache: circleMemberCache,
      clock: clock,
    );
    // Wire the enqueue seam exactly like the provider does — one shared
    // sink shape per host.
    SyncSink sink() => SyncSink(
          onUpsert: (String c, String id, Map<String, dynamic> j) =>
              controller.enqueueUpsert(c, id, j),
          onDelete: (String c, String id) => controller.enqueueDelete(c, id),
        );
    for (final SyncSinkHost host in <SyncSinkHost>[
      medications,
      chat,
      appointments,
      providers,
      healthLog,
      carePlan,
      careEvents,
      careTasks,
      careShifts,
      expenses,
      careCircle,
      documents,
    ]) {
      host.syncSink = sink();
    }
    storage.syncSink = sink();
  }

  final ForumApiClient client;
  late final CareblazersDatabase db;
  late final MedicationRepository medications;
  late final ChatRepository chat;
  late final AppointmentRepository appointments;
  late final ProviderRepository providers;
  late final HealthLogRepository healthLog;
  late final CarePlanRepository carePlan;
  late final CareEventsRepository careEvents;
  late final CareTasksRepository careTasks;
  late final CareShiftsRepository careShifts;
  late final ExpensesRepository expenses;
  late final CareCircleRepository careCircle;
  late final DocumentsRepository documents;
  late final CircleMemberCacheRepository circleMemberCache;
  late final InMemoryStorageProvider storage;
  late final SyncStateStore stateStore;
  late final SyncController controller;

  Future<void> dispose() async {
    controller.dispose();
    await db.close();
  }
}

JournalEntry _journal(String id, {String situation = 'hello'}) =>
    JournalEntry.wizard(
      id: id,
      createdAt: DateTime.utc(2026, 1, 1),
      situationText: situation,
    );

Conversation _convo(String id, {String title = 'Thread'}) => Conversation(
      id: id,
      title: title,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

Message _message(String id, String convoId, {String text = 'hi'}) => Message(
      id: id,
      conversationId: convoId,
      role: MessageRole.user,
      body: text,
      citations: const <String>[],
      createdAt: DateTime.utc(2026, 1, 1, 0, 1),
      streamingDone: true,
    );

Provider _provider(String id, {String name = 'Dr. Lee'}) => Provider(
      id: id,
      name: name,
      role: ProviderRole.doctor,
      phone: '555',
      address: '1 Main St',
    );

Appointment _appt(String id, String providerId) => Appointment(
      id: id,
      providerId: providerId,
      startsAt: DateTime.utc(2026, 2, 1, 10),
      durationMinutes: 30,
      location: 'Clinic',
      agenda: const <String>[],
      status: AppointmentStatus.upcoming,
    );

HealthLogEntry _health(String id, {String patientId = 'p1'}) => HealthLogEntry(
      id: id,
      patientId: patientId,
      kind: HealthLogKind.vitals,
      recordedAt: DateTime.utc(2026, 1, 1),
    );

CarePlanRoutine _routine(String id, {String title = 'Morning walk'}) =>
    CarePlanRoutine(
      id: id,
      patientId: 'p1',
      title: title,
      body: 'Stroll the block',
      scheduledTime: const TimeOfDay(hour: 9, minute: 0),
      frequencyKind: FrequencyKind.daily,
      daysOfWeek: const <int>{},
      startsOn: DateTime.utc(2026, 1, 1),
    );

CareEvent _note(String id, {String title = 'Note'}) => CareEvent(
      id: id,
      kind: CareEventKind.note,
      title: title,
      start: DateTime.utc(2026, 2, 1, 12),
      patientId: 'p1',
    );

CareTask _task(String id, {String title = 'Pick up meds'}) => CareTask(
      id: id,
      title: title,
      patientId: 'p1',
      dueAt: DateTime.utc(2026, 2, 1, 14),
    );

CareShift _shift(String id, {String caregiverId = 'cg1'}) => CareShift(
      id: id,
      caregiverId: caregiverId,
      start: DateTime.utc(2026, 2, 1, 8),
      end: DateTime.utc(2026, 2, 1, 16),
      patientId: 'p1',
    );

Expense _expense(String id, {String description = 'Pharmacy'}) => Expense(
      id: id,
      amountCents: 1299,
      description: description,
      paidByCaregiverId: 'cg1',
      paidAt: DateTime.utc(2026, 2, 1),
      kind: ExpenseKind.meds,
      patientId: 'p1',
    );

Caregiver _caregiver(String id, {String name = 'Sarah'}) => Caregiver(
      id: id,
      displayName: name,
      role: CaregiverRole.primary,
    );

CareCircleMembership _membership(String id, {String caregiverId = 'cg1'}) =>
    CareCircleMembership(
      id: id,
      caregiverId: caregiverId,
      patientId: 'p1',
      permissionLevel: PermissionLevel.editor,
      invitedAt: DateTime.utc(2026, 1, 1),
    );

EmergencyCard _emergencyCard(String id, {String? attachmentPath}) =>
    EmergencyCard(
      id: id,
      patientId: 'p1',
      updatedAt: DateTime.utc(2026, 1, 1),
      conditions: const <String>['Alzheimer'],
      medications: const <String>['Donepezil'],
      allergies: const <String>['Penicillin'],
      emergencyContacts: const <EmergencyContact>[
        EmergencyContact(name: 'Sarah', relation: 'Daughter', phone: '555'),
      ],
      insurance: const Insurance(
          carrier: 'Acme', policyNumber: 'PN1', groupNumber: 'GN1'),
      donorStatus: DonorStatus.unknown,
      attachmentPath: attachmentPath,
    );

PowerOfAttorneyDoc _poa(String id, {String? scanPath}) => PowerOfAttorneyDoc(
      id: id,
      patientId: 'p1',
      updatedAt: DateTime.utc(2026, 1, 1),
      agentName: 'Sarah',
      scope: PoaScope.medical,
      effectiveDate: DateTime.utc(2025, 1, 1),
      scanPath: scanPath,
    );

IdentificationDoc _idDoc(String id, {String? photoFrontPath}) =>
    IdentificationDoc(
      id: id,
      patientId: 'p1',
      updatedAt: DateTime.utc(2026, 1, 1),
      kind: IdKind.driverLicense,
      idNumber: 'D1234',
      photoFrontPath: photoFrontPath,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The "two device" test opens two in-memory drift dbs in one process;
  // they're isolated NativeDatabase.memory() connections, so drift's
  // multiple-database race warning doesn't apply.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('no active circle = pure no-op (fail-safe)', () {
    test('enqueue + push + pull do nothing, writes stay local', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);

      // No circle bound. A local med write must NOT enqueue.
      await d.medications.upsertMedication(_med('m1', 'Donepezil'));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'no circle → nothing queued');

      // push/pull/syncNow are inert.
      await d.controller.push();
      await d.controller.pull();
      await d.controller.syncNow();

      // The med is still on disk locally — fully local behaviour.
      expect((await d.medications.listMedications()).single.id, 'm1');
    });
  });

  group('enqueue → push sends docs', () {
    test('a local med write is pushed to the circle backend', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);

      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.medications.upsertMedication(_med('m1', 'Donepezil'));
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).length, 1);

      await d.controller.push();
      // Outbox drained on accept.
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue);

      // The backend now holds the med doc.
      final SyncPullResult pulled =
          await backend.syncPull(circle.id, since: 0);
      expect(pulled.docs.where((SyncDoc x) => x.collection == 'medication'),
          isNotEmpty);
    });
  });

  group('pull applies patient + medication doc into local storage/repo', () {
    test('a remote patient + med land locally', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);

      // Backend already owns a patient + a med (as if another device
      // pushed them).
      final CircleDto circle = await backend.createCircle(
        'Mary',
        patient: SyncPatientWrite(
          payload: _patient(name: 'Mary H.').toJson(),
          clientUpdatedAt: 1000,
        ),
      );
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'm9',
          collection: 'medication',
          payload: _med('m9', 'Memantine').toJson(),
          clientUpdatedAt: 1000,
        ),
        SyncDocWrite(
          id: 'w9',
          collection: 'dose_window',
          payload: _window('w9').toJson(),
          clientUpdatedAt: 1000,
        ),
      ]);

      await d.stateStore.setCircleId(circle.id);
      await d.controller.pull();

      expect((await d.storage.getPatient())?.name, 'Mary H.');
      final List<Medication> meds = await d.medications.listMedications();
      expect(meds.single.name, 'Memantine');
      expect((await d.medications.getWindow('w9'))?.id, 'w9');

      // Cursor advanced so a second pull is a no-op delta.
      final int cursor = await d.stateStore.getCursor(circle.id);
      expect(cursor, greaterThan(0));
    });
  });

  group('pull does not clobber an unpushed local write (LWW guard)', () {
    test('SyncOutbox.hasPending reflects queued writes', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final SyncOutbox outbox = SyncOutbox(d.db);

      expect(await outbox.hasPending('medication', 'm1'), isFalse);
      await outbox.enqueue(
        collection: 'medication',
        docId: 'm1',
        payload: <String, dynamic>{'id': 'm1'},
        clientUpdatedAt: 1,
        deleted: false,
      );
      expect(await outbox.hasPending('medication', 'm1'), isTrue);
      expect(await outbox.hasPending('medication', 'other'), isFalse);
      expect(await outbox.hasPending('appointment', 'm1'), isFalse);
    });

    test('a pulled doc is SKIPPED while an unpushed local write is queued '
        'for it', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // A local edit that has NOT been pushed (no applyingRemote → enqueues).
      await d.medications.upsertMedication(_med('m1', 'LocalName'));
      await pumpEventQueue(); // let the async enqueue land
      expect(await SyncOutbox(d.db).hasPending('medication', 'm1'), isTrue);

      // The server holds a different (older) value for the same id.
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'm1',
          collection: 'medication',
          payload: _med('m1', 'ServerName').toJson(),
          clientUpdatedAt: 1,
        ),
      ]);

      await d.controller.pull();

      // The unpushed local edit survived — the pull didn't clobber it.
      expect((await d.medications.getMedication('m1'))?.name, 'LocalName');
    });

    test('a pulled doc IS applied once nothing is queued for it', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // No local pending write for m2.
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'm2',
          collection: 'medication',
          payload: _med('m2', 'ServerName').toJson(),
          clientUpdatedAt: 1,
        ),
      ]);

      await d.controller.pull();
      expect((await d.medications.getMedication('m2'))?.name, 'ServerName');
    });
  });

  group('resyncAllLocal — recover data written before the circle was bound',
      () {
    test('pushes local rows that never enqueued so a member can pull them',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // Local writes WITHOUT enqueuing — exactly what the seed does (it runs
      // before sync binds the circle).
      await d.medications.applyingRemote(
          () => d.medications.upsertMedication(_med('m1', 'Donepezil')));
      await d.providers
          .applyingRemote(() => d.providers.upsertProvider(_provider('pr1')));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'seed-style writes never hit the outbox');

      // Backend has neither yet.
      final SyncPullResult pre = await backend.syncPull(circle.id, since: 0);
      expect(pre.docs.where((SyncDoc x) => x.collection == 'medication'),
          isEmpty);

      await d.controller.resyncAllLocal();

      // Now both are on the backend — a circle member's pull would get them.
      final SyncPullResult post = await backend.syncPull(circle.id, since: 0);
      expect(
          post.docs.any(
              (SyncDoc x) => x.collection == 'medication' && x.id == 'm1'),
          isTrue);
      expect(
          post.docs
              .any((SyncDoc x) => x.collection == 'providers' && x.id == 'pr1'),
          isTrue);
    });

    test('no circle bound → no-op', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      await d.medications.applyingRemote(
          () => d.medications.upsertMedication(_med('m1', 'Donepezil')));
      await d.controller.resyncAllLocal(); // must not throw
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue);
    });
  });

  group('tombstone deletes locally', () {
    test('a pulled deleted med doc removes the local row', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);

      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // Seed a local med.
      await d.medications.applyingRemote(
          () => d.medications.upsertMedication(_med('m1', 'Donepezil')));
      expect((await d.medications.listMedications()).length, 1);

      // Backend gets a tombstone for it, newer than any local stamp.
      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'm1',
          collection: 'medication',
          payload: <String, dynamic>{},
          clientUpdatedAt: 9999,
          deleted: true,
        ),
      ]);

      await d.controller.pull();
      expect((await d.medications.listMedications()).isEmpty, isTrue);
    });
  });

  group('LWW-rejected push does not crash', () {
    test('pushing a stale write is tolerated + drains the outbox', () async {
      int t = 5000;
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend, clock: () {
        final DateTime now = DateTime.fromMillisecondsSinceEpoch(t);
        return now;
      });
      addTearDown(d.dispose);

      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // Backend already holds a NEWER version of m1.
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'm1',
          collection: 'medication',
          payload: _med('m1', 'Newer').toJson(),
          clientUpdatedAt: 1000000,
        ),
      ]);

      // Local writes a stale version (clock stamps an older time).
      t = 100; // older than the backend's 1_000_000
      await d.medications.upsertMedication(_med('m1', 'Older'));
      await pumpEventQueue();

      // Push must not throw, and must drain the queue even though the
      // server rejects the doc as stale.
      await d.controller.push();
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue);
    });
  });

  group('applied pulled doc is NOT re-enqueued (echo-loop guard)', () {
    test('applying a remote med leaves the outbox empty', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);

      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'm1',
          collection: 'medication',
          payload: _med('m1', 'Donepezil').toJson(),
          clientUpdatedAt: 1000,
        ),
      ]);

      await d.controller.pull();
      await pumpEventQueue();

      // The applied med must not have bounced back into the outbox.
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled doc must not re-enqueue it');
    });
  });

  group('outbox coalesces by (collection, docId)', () {
    test('repeated edits of one med leave a single pending row', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);

      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.medications.upsertMedication(_med('m1', 'A'));
      await d.medications.upsertMedication(_med('m1', 'B'));
      await d.medications.upsertMedication(_med('m1', 'C'));
      await pumpEventQueue();

      final List<SyncOutboxTableData> pending =
          await SyncOutbox(d.db).listPending();
      expect(pending.length, 1, reason: 'newest write wins, no unbounded growth');
    });
  });

  group('two devices share data through one backend', () {
    test('device A pushes a med, device B pulls + sees it', () async {
      final FakeForumBackend shared = FakeForumBackend();
      final FakeForumApiClient clientA =
          FakeForumApiClient(backend: shared);
      final FakeForumApiClient clientB =
          FakeForumApiClient(backend: shared);
      final _Device a = _Device(clientA);
      final _Device b = _Device(clientB);
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      // A creates the circle owning the loved one.
      final CircleDto circle = await clientA.createCircle(
        'Mary',
        patient: SyncPatientWrite(
          payload: _patient().toJson(),
          clientUpdatedAt: 1000,
        ),
      );
      await a.stateStore.setCircleId(circle.id);
      await b.stateStore.setCircleId(circle.id);

      // A adds a med and pushes.
      await a.medications.upsertMedication(_med('m1', 'Donepezil'));
      await pumpEventQueue();
      await a.controller.push();

      // B pulls and sees both the shared patient and the med.
      await b.controller.pull();
      expect((await b.storage.getPatient())?.name, 'Mary');
      expect((await b.medications.listMedications()).single.name, 'Donepezil');
    });
  });

  // ───────────────────────────────────────────── Batch 1 collections ──
  //
  // For each new collection: a local write enqueues; a pulled doc applies
  // via the repo WITHOUT re-enqueuing (echo guard); a pulled tombstone
  // deletes the local row. Mirrors the medication-family coverage above.

  group('journal_entries sync', () {
    test('local write enqueues; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // Local write enqueues.
      await d.storage.insertJournalEntry(_journal('j1'));
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).single.collection,
          'journal_entries');

      // Push + a remote upsert pulled back applies without re-enqueuing.
      await d.controller.push();
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'j2',
          collection: 'journal_entries',
          payload: _journal('j2', situation: 'remote').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.storage.listAllJournalEntries()).map((e) => e.id),
          containsAll(<String>['j1', 'j2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled journal entry must not re-enqueue it');

      // Tombstone deletes.
      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'j2',
          collection: 'journal_entries',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.storage.listAllJournalEntries()).map((e) => e.id),
          isNot(contains('j2')));
    });
  });

  group('chat_conversations + chat_messages sync', () {
    test('local writes enqueue; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // Creating a conversation + appending a message both enqueue.
      await d.chat.createConversation(
          id: 'c1', title: 'T', createdAt: DateTime.utc(2026, 1, 1));
      await d.chat.appendMessage(_message('msg1', 'c1'));
      await pumpEventQueue();
      final Set<String> collections = (await SyncOutbox(d.db).listPending())
          .map((r) => r.collection)
          .toSet();
      expect(collections, containsAll(<String>['chat_conversations',
        'chat_messages']));
      await d.controller.push();

      // Remote conversation + message apply without re-enqueuing.
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'c2',
          collection: 'chat_conversations',
          payload: _convo('c2', title: 'Remote').toJson(),
          clientUpdatedAt: 9999,
        ),
        SyncDocWrite(
          id: 'm2',
          collection: 'chat_messages',
          payload: _message('m2', 'c2', text: 'remote msg').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.chat.listConversations()).map((c) => c.id),
          containsAll(<String>['c1', 'c2']));
      expect((await d.chat.loadMessages('c2')).single.id, 'm2');
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled chat doc must not re-enqueue it');

      // Conversation tombstone deletes the thread (cascades messages).
      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'c2',
          collection: 'chat_conversations',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.chat.listConversations()).map((c) => c.id),
          isNot(contains('c2')));
    });
  });

  group('appointments + providers sync', () {
    test('local writes enqueue; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.providers.upsertProvider(_provider('pr1'));
      await d.appointments.upsertAppointment(_appt('a1', 'pr1'));
      await pumpEventQueue();
      final Set<String> collections = (await SyncOutbox(d.db).listPending())
          .map((r) => r.collection)
          .toSet();
      expect(collections, containsAll(<String>['providers', 'appointments']));
      await d.controller.push();

      // Remote provider + appointment apply without re-enqueuing.
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'pr2',
          collection: 'providers',
          payload: _provider('pr2', name: 'Dr. Remote').toJson(),
          clientUpdatedAt: 9999,
        ),
        SyncDocWrite(
          id: 'a2',
          collection: 'appointments',
          payload: _appt('a2', 'pr2').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.appointments.listProviders()).map((p) => p.id),
          containsAll(<String>['pr1', 'pr2']));
      expect((await d.appointments.listAppointments()).map((a) => a.id),
          containsAll(<String>['a1', 'a2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled appointment doc must not re-enqueue it');

      // Appointment tombstone deletes the row.
      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'a2',
          collection: 'appointments',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.appointments.listAppointments()).map((a) => a.id),
          isNot(contains('a2')));
    });
  });

  group('health_log_entries sync', () {
    test('local write enqueues; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.healthLog.upsert(_health('h1'));
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).single.collection,
          'health_log_entries');
      await d.controller.push();

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'h2',
          collection: 'health_log_entries',
          payload: _health('h2').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.healthLog.listAll()).map((e) => e.id),
          containsAll(<String>['h1', 'h2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled health-log entry must not re-enqueue it');

      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'h2',
          collection: 'health_log_entries',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.healthLog.listAll()).map((e) => e.id),
          isNot(contains('h2')));
    });
  });

  // ───────────────────────────────────────────── Batch 2 collections ──
  //
  // For each: a local write enqueues; a pulled doc applies via the repo
  // WITHOUT re-enqueuing (echo guard); a pulled tombstone deletes the local
  // row. Mirrors the batch-1 coverage above.

  group('care_plan_routines sync', () {
    test('local write enqueues; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.carePlan.upsert(_routine('r1'));
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).single.collection,
          'care_plan_routines');
      await d.controller.push();

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'r2',
          collection: 'care_plan_routines',
          payload: _routine('r2', title: 'Remote routine').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.carePlan.listAll()).map((e) => e.id),
          containsAll(<String>['r1', 'r2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled routine must not re-enqueue it');

      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'r2',
          collection: 'care_plan_routines',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.carePlan.listAll()).map((e) => e.id),
          isNot(contains('r2')));
    });
  });

  group('care_events (notes) sync', () {
    test('local note enqueues; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.careEvents.upsertEvent(_note('n1'));
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).single.collection,
          'care_events');
      await d.controller.push();

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'n2',
          collection: 'care_events',
          payload: _note('n2', title: 'Remote note').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.careEvents.listEvents()).map((e) => e.id),
          containsAll(<String>['n1', 'n2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled note must not re-enqueue it');

      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'n2',
          collection: 'care_events',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.careEvents.listEvents()).map((e) => e.id),
          isNot(contains('n2')));
    });
  });

  group('care_tasks sync', () {
    test('local write enqueues; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.careTasks.upsertTask(_task('t1'));
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).single.collection,
          'care_tasks');
      await d.controller.push();

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 't2',
          collection: 'care_tasks',
          payload: _task('t2', title: 'Remote task').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.careTasks.listTasks()).map((e) => e.id),
          containsAll(<String>['t1', 't2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled task must not re-enqueue it');

      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 't2',
          collection: 'care_tasks',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.careTasks.listTasks()).map((e) => e.id),
          isNot(contains('t2')));
    });
  });

  group('care_shifts sync', () {
    test('local write enqueues; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.careShifts.upsertShift(_shift('s1'));
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).single.collection,
          'care_shifts');
      await d.controller.push();

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 's2',
          collection: 'care_shifts',
          payload: _shift('s2', caregiverId: 'cg2').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.careShifts.listShifts()).map((e) => e.id),
          containsAll(<String>['s1', 's2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled shift must not re-enqueue it');

      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 's2',
          collection: 'care_shifts',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.careShifts.listShifts()).map((e) => e.id),
          isNot(contains('s2')));
    });
  });

  group('expenses sync', () {
    test('local write enqueues; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.expenses.upsertExpense(_expense('e1'));
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).single.collection,
          'expenses');
      await d.controller.push();

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'e2',
          collection: 'expenses',
          payload: _expense('e2', description: 'Transport').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.expenses.listExpenses()).map((e) => e.id),
          containsAll(<String>['e1', 'e2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled expense must not re-enqueue it');

      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'e2',
          collection: 'expenses',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.expenses.listExpenses()).map((e) => e.id),
          isNot(contains('e2')));
    });
  });

  group('caregivers + care_circle_memberships sync', () {
    test('local writes enqueue; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      await d.careCircle.upsertCaregiver(_caregiver('cg1'));
      await d.careCircle.upsertMembership(_membership('mb1'));
      await pumpEventQueue();
      final Set<String> collections = (await SyncOutbox(d.db).listPending())
          .map((r) => r.collection)
          .toSet();
      expect(collections,
          containsAll(<String>['caregivers', 'care_circle_memberships']));
      await d.controller.push();

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'cg2',
          collection: 'caregivers',
          payload: _caregiver('cg2', name: 'Remote').toJson(),
          clientUpdatedAt: 9999,
        ),
        SyncDocWrite(
          id: 'mb2',
          collection: 'care_circle_memberships',
          payload: _membership('mb2', caregiverId: 'cg2').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      expect((await d.careCircle.listCaregivers()).map((c) => c.id),
          containsAll(<String>['cg1', 'cg2']));
      expect((await d.careCircle.listMemberships()).map((m) => m.id),
          containsAll(<String>['mb1', 'mb2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled caregiver/membership must not re-enqueue');

      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'mb2',
          collection: 'care_circle_memberships',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.careCircle.listMemberships()).map((m) => m.id),
          isNot(contains('mb2')));
    });
  });

  group('documents (emergency_cards + poa + id) sync', () {
    test('local writes enqueue; remote apply + tombstone (echo-guarded)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // File paths in the model are synced AS-IS (metadata only).
      await d.documents
          .upsertEmergencyCard(_emergencyCard('ec1', attachmentPath: '/x.png'));
      await d.documents.upsertPoa(_poa('poa1', scanPath: '/poa.png'));
      await d.documents.upsertId(_idDoc('id1', photoFrontPath: '/f.png'));
      await pumpEventQueue();
      final Set<String> collections = (await SyncOutbox(d.db).listPending())
          .map((r) => r.collection)
          .toSet();
      expect(
          collections,
          containsAll(<String>[
            'emergency_cards',
            'power_of_attorney_docs',
            'identification_docs',
          ]));
      await d.controller.push();

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'ec2',
          collection: 'emergency_cards',
          // A file path that doesn't exist on this device — must round-trip
          // as-is and degrade gracefully (no file upload here).
          payload: _emergencyCard('ec2', attachmentPath: '/missing.png')
              .toJson(),
          clientUpdatedAt: 9999,
        ),
        SyncDocWrite(
          id: 'poa2',
          collection: 'power_of_attorney_docs',
          payload: _poa('poa2', scanPath: '/missing-poa.png').toJson(),
          clientUpdatedAt: 9999,
        ),
        SyncDocWrite(
          id: 'id2',
          collection: 'identification_docs',
          payload: _idDoc('id2', photoFrontPath: '/missing-id.png').toJson(),
          clientUpdatedAt: 9999,
        ),
      ]);
      await d.controller.pull();
      await pumpEventQueue();
      final EmergencyCard? ec2 = await d.documents.getEmergencyCard('ec2');
      expect(ec2?.attachmentPath, '/missing.png',
          reason: 'file path synced as-is');
      expect((await d.documents.listPoa()).map((p) => p.id),
          containsAll(<String>['poa1', 'poa2']));
      expect((await d.documents.listIds()).map((i) => i.id),
          containsAll(<String>['id1', 'id2']));
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'applying a pulled document must not re-enqueue it');

      await backend.syncPush(circle.id, docs: const <SyncDocWrite>[
        SyncDocWrite(
          id: 'ec2',
          collection: 'emergency_cards',
          payload: <String, dynamic>{},
          clientUpdatedAt: 99999,
          deleted: true,
        ),
      ]);
      await d.controller.pull();
      expect((await d.documents.listEmergencyCards()).map((c) => c.id),
          isNot(contains('ec2')));
    });
  });

  group('currentCaregiverId resolves the signed-in user', () {
    tearDown(() => preloadedAlphaUser = null);

    test('falls back to the demo constant when signed out', () {
      preloadedAlphaUser = null;
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(currentCaregiverIdProvider), fallbackCaregiverId);
    });

    test('resolves the real signed-in user id when present', () {
      preloadedAlphaUser =
          const User(id: 'user-abc', email: 'a@b.c', name: 'Sarah');
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(currentCaregiverIdProvider), 'user-abc');
    });
  });

  group('pull hardening (2026-06-11) — isolation + dependency ordering', () {
    test('a chat MESSAGE whose rev is below its conversation still applies '
        '(parents-first ordering beats rev order)', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');

      // Server revs follow PUSH order: the message lands first (rev
      // below), the conversation second (rev above) — exactly the shape
      // a conversation bump after each message produces. A rev-ordered
      // apply would insert the message before its FK parent exists.
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'msg-1',
          collection: 'chat_messages',
          payload: _message('msg-1', 'convo-1').toJson(),
          clientUpdatedAt: 1000,
        ),
      ]);
      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'convo-1',
          collection: 'chat_conversations',
          payload: _convo('convo-1').toJson(),
          clientUpdatedAt: 1001,
        ),
      ]);

      await d.stateStore.setCircleId(circle.id);
      await d.controller.pull();

      // The fresh joiner has the whole thread — no FK wedge.
      expect((await d.chat.listConversations()).single.id, 'convo-1');
      expect((await d.chat.loadMessages('convo-1')).single.id, 'msg-1');
    });

    test('one malformed doc neither aborts the batch nor pins the cursor',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');

      await backend.syncPush(circle.id, docs: <SyncDocWrite>[
        // Garbage payload — Medication.fromJson throws on apply, every
        // time, deterministically.
        const SyncDocWrite(
          id: 'poison',
          collection: 'medication',
          payload: <String, dynamic>{'garbage': true},
          clientUpdatedAt: 1000,
        ),
        SyncDocWrite(
          id: 'j1',
          collection: 'journal_entries',
          payload: _journal('j1').toJson(),
          clientUpdatedAt: 1001,
        ),
      ]);

      await d.stateStore.setCircleId(circle.id);
      await d.controller.pull();

      // The good doc applied…
      expect(
        (await d.storage.listAllJournalEntries()).single.id,
        'j1',
      );
      // …and the cursor advanced PAST the poison doc, so sync is not
      // bricked: the next pull is an empty delta, not a repeat failure.
      final int cursor = await d.stateStore.getCursor(circle.id);
      expect(cursor, greaterThan(0));
      final SyncPullResult delta =
          await backend.syncPull(circle.id, since: cursor);
      expect(delta.docs, isEmpty);
    });
  });

  group('patient sync (2026-06-11) — loved-one edits reach the circle', () {
    test('upsertPatient enqueues; push routes it onto the dedicated '
        'patient field', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle(
        'Mary',
        patient: SyncPatientWrite(
          payload: _patient().toJson(),
          clientUpdatedAt: 1000,
        ),
      );
      await d.stateStore.setCircleId(circle.id);

      // A crisis-card style edit on this device.
      await d.storage.upsertPatient(_patient(name: 'Mary Updated'));
      await pumpEventQueue();
      expect(await SyncOutbox(d.db).hasPending('patient', 'p1'), isTrue);

      await d.controller.push();

      // The circle's patient row now carries the edit; the outbox drained.
      final SyncPullResult pulled = await backend.syncPull(circle.id, since: 0);
      expect(pulled.patient, isNotNull);
      expect(
        (jsonDecode(pulled.patient!.payload)
            as Map<String, dynamic>)['name'],
        'Mary Updated',
      );
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue);
    });

    test('a pulled patient does NOT clobber an unpushed local edit',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle(
        'Mary',
        patient: SyncPatientWrite(
          payload: _patient(name: 'Server Copy').toJson(),
          clientUpdatedAt: 5000,
        ),
      );
      await d.stateStore.setCircleId(circle.id);

      // Local edit queued but not yet pushed.
      await d.storage.upsertPatient(_patient(name: 'Local Edit'));
      await pumpEventQueue();

      await d.controller.pull();

      // The local-first guard preserved the unpushed edit.
      expect((await d.storage.getPatient())?.name, 'Local Edit');
    });

    test('applying a pulled patient does not echo back into the outbox',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle(
        'Mary',
        patient: SyncPatientWrite(
          payload: _patient(name: 'Remote').toJson(),
          clientUpdatedAt: 5000,
        ),
      );
      await d.stateStore.setCircleId(circle.id);

      await d.controller.pull();

      expect((await d.storage.getPatient())?.name, 'Remote');
      await pumpEventQueue();
      expect((await SyncOutbox(d.db).listPending()).isEmpty, isTrue,
          reason: 'a pulled patient is a remote apply, never a local edit');
    });
  });

  group('adopt/bootstrap cursor (2026-06-11) — never skip unseen docs', () {
    test('adoptJoinedCircle pulls docs whose rev is BELOW the patient rev',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);

      // History: circle created with a patient, a journal doc pushed,
      // then the patient re-pushed — its rev now exceeds the doc's.
      await backend.createCircle(
        'Mary',
        patient: SyncPatientWrite(
          payload: _patient().toJson(),
          clientUpdatedAt: 1000,
        ),
      );
      final CircleDto created = (await backend.listCircles()).single;
      await backend.syncPush(created.id, docs: <SyncDocWrite>[
        SyncDocWrite(
          id: 'j1',
          collection: 'journal_entries',
          payload: _journal('j1').toJson(),
          clientUpdatedAt: 1001,
        ),
      ]);
      await backend.syncPush(
        created.id,
        patient: SyncPatientWrite(
          payload: _patient(name: 'Mary Renamed').toJson(),
          clientUpdatedAt: 2000,
        ),
        docs: const <SyncDocWrite>[],
      );
      final CircleDto dto = (await backend.listCircles()).single;
      expect(dto.patient!.rev, greaterThan(1),
          reason: 'precondition: patient rev sits above the journal doc');

      await d.controller.adoptJoinedCircle(dto);

      // The doc below the patient's rev arrived — the old cursor seeding
      // (cursor = patient.rev) skipped it forever.
      expect((await d.storage.listAllJournalEntries()).single.id, 'j1');
      expect((await d.storage.getPatient())?.name, 'Mary Renamed');
    });

    test(
        'adoptJoinedCircle caches the WHOLE roster locally so the People '
        'screen sees the inviter immediately (2026-06-14 roster bug)',
        () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);

      // The circle the join returned: owner + the inviter + the joiner.
      // Before the fix this roster was never cached, so the People screen
      // showed only the owner + herself until the next online refresh.
      final CircleDto joined = CircleDto(
        id: 'circle-1',
        name: 'Mary',
        ownerProfileId: 'owner-1',
        createdAt: DateTime.utc(2026, 1, 1),
        members: const <CircleMemberDto>[
          CircleMemberDto(
            profileId: 'owner-1',
            username: 'mom',
            displayName: 'Mom',
            role: 'owner',
          ),
          CircleMemberDto(
            profileId: 'inviter-1',
            username: 'sarah_h',
            displayName: 'Sarah',
            role: 'member',
          ),
          CircleMemberDto(
            profileId: 'me-1',
            username: null,
            displayName: 'Me',
            role: 'member',
          ),
        ],
      );

      await d.controller.adoptJoinedCircle(joined);

      final List<CircleMemberDto> cached = await d.circleMemberCache.list();
      expect(
        cached.map((CircleMemberDto m) => m.profileId).toSet(),
        <String>{'owner-1', 'inviter-1', 'me-1'},
        reason: 'every member — owner, inviter, self — must be cached',
      );
    });
  });

  group('resyncAllLocal (2026-06-11) — backfill, never overwrite', () {
    test('resync rows are stamped 0 and cannot beat another member\'s edit',
        () async {
      final FakeForumBackend shared = FakeForumBackend();
      final FakeForumApiClient clientA = FakeForumApiClient(backend: shared);
      final FakeForumApiClient clientB = FakeForumApiClient(backend: shared);
      final _Device a = _Device(clientA);
      final _Device b = _Device(clientB);
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      // A creates the circle and pushes a RECENT edit of med m1.
      final CircleDto circle = await clientA.createCircle('Mary');
      await a.stateStore.setCircleId(circle.id);
      await a.medications.upsertMedication(_med('m1', 'Donepezil 23mg NEW'));
      await pumpEventQueue();
      await a.controller.push();

      // B holds a STALE local copy written before any circle existed
      // (no outbox row), then joins and force-resyncs.
      await b.medications.applyingRemote(
        () => b.medications.upsertMedication(_med('m1', 'Donepezil OLD')),
      );
      await b.stateStore.setCircleId(circle.id);
      await b.controller.resyncAllLocal();

      // The circle still holds A's newer edit — the backfill lost LWW —
      // and B's own pull during resync brought the newer copy down.
      final SyncPullResult pulled = await clientA.syncPull(circle.id, since: 0);
      final SyncDoc med = pulled.docs
          .firstWhere((SyncDoc x) => x.collection == 'medication');
      expect(
        (jsonDecode(med.payload) as Map<String, dynamic>)['name'],
        'Donepezil 23mg NEW',
      );
      expect(
        (await b.medications.listMedications()).single.name,
        'Donepezil 23mg NEW',
      );
    });

    test('resync does NOT downgrade a pending real edit to the backfill '
        'stamp', () async {
      final FakeForumApiClient backend = FakeForumApiClient();
      final _Device d = _Device(backend);
      addTearDown(d.dispose);
      final CircleDto circle = await backend.createCircle('Mary');
      await d.stateStore.setCircleId(circle.id);

      // A live local edit sits in the outbox with a real timestamp.
      await d.medications.upsertMedication(_med('m1', 'Fresh Edit'));
      await pumpEventQueue();

      await d.controller.resyncAllLocal();

      // The pushed doc kept its real (non-zero) stamp — a resync running
      // over a pending edit must not weaken it to 0.
      final SyncPullResult pulled = await backend.syncPull(circle.id, since: 0);
      final SyncDoc med = pulled.docs
          .firstWhere((SyncDoc x) => x.collection == 'medication');
      expect(med.clientUpdatedAt, greaterThan(0));
      expect(
        (jsonDecode(med.payload) as Map<String, dynamic>)['name'],
        'Fresh Edit',
      );
    });
  });
}
