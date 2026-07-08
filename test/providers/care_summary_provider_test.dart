import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/care_summary_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/circle_member_cache_provider.dart';
import 'package:holdclose/providers/documents_provider.dart';
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/seed/demo_dataset.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Regression test for fb_1783047813260308 ("Couldn't build the summary").
///
/// The care-summary screen reads [careSummaryPdfProvider] exactly once via
/// `ref.read(...future)` with no live listener, so the autoDispose provider
/// is torn down on the next event-loop task. `NativeDatabase.memory()`
/// completes drift queries in microtasks that beat that dispose task, which
/// is why the suite never caught it — on a device the queries cross a
/// background DB isolate (real event-loop turns) and the chain was disposed
/// mid-gather. `NativeDatabase.createInBackground` reproduces the on-device
/// scheduling, so this test fails without the keepAlive link in the
/// provider body.
void main() {
  // A fixed "now" so the relative-dated seed is deterministic.
  DateTime clock() => DateTime(2026, 6, 10, 9, 0);

  late Directory tmp;
  late HoldcloseDatabase db;
  late StorageProvider storage;
  late MedicationRepository medications;
  late AppointmentRepository appointments;
  late DocumentsRepository documents;
  late ProviderContainer container;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('care_summary_repro');
    // CROSS-ISOLATE executor on purpose — see the library comment above.
    db = HoldcloseDatabase(
        NativeDatabase.createInBackground(File('${tmp.path}/repro.sqlite')));
    storage = DriftStorageProvider(db);
    medications = MedicationRepository(db, clock: clock);
    appointments = AppointmentRepository(db, clock: clock);
    documents = DocumentsRepository(db);
    final DemoDatasetSeeder seeder = DemoDatasetSeeder(
      storage: storage,
      medications: medications,
      appointments: appointments,
      providers: ProviderRepository(db),
      healthLog: HealthLogRepository(db),
      carePlan: CarePlanRepository(db),
      careTasks: CareTasksRepository(db),
      careShifts: CareShiftsRepository(db),
      expenses: ExpensesRepository(db),
      careCircle: CareCircleRepository(db),
      circleMemberCache: CircleMemberCacheRepository(db),
      careEvents: CareEventsRepository(db),
      documents: documents,
      chat: ChatRepository(db),
      currentCaregiverId: 'me-test',
      clock: clock,
    );
    await seeder.seedAll();

    container = ProviderContainer(
      overrides: <Override>[
        storageProvider.overrideWithValue(storage),
        medicationRepositoryBackendProvider.overrideWithValue(medications),
        appointmentRepositoryBackendProvider.overrideWithValue(appointments),
        documentsRepositoryBackendProvider.overrideWithValue(documents),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('one-shot .future read survives a cross-isolate DB and builds the PDF',
      () async {
    // Deliberately NO container.listen — the screen's one-shot read is the
    // exact shape that let autoDispose fire mid-gather.
    final Uint8List? bytes =
        await container.read(careSummaryPdfProvider.future);
    expect(bytes, isNotNull);
    expect(String.fromCharCodes(bytes!.take(4)), '%PDF');
  });
}
