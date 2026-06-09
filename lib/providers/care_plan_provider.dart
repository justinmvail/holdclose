import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/care_plan_routine.dart';
import '../models/medication.dart' show FrequencyKind;
import '../services/sync_sink.dart';

part 'care_plan_provider.g.dart';

/// Drift-backed persistence for [CarePlanRoutine] rows (BUILD_SPEC.md
/// §5.13 v2). Same blob-with-lifted-keys pattern as [Medication] +
/// [HealthLogEntry]: the freezed routine serialises into the
/// [CarePlanRoutinesTable.payload] column; the lifted-out
/// [CarePlanRoutinesTable.scheduledMinute] keeps the "today's
/// routines" expansion from decoding every row to know the start time.
class CarePlanRepository with SyncSinkHost {
  CarePlanRepository(this._db);

  final CareblazersDatabase _db;

  Future<void> close() => _db.close();

  /// All routines for the active patient, sorted by wall-clock time.
  Future<List<CarePlanRoutine>> listAll() async {
    final List<CarePlanRoutinesTableData> rows = await (_db
            .select(_db.carePlanRoutinesTable)
          ..orderBy(<OrderingTerm Function($CarePlanRoutinesTableTable)>[
            ($CarePlanRoutinesTableTable t) =>
                OrderingTerm(expression: t.scheduledMinute),
          ]))
        .get();
    return <CarePlanRoutine>[
      for (final CarePlanRoutinesTableData row in rows)
        CarePlanRoutine.fromJson(
          jsonDecode(row.payload) as Map<String, dynamic>,
        ),
    ];
  }

  /// Upsert by [CarePlanRoutine.id]. Re-encodes the lifted-out minute.
  Future<void> upsert(CarePlanRoutine routine) async {
    final int minute =
        routine.scheduledTime.hour * 60 + routine.scheduledTime.minute;
    await _db.into(_db.carePlanRoutinesTable).insertOnConflictUpdate(
          CarePlanRoutinesTableCompanion(
            id: Value<String>(routine.id),
            patientId: Value<String>(routine.patientId),
            scheduledMinute: Value<int>(minute),
            payload: Value<String>(jsonEncode(routine.toJson())),
          ),
        );
    emitUpsert('care_plan_routines', routine.id, routine.toJson());
  }

  /// Delete by id. Idempotent; deleting a missing row is a no-op.
  Future<void> delete(String id) async {
    await (_db.delete(_db.carePlanRoutinesTable)
          ..where(($CarePlanRoutinesTableTable t) => t.id.equals(id)))
        .go();
    emitDelete('care_plan_routines', id);
  }

  /// Expand a [CarePlanRoutine] into its individual occurrence
  /// `DateTime`s in `[from, to]`. Daily frequency emits one per day;
  /// weekly emits only on days listed in [CarePlanRoutine.daysOfWeek];
  /// [FrequencyKind.asNeeded] emits nothing (it's not time-keyed).
  /// Mirrors [MedicationRepository._expandSchedule] without the
  /// per-day `timesOfDay` list, since a routine has a single anchor.
  Iterable<DateTime> expand(
    CarePlanRoutine routine,
    DateTime from,
    DateTime to,
  ) sync* {
    if (routine.frequencyKind == FrequencyKind.asNeeded) return;

    final DateTime windowStart =
        from.isBefore(routine.startsOn) ? routine.startsOn : from;
    final DateTime? endsOn = routine.endsOn;
    final DateTime windowEnd =
        endsOn != null && endsOn.isBefore(to) ? endsOn : to;
    if (windowEnd.isBefore(windowStart)) return;

    DateTime day =
        DateTime(windowStart.year, windowStart.month, windowStart.day);
    final DateTime lastDay =
        DateTime(windowEnd.year, windowEnd.month, windowEnd.day);
    while (!day.isAfter(lastDay)) {
      if (routine.frequencyKind == FrequencyKind.weekly &&
          !routine.daysOfWeek.contains(day.weekday)) {
        day = day.add(const Duration(days: 1));
        continue;
      }
      final DateTime occurrence = DateTime(
        day.year,
        day.month,
        day.day,
        routine.scheduledTime.hour,
        routine.scheduledTime.minute,
      );
      if (!occurrence.isBefore(windowStart) &&
          !occurrence.isAfter(windowEnd)) {
        yield occurrence;
      }
      day = day.add(const Duration(days: 1));
    }
  }
}

@Riverpod(keepAlive: true)
CarePlanRepository carePlanRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return CarePlanRepository(db);
}

final CarePlanRepositoryBackendProvider carePlanRepositoryProvider =
    carePlanRepositoryBackendProvider;

/// AsyncNotifier exposing the routine list. Mutations call repo methods
/// then refresh `state` so consumers re-render.
@Riverpod(keepAlive: true)
class CarePlan extends _$CarePlan {
  @override
  Future<List<CarePlanRoutine>> build() async {
    final CarePlanRepository repo = ref.watch(carePlanRepositoryProvider);
    return repo.listAll();
  }

  Future<void> upsert(CarePlanRoutine routine) async {
    final CarePlanRepository repo = ref.read(carePlanRepositoryProvider);
    await repo.upsert(routine);
    state = AsyncValue<List<CarePlanRoutine>>.data(await repo.listAll());
  }

  Future<void> delete(String id) async {
    final CarePlanRepository repo = ref.read(carePlanRepositoryProvider);
    await repo.delete(id);
    state = AsyncValue<List<CarePlanRoutine>>.data(await repo.listAll());
  }
}
