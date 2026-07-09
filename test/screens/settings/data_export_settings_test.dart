import 'dart:convert';
import 'dart:typed_data';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/models/settings.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/tts_provider.dart';
import 'package:holdclose/screens/settings/settings_screen.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/data_exporter.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/documents_provider.dart';
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pump the Settings screen with the data-export seams overridden so the
/// "Back up my data" row runs end-to-end without hitting the drift file
/// (`HoldcloseDatabase.open()`) or the `share_plus` platform channel:
///   - [exportSourcesProvider] → sources backed by an in-memory DB +
///     [InMemoryStorageProvider] (seeded with the demo loved one).
///   - [dataFileSharerProvider] → [RecordingDataFileSharer] so the test
///     asserts the bytes + filename the row handed off.
///   - storage + tts are pinned the same way the sibling settings test
///     does so the screen renders without sqlite / flutter_tts.
Future<
    ({
      RecordingDataFileSharer sharer,
      HoldcloseDatabase db,
      InMemoryStorageProvider storage,
      ExportSources sources,
    })> _pumpSettings(
  WidgetTester tester, {
  DataFilePicker? picker,
  bool seedPatient = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  addTearDown(() async => db.close());
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  if (seedPatient) await storage.upsertPatient(maryHenderson());

  final ExportSources sources = (
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
  final RecordingDataFileSharer sharer = RecordingDataFileSharer();

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
        ttsProvider.overrideWith((Ref _) => const NoopTTSProvider()),
        exportSourcesProvider.overrideWithValue(sources),
        dataFileSharerProvider.overrideWithValue(sharer),
        if (picker != null)
          dataFilePickerProvider.overrideWithValue(picker),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pump();
  return (sharer: sharer, db: db, storage: storage, sources: sources);
}

void main() {
  group('Settings — Back up my data (Issue #20)', () {
    testWidgets('renders the Your data section + backup row',
        (WidgetTester tester) async {
      await _pumpSettings(tester);

      expect(find.byKey(SettingsScreen.dataSectionKey), findsOneWidget);
      expect(find.text('Your data'), findsOneWidget);
      expect(find.byKey(SettingsScreen.backupDataButtonKey), findsOneWidget);
      expect(find.text('Back up my data'), findsOneWidget);
    });

    testWidgets('tapping the row invokes the exporter and shares the JSON',
        (WidgetTester tester) async {
      final pumped = await _pumpSettings(tester);

      await tester.scrollUntilVisible(
        find.byKey(SettingsScreen.backupDataButtonKey),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      await tester.tap(find.byKey(SettingsScreen.backupDataButtonKey));
      // Drain the gather + share futures, then settle the success snackbar.
      await tester.pumpAndSettle();

      // The exporter ran and handed exactly one JSON file to the share seam.
      expect(pumped.sharer.shared, hasLength(1));
      final ({Uint8List bytes, String filename, String mimeType}) call =
          pumped.sharer.shared.single;
      expect(call.mimeType, 'application/json');
      expect(call.filename, endsWith('.json'));
      expect(call.filename, startsWith(DataExporter.filenamePrefix));

      // The shared bytes are the real export envelope, carrying the seeded
      // loved one — proof the row gathered through the exporter, not a stub.
      final Map<String, dynamic> parsed =
          jsonDecode(utf8.decode(call.bytes)) as Map<String, dynamic>;
      expect(parsed['schemaVersion'], dataExportSchemaVersion);
      final List<dynamic> patients = parsed['patients'] as List<dynamic>;
      expect(
        (patients.single as Map<String, dynamic>)['name'],
        'Mary Henderson',
      );

      // The confirmation snackbar surfaced.
      expect(find.text('Backup ready to share.'), findsOneWidget);
    });

    testWidgets('the export envelope carries the chat sections + v2 schema',
        (WidgetTester tester) async {
      final pumped = await _pumpSettings(tester);

      // Seed a chat thread + one message through the same repo the exporter
      // reads, so the backup should carry them.
      final DateTime at = DateTime.utc(2026, 6, 1, 9);
      await pumped.sources.chat.createConversation(
        id: 'conv-1',
        title: 'Sleep questions',
        createdAt: at,
      );
      await pumped.sources.chat.appendMessage(Message(
        id: 'msg-1',
        conversationId: 'conv-1',
        role: MessageRole.user,
        body: 'How do I help with sundowning?',
        citations: const <String>[],
        createdAt: at,
        streamingDone: true,
      ));

      await tester.scrollUntilVisible(
        find.byKey(SettingsScreen.backupDataButtonKey),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.tap(find.byKey(SettingsScreen.backupDataButtonKey));
      await tester.pumpAndSettle();

      final Map<String, dynamic> parsed = jsonDecode(
              utf8.decode(pumped.sharer.shared.single.bytes))
          as Map<String, dynamic>;
      expect(parsed['schemaVersion'], 2);
      expect(
        (parsed['chatConversations'] as List<dynamic>)
            .map((dynamic c) => (c as Map<String, dynamic>)['id']),
        contains('conv-1'),
      );
      expect(
        (parsed['chatMessages'] as List<dynamic>)
            .map((dynamic m) => (m as Map<String, dynamic>)['id']),
        contains('msg-1'),
      );
    });
  });

  group('Settings — Restore from backup (Issue #20)', () {
    testWidgets('renders the restore row', (WidgetTester tester) async {
      await _pumpSettings(tester);
      expect(find.byKey(SettingsScreen.restoreDataButtonKey), findsOneWidget);
      expect(find.text('Restore from backup'), findsOneWidget);
    });

    testWidgets(
        'picking a backup file restores the records + shows the count',
        (WidgetTester tester) async {
      // A minimal, valid backup envelope carrying one patient + valid
      // settings. Restoring it should write 2 records (patient + settings).
      final Map<String, dynamic> backup = <String, dynamic>{
        'schemaVersion': dataExportSchemaVersion,
        'exportedAt': DateTime.utc(2026, 6, 1).toIso8601String(),
        'patients': <Map<String, dynamic>>[maryHenderson().toJson()],
        'settings': AppSettings.defaults().toJson(),
      };
      final Uint8List bytes =
          Uint8List.fromList(utf8.encode(jsonEncode(backup)));
      final RecordingDataFilePicker picker =
          RecordingDataFilePicker(bytes: bytes);

      // Start with an EMPTY store so we can prove the restore landed.
      final pumped = await _pumpSettings(tester, picker: picker,
          seedPatient: false);
      expect(await pumped.storage.getPatient(), isNull);

      await tester.scrollUntilVisible(
        find.byKey(SettingsScreen.restoreDataButtonKey),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.tap(find.byKey(SettingsScreen.restoreDataButtonKey));
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      // patient + settings = 2 records restored.
      expect((await pumped.storage.getPatient())!.name, 'Mary Henderson');
      expect(find.textContaining('Restored 2 records'), findsOneWidget);
    });

    testWidgets('cancelling the picker changes nothing (no snackbar)',
        (WidgetTester tester) async {
      // A null-returning picker models the caregiver cancelling.
      final RecordingDataFilePicker picker = RecordingDataFilePicker();
      final pumped =
          await _pumpSettings(tester, picker: picker, seedPatient: false);

      await tester.scrollUntilVisible(
        find.byKey(SettingsScreen.restoreDataButtonKey),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.tap(find.byKey(SettingsScreen.restoreDataButtonKey));
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(await pumped.storage.getPatient(), isNull);
      expect(find.textContaining('Restored'), findsNothing);
    });

    testWidgets('a non-backup file is rejected with a clear message',
        (WidgetTester tester) async {
      // Random bytes that don't decode to a JSON object.
      final RecordingDataFilePicker picker = RecordingDataFilePicker(
        bytes: Uint8List.fromList(utf8.encode('not a backup')),
      );
      final pumped =
          await _pumpSettings(tester, picker: picker, seedPatient: false);

      await tester.scrollUntilVisible(
        find.byKey(SettingsScreen.restoreDataButtonKey),
        200.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.tap(find.byKey(SettingsScreen.restoreDataButtonKey));
      await tester.pumpAndSettle();

      expect(find.text("That file isn't a Holdclose backup."), findsOneWidget);
      expect(await pumped.storage.getPatient(), isNull);
    });
  });
}
