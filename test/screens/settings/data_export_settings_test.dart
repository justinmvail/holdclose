import 'dart:convert';
import 'dart:typed_data';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/tts_provider.dart';
import 'package:holdclose/screens/settings/settings_screen.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/services/appointment_repository.dart';
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
Future<({RecordingDataFileSharer sharer, HoldcloseDatabase db})>
    _pumpSettings(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  addTearDown(() async => db.close());
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  await storage.upsertPatient(maryHenderson());

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
  );
  final RecordingDataFileSharer sharer = RecordingDataFileSharer();

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
        ttsProvider.overrideWith((Ref _) => const NoopTTSProvider()),
        exportSourcesProvider.overrideWithValue(sources),
        dataFileSharerProvider.overrideWithValue(sharer),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pump();
  return (sharer: sharer, db: db);
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
      final ({RecordingDataFileSharer sharer, HoldcloseDatabase db}) pumped =
          await _pumpSettings(tester);

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
  });
}
