import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_events_provider.dart';
import 'package:holdclose/providers/care_plan_provider.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart';
import 'package:holdclose/providers/circle_member_cache_provider.dart';
import 'package:holdclose/providers/documents_provider.dart';
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/health_log_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/visit_prep_provider.dart';
import 'package:holdclose/seed/demo_dataset.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/medication_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Guard test for the visit-prep/appeal cousin of fb_1783047813260308.
///
/// [careContextTextProvider] is read exactly once via `ref.read(...future)`
/// from the visit-prep and insurance-appeal button handlers with no live
/// listener. Today the gather only reads plain repository instances, so the
/// one-shot read is safe — but if anyone introduces a `ref.watch` of an
/// autoDispose provider into gatherChatContext, the child is disposed
/// mid-await on a device (exactly how careSummaryPdfProvider broke) and the
/// provider's catch silently collapses the result to ''. The cross-isolate
/// executor below reproduces on-device scheduling, so that regression turns
/// this test red instead of shipping as an invisible empty AI prompt.
void main() {
  DateTime clock() => DateTime(2026, 6, 10, 9, 0);

  late Directory tmp;
  late HoldcloseDatabase db;
  late StorageProvider storage;
  late MedicationRepository medications;
  late AppointmentRepository appointments;
  late DocumentsRepository documents;
  late CarePlanRepository carePlan;
  late HealthLogRepository healthLog;
  late ProviderContainer container;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('visit_prep_repro');
    // CROSS-ISOLATE executor on purpose — see the library comment above.
    db = HoldcloseDatabase(
        NativeDatabase.createInBackground(File('${tmp.path}/repro.sqlite')));
    storage = DriftStorageProvider(db);
    medications = MedicationRepository(db, clock: clock);
    appointments = AppointmentRepository(db, clock: clock);
    documents = DocumentsRepository(db);
    carePlan = CarePlanRepository(db);
    healthLog = HealthLogRepository(db);
    final DemoDatasetSeeder seeder = DemoDatasetSeeder(
      storage: storage,
      medications: medications,
      appointments: appointments,
      providers: ProviderRepository(db),
      healthLog: healthLog,
      carePlan: carePlan,
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
        carePlanRepositoryProvider.overrideWithValue(carePlan),
        healthLogRepositoryProvider.overrideWithValue(healthLog),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('one-shot .future read survives a cross-isolate DB and keeps the data',
      () async {
    // Deliberately NO container.listen — the button handlers' one-shot read
    // is the exact shape that let autoDispose fire mid-gather.
    final String context =
        await container.read(careContextTextProvider.future);
    expect(context, isNotEmpty);
    // The seeded demo persona must actually be in the gathered context —
    // '' or generic text means the gather silently failed.
    expect(context, contains('Mary'));
  });
}
