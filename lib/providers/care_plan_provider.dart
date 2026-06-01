import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/care_plan_section.dart';

part 'care_plan_provider.g.dart';

/// Persistence for the care plan (TASKS.md Phase 14.18).
///
/// Wraps the single drift table [CarePlanSectionsTable] behind plain
/// CRUD plus a [bySlot] query. Each [CarePlanSection] serialises through
/// its `toJson` shape into the row's `payload` column — same blob-with-
/// lifted-keys pattern [HealthLogRepository] / [AppointmentRepository]
/// use; the lifted [CarePlanSectionsTable.slot] +
/// [CarePlanSectionsTable.orderIndex] columns keep the [bySlot] filter +
/// ordering off the blob.
///
/// The repository owns reads and raw row writes only — the per-slot
/// ordering invariant (contiguous, duplicate-free [CarePlanSection.order]
/// per slot; gaps closed on delete) is enforced one level up by the
/// [CarePlan] notifier, which is the single writer in the app.
///
/// There's no provider/FK cascade to worry about — the care-plan table
/// stands alone (see `lib/db/tables.dart` for why the [patientId] link
/// is logical, not a DB foreign key).
class CarePlanRepository {
  CarePlanRepository(this._db);

  final CareblazersDatabase _db;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  /// Insert-or-replace [section] by id. The lifted columns are kept in
  /// sync with the blob so the [bySlot] read never parses a payload to
  /// filter or order.
  Future<void> upsert(CarePlanSection section) async {
    await _db.into(_db.carePlanSectionsTable).insertOnConflictUpdate(
          CarePlanSectionsTableCompanion.insert(
            id: section.id,
            patientId: section.patientId,
            slot: section.slot.name,
            orderIndex: section.order,
            payload: jsonEncode(section.toJson()),
          ),
        );
  }

  /// Drop the row with this id. No-op if absent.
  Future<void> delete(String id) async {
    await (_db.delete(_db.carePlanSectionsTable)
          ..where((t) => t.id.equals(id)))
        .go();
  }

  /// One section by id, or null if absent.
  Future<CarePlanSection?> getById(String id) async {
    final CarePlanSectionsTableData? row =
        await (_db.select(_db.carePlanSectionsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    if (row == null) return null;
    return _decode(row.payload);
  }

  /// Every section, grouped by [slot] then by [orderIndex] ascending so
  /// the list reads as the daily timeline the screen renders.
  Future<List<CarePlanSection>> listAll() async {
    final List<CarePlanSectionsTableData> rows =
        await (_db.select(_db.carePlanSectionsTable)
              ..orderBy(<OrderClauseGenerator<$CarePlanSectionsTableTable>>[
                (t) => OrderingTerm(expression: t.slot),
                (t) => OrderingTerm(expression: t.orderIndex),
              ]))
            .get();
    return rows
        .map((CarePlanSectionsTableData r) => _decode(r.payload))
        .toList();
  }

  /// Every section in [slot], ordered by [CarePlanSection.order]
  /// ascending. The orders are contiguous (0-based, no gaps) because the
  /// [CarePlan] notifier renumbers the slot after every mutation.
  Future<List<CarePlanSection>> bySlot(CarePlanSlot slot) async {
    final List<CarePlanSectionsTableData> rows =
        await (_db.select(_db.carePlanSectionsTable)
              ..where((t) => t.slot.equals(slot.name))
              ..orderBy(<OrderClauseGenerator<$CarePlanSectionsTableTable>>[
                (t) => OrderingTerm(expression: t.orderIndex),
              ]))
            .get();
    return rows
        .map((CarePlanSectionsTableData r) => _decode(r.payload))
        .toList();
  }

  CarePlanSection _decode(String payload) =>
      CarePlanSection.fromJson(jsonDecode(payload) as Map<String, dynamic>);
}

/// Riverpod-wired singleton (TASKS.md Phase 14.18). The care-plan screen
/// + add form (later Phase 14 tasks) reach for
/// [carePlanRepositoryProvider] and never see the concrete drift
/// database — same indirection [healthLogRepositoryProvider] uses.
///
/// In production the repo opens its own [CareblazersDatabase] handle onto
/// the shared SQLite file; SQLite's per-connection serialization keeps
/// that safe. Tests build a [CarePlanRepository] directly against
/// `CareblazersDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
///
/// Named `carePlanRepositoryBackend` so the generated class is
/// [CarePlanRepositoryBackendProvider], leaving room for the
/// natural-language [carePlanRepositoryProvider] alias below.
@Riverpod(keepAlive: true)
CarePlanRepository carePlanRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return CarePlanRepository(db);
}

/// Alias for consumers — matches the `carePlanRepositoryProvider` name
/// the care-plan screens reach for.
final CarePlanRepositoryBackendProvider carePlanRepositoryProvider =
    carePlanRepositoryBackendProvider;

/// The loved one's care plan (TASKS.md Phase 14.18).
///
/// `build()` loads every section grouped by slot then order; [add],
/// [updateSection], [reorder], and [delete] mutate through
/// [carePlanRepositoryProvider] and re-read the list so the screen
/// reflects the write without a manual invalidate. The [bySlot] selector
/// filters the already-loaded state synchronously so a `ConsumerWidget`
/// can call it in `build` without awaiting.
///
/// This notifier is the single writer for the table, and it owns the
/// per-slot ordering invariant:
///
/// - [add] appends a section at the end of its slot ([order] == the
///   slot's current count), so the new row never collides with an
///   existing index.
/// - [delete] renumbers the affected slot's survivors back to 0..n-1, so
///   the gap the removed row left is closed.
/// - [reorder] reassigns the slot's orders to match a caller-supplied id
///   sequence, again landing on a contiguous 0..n-1 run.
///
/// The net effect: within any slot the orders are always a clean,
/// duplicate-free 0-based index — never a sparse sort key.
///
/// `keepAlive: true` so the care-plan screen and a quick add from a
/// floating "+" action share one cached list.
@Riverpod(keepAlive: true)
class CarePlan extends _$CarePlan {
  @override
  Future<List<CarePlanSection>> build() async {
    final CarePlanRepository repo = ref.watch(carePlanRepositoryProvider);
    return repo.listAll();
  }

