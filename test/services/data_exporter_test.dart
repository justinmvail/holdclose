import 'dart:convert';
import 'dart:typed_data';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/db/tables.dart';
import 'package:holdclose/models/appointment.dart';
import 'package:holdclose/models/health_log_entry.dart';
import 'package:holdclose/models/care_circle_membership.dart';
import 'package:holdclose/models/care_event.dart';
import 'package:holdclose/models/caregiver.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/models/document.dart';
import 'package:holdclose/models/expense.dart';
import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/documents_provider.dart';
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/data_exporter.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_test/flutter_test.dart';

/// Fixed instant so the `exportedAt` envelope stamp is deterministic.
DateTime _fixedNow() => DateTime.utc(2026, 6, 4, 9, 30);

/// Assemble an [ExportSources] over [db] (+ [storage]) — every drift repo
/// shares the one in-memory connection, mirroring the production wiring.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The native document-picker contract `RealDataFilePicker` speaks to both
  // `ios/Runner/DocumentPickerBridge.swift` and (for Android parity)
  // `android/.../DocumentImportBridge.kt`. Both hand the picked file's bytes
  // back over the `holdclose/document_import` channel's `pickJson` method —
  // decoded to a Dart `Uint8List` — or null on cancel. This group pins that
  // wire contract with a mock handler so both native twins have a Dart-side
  // spec to match; the settings screen's own tests use the recording fake.
  group('RealDataFilePicker — holdclose/document_import wire contract', () {
    const MethodChannel channel = MethodChannel('holdclose/document_import');
    const RealDataFilePicker picker = RealDataFilePicker();

    tearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    void handleWith(Future<Object?> Function() respond) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'pickJson');
        return respond();
      });
    }

    test('bytes from the native picker surface as a Uint8List', () async {
      final Uint8List backup =
          Uint8List.fromList(utf8.encode('{"schemaVersion":2}'));
      handleWith(() async => backup);

      final Uint8List? out = await picker.pickJsonFile();
      expect(out, isNotNull);
      // Round-trips to the JSON `importFromBytes` will hand to `jsonDecode`.
      expect(utf8.decode(out!), '{"schemaVersion":2}');
    });

    test('a null return (caregiver cancelled) yields null', () async {
      handleWith(() async => null);
      expect(await picker.pickJsonFile(), isNull);
    });

    test('MissingPluginException degrades to null, not a throw', () async {
      handleWith(() async => throw MissingPluginException('no channel'));
      expect(await picker.pickJsonFile(), isNull);
    });

    test('a native PlatformException degrades to null', () async {
      handleWith(
          () async => throw PlatformException(code: 'READ_FAILED'));
      expect(await picker.pickJsonFile(), isNull);
    });
  });

  group('DataExporter.gather — Issue #20', () {
    late HoldcloseDatabase db;
    late DriftStorageProvider storage;
    late ExportSources sources;

    setUp(() {
      // One in-memory DB shared across every repo — the same SQLite file the
      // real app shares, just memory-backed and isolated per test.
      db = HoldcloseDatabase(NativeDatabase.memory());
      storage = DriftStorageProvider(db);
      sources = _sourcesFor(db, storage);
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'exports the seeded patient, journal entry, and medication into the '
      'versioned envelope',
      () async {
        // Seed across a few of the repositories the gather reads.
        await storage.upsertPatient(maryHenderson());

        final JournalEntry entry = JournalEntry.wizard(
          id: 'journal-export-1',
          createdAt: DateTime.utc(2026, 6, 1, 8),
          situationText: 'Refused breakfast',
        );
        await storage.insertJournalEntry(entry);

        const Medication med = Medication(
          id: 'med-export-1',
          name: 'Donepezil',
          dosage: '10 mg',
          route: MedicationRoute.oral,
        );
        await sources.medications.upsertMedication(med);

        const DataExporter exporter = DataExporter(clock: _fixedNow);
        final Map<String, dynamic> doc = await exporter.gather(sources);

        // Envelope fields.
        expect(doc['schemaVersion'], dataExportSchemaVersion);
        expect(doc['exportedAt'], _fixedNow().toIso8601String());

        // Round-trip through a real JSON encode/decode so the assertions
        // exercise the same path the shared file does.
        final Uint8List bytes = await exporter.exportJson(sources);
        final Map<String, dynamic> parsed =
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

        // Patient name is present.
        final List<dynamic> patients = parsed['patients'] as List<dynamic>;
        expect(patients, hasLength(1));
        expect(
          (patients.single as Map<String, dynamic>)['name'],
          'Mary Henderson',
        );

        // Journal entry id is present.
        final List<dynamic> journal =
            parsed['journalEntries'] as List<dynamic>;
        expect(
          journal.map((dynamic e) => (e as Map<String, dynamic>)['id']),
          contains('journal-export-1'),
        );

        // Medication name is present.
        final List<dynamic> meds = parsed['medications'] as List<dynamic>;
        expect(
          meds.map((dynamic m) => (m as Map<String, dynamic>)['name']),
          contains('Donepezil'),
        );

        // Settings section is the AppSettings blob (never null — defaults).
        expect(parsed['settings'], isA<Map<String, dynamic>>());
      },
    );

    test(
      'gathers the medication trio — windows, window entries, and dose logs',
      () async {
        await storage.upsertPatient(maryHenderson());
        const String patientId = 'demo-patient-mary';

        const Medication med = Medication(
          id: 'med-trio',
          name: 'Memantine',
          dosage: '5 mg',
          route: MedicationRoute.oral,
        );
        await sources.medications.upsertMedication(med);

        const DoseWindow window = DoseWindow(
          id: 'win-morning',
          patientId: patientId,
          label: 'Morning',
          anchorTime: TimeOfDay(hour: 8, minute: 0),
          sortOrder: 0,
        );
        await sources.medications.upsertWindow(window);

        final MedicationWindowEntry windowEntry = MedicationWindowEntry(
          id: 'entry-1',
          medicationId: med.id,
          windowId: window.id,
          daysOfWeek: const <int>{},
          startsOn: DateTime.utc(2026, 6, 1),
        );
        await sources.medications.upsertEntry(windowEntry);

        final DoseLog log = DoseLog(
          id: 'log-1',
          medicationId: med.id,
          scheduledFor: DateTime.utc(2026, 6, 1, 8),
          takenAt: DateTime.utc(2026, 6, 1, 8, 5),
          status: DoseStatus.taken,
        );
        await sources.medications.upsertDoseLog(log);

        const DataExporter exporter = DataExporter(clock: _fixedNow);
        final Map<String, dynamic> doc = await exporter.gather(sources);

        expect(
          (doc['doseWindows'] as List<dynamic>)
              .map((dynamic w) => (w as Map<String, dynamic>)['id']),
          contains('win-morning'),
        );
        expect(
          (doc['medicationWindowEntries'] as List<dynamic>)
              .map((dynamic e) => (e as Map<String, dynamic>)['id']),
          contains('entry-1'),
        );
        expect(
          (doc['doseLogs'] as List<dynamic>)
              .map((dynamic l) => (l as Map<String, dynamic>)['id']),
          contains('log-1'),
        );
      },
    );

    test(
      'every documented section key is present even when the store is empty',
      () async {
        const DataExporter exporter = DataExporter(clock: _fixedNow);
        final Map<String, dynamic> doc = await exporter.gather(sources);

        const List<String> sectionKeys = <String>[
          'patients',
          'journalEntries',
          'medications',
          'doseWindows',
          'medicationWindowEntries',
          'doseLogs',
          'providers',
          'appointments',
          'healthLogEntries',
          'carePlanRoutines',
          'emergencyCards',
          'powerOfAttorneyDocs',
          'identificationDocs',
          'caregivers',
          'careCircleMemberships',
          'careEvents',
          'careTasks',
          'careShifts',
          'expenses',
          'chatConversations',
          'chatMessages',
        ];
        for (final String key in sectionKeys) {
          expect(doc[key], isA<List<dynamic>>(),
              reason: '$key should serialise as a (possibly empty) list');
          expect(doc[key], isEmpty, reason: '$key should be empty on a fresh '
              'store');
        }
        // Patient-less store still carries the envelope + settings.
        expect(doc['schemaVersion'], dataExportSchemaVersion);
        expect(doc['settings'], isA<Map<String, dynamic>>());
      },
    );

    test(
      'pulls appointments + providers + health-log entries through their repos',
      () async {
        await ProviderRepository(db).upsertProvider(const Provider(
          id: 'prov-1',
          name: 'Dr. Ortega',
          role: ProviderRole.neurologist,
          phone: '(415) 555-0188',
          address: '250 Bon Air Rd',
        ));
        await sources.appointments.upsertAppointment(Appointment(
          id: 'appt-1',
          providerId: 'prov-1',
          startsAt: DateTime.utc(2026, 6, 20, 14),
          durationMinutes: 30,
          location: 'Marin General',
          agenda: const <String>['Evening agitation'],
          status: AppointmentStatus.upcoming,
        ));
        await sources.healthLog.upsert(HealthLogEntry(
          id: 'hl-1',
          patientId: 'demo-patient-mary',
          kind: HealthLogKind.note,
          recordedAt: DateTime.utc(2026, 6, 3, 7),
          notes: 'Slept 6 hours',
        ));

        const DataExporter exporter = DataExporter(clock: _fixedNow);
        final Map<String, dynamic> doc = await exporter.gather(sources);

        expect(
          (doc['providers'] as List<dynamic>)
              .map((dynamic p) => (p as Map<String, dynamic>)['id']),
          contains('prov-1'),
        );
        expect(
          (doc['appointments'] as List<dynamic>)
              .map((dynamic a) => (a as Map<String, dynamic>)['id']),
          contains('appt-1'),
        );
        expect(
          (doc['healthLogEntries'] as List<dynamic>)
              .map((dynamic h) => (h as Map<String, dynamic>)['id']),
          contains('hl-1'),
        );
      },
    );

    test(
      'exports document rows carrying the R2 storage keys + a dose care '
      'event without throwing (regression: backup failed in settings)',
      () async {
        const String patientId = 'demo-patient-mary';
        await storage.upsertPatient(maryHenderson());

        // Emergency card with the new R2 attachmentKey populated.
        await sources.documents.upsertEmergencyCard(EmergencyCard(
          id: 'ec-1',
          patientId: patientId,
          updatedAt: DateTime.utc(2026, 6, 3),
          conditions: const <String>['Alzheimer\'s'],
          medications: const <String>['Donepezil'],
          allergies: const <String>['Penicillin'],
          emergencyContacts: const <EmergencyContact>[
            EmergencyContact(
                name: 'Sarah', relation: 'Daughter', phone: '555-0101'),
          ],
          insurance: const Insurance(
            carrier: 'Aetna',
            policyNumber: 'P-123',
            groupNumber: 'G-9',
          ),
          donorStatus: DonorStatus.donor,
          attachmentPath: '/local/ec.jpg',
          attachmentKey: 'r2/ec/attachment',
        ));

        // POA with both attachmentKey + scanKey populated.
        await sources.documents.upsertPoa(PowerOfAttorneyDoc(
          id: 'poa-1',
          patientId: patientId,
          updatedAt: DateTime.utc(2026, 6, 3),
          agentName: 'Sarah',
          scope: PoaScope.medical,
          effectiveDate: DateTime.utc(2025, 1, 1),
          scanPath: '/local/poa.pdf',
          scanKey: 'r2/poa/scan',
          attachmentPath: '/local/poa-att.jpg',
          attachmentKey: 'r2/poa/attachment',
        ));

        // ID doc with front/back/attachment R2 keys populated.
        await sources.documents.upsertId(IdentificationDoc(
          id: 'id-1',
          patientId: patientId,
          updatedAt: DateTime.utc(2026, 6, 3),
          kind: IdKind.driverLicense,
          idNumber: 'D-9988',
          photoFrontPath: '/local/front.jpg',
          photoBackPath: '/local/back.jpg',
          photoFrontKey: 'r2/id/front',
          photoBackKey: 'r2/id/back',
          attachmentPath: '/local/id-att.jpg',
          attachmentKey: 'r2/id/attachment',
        ));

        // A dose care event carrying the new windowLabel / windowSlot fields.
        await sources.careEvents.upsertEvent(CareEvent(
          id: 'ce-1',
          kind: CareEventKind.doseLogged,
          title: 'Donepezil',
          start: DateTime.utc(2026, 6, 3, 14, 15),
          patientId: patientId,
          windowLabel: 'Morning',
          windowSlot: DateTime.utc(2026, 6, 3, 8),
        ));

        const DataExporter exporter = DataExporter(clock: _fixedNow);

        // The whole pipeline (gather → encode → bytes) must not throw and
        // must yield valid JSON.
        final Uint8List bytes = await exporter.exportJson(sources);
        final Map<String, dynamic> parsed =
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

        // Each document section round-tripped its R2 key onto the JSON.
        final Map<String, dynamic> ec =
            (parsed['emergencyCards'] as List<dynamic>).single
                as Map<String, dynamic>;
        expect(ec['attachmentKey'], 'r2/ec/attachment');

        final Map<String, dynamic> poa =
            (parsed['powerOfAttorneyDocs'] as List<dynamic>).single
                as Map<String, dynamic>;
        expect(poa['scanKey'], 'r2/poa/scan');
        expect(poa['attachmentKey'], 'r2/poa/attachment');

        final Map<String, dynamic> id =
            (parsed['identificationDocs'] as List<dynamic>).single
                as Map<String, dynamic>;
        expect(id['photoFrontKey'], 'r2/id/front');
        expect(id['photoBackKey'], 'r2/id/back');
        expect(id['attachmentKey'], 'r2/id/attachment');

        final Map<String, dynamic> ce =
            (parsed['careEvents'] as List<dynamic>).single
                as Map<String, dynamic>;
        expect(ce['windowLabel'], 'Morning');
        expect(ce['windowSlot'], isNotNull);

        // The full populated doc round-trips through importInto cleanly too,
        // so the backup is restorable, not just writable.
        final HoldcloseDatabase dstDb =
            HoldcloseDatabase(NativeDatabase.memory());
        addTearDown(() async => dstDb.close());
        final DriftStorageProvider dstStorage = DriftStorageProvider(dstDb);
        final ExportSources dst = _sourcesFor(dstDb, dstStorage);
        await exporter.importInto(dst, parsed);
        expect((await dst.documents.listEmergencyCards()).single.attachmentKey,
            'r2/ec/attachment');
        expect((await dst.documents.listIds()).single.photoFrontKey,
            'r2/id/front');
      },
    );

    test(
      'a corrupt settings blob falls back to defaults instead of aborting '
      'the whole backup (resilience hardening)',
      () async {
        await storage.upsertPatient(maryHenderson());
        await storage.insertJournalEntry(JournalEntry.wizard(
          id: 'j-good',
          createdAt: DateTime.utc(2026, 6, 1, 8),
          situationText: 'Fine',
        ));

        // Poison the settings row with a blob that AppSettings.fromJson
        // can't decode (a JSON array where an object is required). Without
        // the defensive fallback this would throw straight out of gather and
        // surface to the caregiver as "Back up failed".
        await db.into(db.appSettingsTable).insertOnConflictUpdate(
              AppSettingsTableCompanion.insert(
                id: appSettingsSingletonId,
                payload: '[]',
              ),
            );

        const DataExporter exporter = DataExporter(clock: _fixedNow);
        final Uint8List bytes = await exporter.exportJson(sources);
        final Map<String, dynamic> parsed =
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

        // Backup still produced — settings degraded to a valid defaults blob,
        // and the rest of the data is intact.
        expect(parsed['settings'], isA<Map<String, dynamic>>());
        expect(
          (parsed['journalEntries'] as List<dynamic>)
              .map((dynamic e) => (e as Map<String, dynamic>)['id']),
          contains('j-good'),
        );
        expect((parsed['patients'] as List<dynamic>), hasLength(1));
      },
    );
  });

  group('DataExporter.exportAndShare — Issue #20', () {
    test('hands a date-stamped JSON file to the sharer', () async {
      final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final DriftStorageProvider storage = DriftStorageProvider(db);
      await storage.upsertPatient(maryHenderson());

      final ExportSources sources = _sourcesFor(db, storage);

      const DataExporter exporter = DataExporter(clock: _fixedNow);
      final RecordingDataFileSharer sharer = RecordingDataFileSharer();

      final String filename = await exporter.exportAndShare(sources, sharer);

      expect(filename, 'holdclose-backup-2026-06-04.json');
      expect(sharer.shared, hasLength(1));
      final ({Uint8List bytes, String filename, String mimeType}) call =
          sharer.shared.single;
      expect(call.filename, filename);
      expect(call.mimeType, 'application/json');

      // The shared bytes are the same JSON the exporter would write.
      final Map<String, dynamic> parsed =
          jsonDecode(utf8.decode(call.bytes)) as Map<String, dynamic>;
      expect(parsed['schemaVersion'], dataExportSchemaVersion);
      expect((parsed['patients'] as List<dynamic>).single,
          isA<Map<String, dynamic>>());
    });
  });

  group('DataExporter.importInto — Issue #20 (round-trip restore)', () {
    test(
      'export from a populated store then import into a fresh one restores '
      'every section',
      () async {
        // ── Source store: seed a cross-section spanning the FK chains. ──
        final HoldcloseDatabase srcDb =
            HoldcloseDatabase(NativeDatabase.memory());
        addTearDown(() async => srcDb.close());
        final DriftStorageProvider srcStorage = DriftStorageProvider(srcDb);
        final ExportSources src = _sourcesFor(srcDb, srcStorage);

        const String patientId = 'demo-patient-mary';
        await srcStorage.upsertPatient(maryHenderson());
        await srcStorage.insertJournalEntry(JournalEntry.wizard(
          id: 'j-1',
          createdAt: DateTime.utc(2026, 6, 1, 8),
          situationText: 'Sundowning',
        ));

        // Medication chain: med → window → entry → log.
        const Medication med = Medication(
          id: 'm-1',
          name: 'Donepezil',
          dosage: '10 mg',
          route: MedicationRoute.oral,
        );
        await src.medications.upsertMedication(med);
        const DoseWindow window = DoseWindow(
          id: 'w-1',
          patientId: patientId,
          label: 'Morning',
          anchorTime: TimeOfDay(hour: 8, minute: 0),
          sortOrder: 0,
        );
        await src.medications.upsertWindow(window);
        await src.medications.upsertEntry(MedicationWindowEntry(
          id: 'we-1',
          medicationId: med.id,
          windowId: window.id,
          daysOfWeek: const <int>{},
          startsOn: DateTime.utc(2026, 6, 1),
        ));
        await src.medications.upsertDoseLog(DoseLog(
          id: 'dl-1',
          medicationId: med.id,
          scheduledFor: DateTime.utc(2026, 6, 1, 8),
          status: DoseStatus.taken,
        ));

        // Provider → appointment chain.
        await src.providers.upsertProvider(const Provider(
          id: 'p-1',
          name: 'Dr. Ortega',
          role: ProviderRole.neurologist,
          phone: '(415) 555-0188',
          address: '250 Bon Air Rd',
        ));
        await src.appointments.upsertAppointment(Appointment(
          id: 'a-1',
          providerId: 'p-1',
          startsAt: DateTime.utc(2026, 6, 20, 14),
          durationMinutes: 30,
          location: 'Marin General',
          agenda: const <String>[],
          status: AppointmentStatus.upcoming,
        ));

        // Caregiver → membership chain.
        await src.careCircle.upsertCaregiver(const Caregiver(
          id: 'c-1',
          displayName: 'Sarah',
          role: CaregiverRole.child,
        ));
        await src.careCircle.upsertMembership(CareCircleMembership(
          id: 'cm-1',
          caregiverId: 'c-1',
          patientId: patientId,
          permissionLevel: PermissionLevel.owner,
          invitedAt: DateTime.utc(2026, 5, 1),
        ));

        // A standalone Care Team row.
        await src.expenses.upsertExpense(Expense(
          id: 'e-1',
          amountCents: 4200,
          description: 'Pharmacy copay',
          paidByCaregiverId: 'c-1',
          paidAt: DateTime.utc(2026, 6, 2),
          kind: ExpenseKind.meds,
          patientId: patientId,
        ));

        // ── Export, then round-trip the bytes through JSON. ──
        const DataExporter exporter = DataExporter(clock: _fixedNow);
        final Uint8List bytes = await exporter.exportJson(src);
        final Map<String, dynamic> doc =
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

        // ── Destination store: fresh + empty. ──
        final HoldcloseDatabase dstDb =
            HoldcloseDatabase(NativeDatabase.memory());
        addTearDown(() async => dstDb.close());
        final DriftStorageProvider dstStorage = DriftStorageProvider(dstDb);
        final ExportSources dst = _sourcesFor(dstDb, dstStorage);

        // Sanity: the destination starts empty.
        expect(await dstStorage.getPatient(), isNull);

        final int written = await exporter.importInto(dst, doc);
        // patient + settings + journal + med + window + entry + log +
        // provider + appt + caregiver + membership + expense = 12.
        expect(written, 12);

        // ── Verify the restore landed in the destination repos. ──
        expect((await dstStorage.getPatient())!.name, 'Mary Henderson');
        expect((await dstStorage.listAllJournalEntries()).map((e) => e.id),
            contains('j-1'));

        final List<Medication> meds = await dst.medications.listMedications();
        expect(meds.map((Medication m) => m.id), contains('m-1'));
        expect(await dst.medications.windowsForPatient(patientId),
            hasLength(1));
        expect((await dst.medications.entriesForMedication('m-1')).single.id,
            'we-1');
        expect((await dst.medications.logsFor('m-1')).single.id, 'dl-1');

        expect((await dst.providers.listProviders()).single.id, 'p-1');
        expect((await dst.appointments.listAppointments()).single.id, 'a-1');
        expect((await dst.careCircle.listCaregivers()).single.id, 'c-1');
        expect((await dst.careCircle.listMemberships()).single.id, 'cm-1');
        expect((await dst.expenses.listExpenses()).single.id, 'e-1');

        // ── Re-importing the same doc is idempotent (upsert by id). ──
        final int writtenAgain = await exporter.importInto(dst, doc);
        expect(writtenAgain, 12);
        expect(await dst.medications.listMedications(), hasLength(1));
        expect(await dst.expenses.listExpenses(), hasLength(1));
      },
    );

    test('chat conversations + messages round-trip through export/import',
        () async {
      final HoldcloseDatabase srcDb =
          HoldcloseDatabase(NativeDatabase.memory());
      addTearDown(() async => srcDb.close());
      final DriftStorageProvider srcStorage = DriftStorageProvider(srcDb);
      final ExportSources src = _sourcesFor(srcDb, srcStorage);

      final DateTime at = DateTime.utc(2026, 6, 1, 9);
      await src.chat.createConversation(
        id: 'conv-1',
        title: 'Sleep',
        createdAt: at,
      );
      await src.chat.appendMessage(Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        body: 'How do I help with sundowning?',
        citations: const <String>[],
        createdAt: at,
        streamingDone: true,
      ));
      await src.chat.appendMessage(Message(
        id: 'msg-2',
        conversationId: 'conv-1',
        role: MessageRole.assistant,
        body: 'A calm evening routine can help.',
        citations: const <String>['card-sundowning'],
        createdAt: at.add(const Duration(seconds: 1)),
        streamingDone: true,
      ));

      const DataExporter exporter = DataExporter(clock: _fixedNow);
      final Uint8List bytes = await exporter.exportJson(src);
      final Map<String, dynamic> doc =
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      // The envelope carries both chat sections.
      expect(doc['schemaVersion'], 2);
      expect((doc['chatConversations'] as List<dynamic>), hasLength(1));
      expect((doc['chatMessages'] as List<dynamic>), hasLength(2));

      // Restore into a fresh store and verify the thread + its messages land.
      final HoldcloseDatabase dstDb =
          HoldcloseDatabase(NativeDatabase.memory());
      addTearDown(() async => dstDb.close());
      final DriftStorageProvider dstStorage = DriftStorageProvider(dstDb);
      final ExportSources dst = _sourcesFor(dstDb, dstStorage);

      await exporter.importInto(dst, doc);

      final List<Conversation> convos = await dst.chat.listConversations();
      expect(convos.map((Conversation c) => c.id), contains('conv-1'));
      final List<Message> msgs = await dst.chat.loadMessages('conv-1');
      expect(msgs.map((Message m) => m.id), <String>['msg-1', 'msg-2']);
      expect(msgs.last.citations, contains('card-sundowning'));
    });

    test('import tolerates a doc missing optional sections', () async {
      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final DriftStorageProvider storage = DriftStorageProvider(db);
      final ExportSources sources = _sourcesFor(db, storage);

      // Only an envelope + one patient — every other section absent.
      final Map<String, dynamic> doc = <String, dynamic>{
        'schemaVersion': dataExportSchemaVersion,
        'exportedAt': _fixedNow().toIso8601String(),
        'patients': <Map<String, dynamic>>[maryHenderson().toJson()],
      };

      final int written = await const DataExporter().importInto(sources, doc);
      expect(written, 1);
      expect((await storage.getPatient())!.name, 'Mary Henderson');
    });
  });
}