  /// Append [section] to the end of its slot, then refresh. The incoming
  /// [CarePlanSection.order] is overwritten with the slot's current count
  /// so the invariant holds no matter what the caller passed.
  Future<void> add(CarePlanSection section) =>
      _mutate((CarePlanRepository repo) async {
        final List<CarePlanSection> slotSections =
            await repo.bySlot(section.slot);
        await repo.upsert(section.copyWith(order: slotSections.length));
      });

  /// Persist an edit to an existing section (upsert by id), then refresh.
  /// Intended for content edits (title / body / stage) that keep the
  /// section in its current slot + position — the caller passes the
  /// section back with its existing [CarePlanSection.order] and [slot].
  ///
  /// Named `updateSection` rather than `update` because Riverpod's
  /// `AsyncNotifier` already defines an `update(...)` method with an
  /// incompatible signature — overriding it isn't allowed.
  Future<void> updateSection(CarePlanSection section) =>
      _mutate((CarePlanRepository repo) => repo.upsert(section));

  /// Reorder [slot] to match [orderedIds] — the section ids in their new
  /// top-to-bottom order — then refresh. Each section's
  /// [CarePlanSection.order] is reassigned to its index in [orderedIds]
  /// (0..n-1), and only rows whose order actually changed are rewritten.
  /// Ids not currently in [slot] are ignored.
  Future<void> reorder(CarePlanSlot slot, List<String> orderedIds) =>
      _mutate((CarePlanRepository repo) async {
        final List<CarePlanSection> slotSections = await repo.bySlot(slot);
        final Map<String, CarePlanSection> byId = <String, CarePlanSection>{
          for (final CarePlanSection s in slotSections) s.id: s,
        };
        for (int i = 0; i < orderedIds.length; i++) {
          final CarePlanSection? s = byId[orderedIds[i]];
          if (s != null && s.order != i) {
            await repo.upsert(s.copyWith(order: i));
          }
        }
      });

  /// Delete the section with this id, then close the gap it left by
  /// renumbering its slot's survivors back to a contiguous 0..n-1, then
  /// refresh.
  Future<void> delete(String id) => _mutate((CarePlanRepository repo) async {
        final CarePlanSection? removed = await repo.getById(id);
        await repo.delete(id);
        if (removed != null) {
          await _compactSlot(repo, removed.slot);
        }
      });

  /// Renumber [slot]'s sections to a contiguous 0..n-1 run, preserving
  /// their current relative order. Only rows whose order changed are
  /// rewritten.
  Future<void> _compactSlot(CarePlanRepository repo, CarePlanSlot slot) async {
    final List<CarePlanSection> slotSections = await repo.bySlot(slot);
    for (int i = 0; i < slotSections.length; i++) {
      final CarePlanSection s = slotSections[i];
      if (s.order != i) {
        await repo.upsert(s.copyWith(order: i));
      }
    }
  }

  /// Run [op] against the repo, then reload the list into [state]. The
  /// current data stays visible until the reload lands (no transient
  /// loading flash); a throw from [op] surfaces as [AsyncValue.error].
  Future<void> _mutate(
    Future<void> Function(CarePlanRepository repo) op,
  ) async {
    final CarePlanRepository repo = ref.read(carePlanRepositoryProvider);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listAll();
    });
  }

  /// Sections belonging to [slot], ordered by [CarePlanSection.order].
  /// Reads off the already-loaded list; empty while the first load is
  /// still in flight.
  List<CarePlanSection> bySlot(CarePlanSlot slot) =>
      (state.asData?.value ?? const <CarePlanSection>[])
          .where((CarePlanSection s) => s.slot == slot)
          .toList()
        ..sort((CarePlanSection a, CarePlanSection b) =>
            a.order.compareTo(b.order));
}
