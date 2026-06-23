import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/care_circle_membership.dart';
import '../models/caregiver.dart';
import '../services/sync_sink.dart';

part 'care_circle_provider.g.dart';

/// Persistence for the care circle — caregivers + their memberships
/// (TASKS.md Phase 14.25).
///
/// Backs Care Team → Care Circle (BUILD_SPEC.md §5.14). Like the documents
/// repository it maps each model field onto a typed column rather than
/// blobbing a `payload`. Enums persist as `.name`; `DateTime`s persist as
/// epoch-ms. The membership table FKs onto the caregiver table with
/// `ON DELETE CASCADE`, so [deleteCaregiver] also clears that caregiver's
/// membership rows.
class CareCircleRepository with SyncSinkHost {
  CareCircleRepository(this._db);

  final HoldcloseDatabase _db;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  // ---- Caregivers -------------------------------------------------------

  /// Insert-or-replace [caregiver] by id.
  Future<void> upsertCaregiver(Caregiver caregiver) async {
    await _db.into(_db.caregiversTable).insertOnConflictUpdate(
          CaregiversTableCompanion.insert(
            id: caregiver.id,
            displayName: caregiver.displayName,
            role: caregiver.role.name,
            phone: Value<String?>(caregiver.phone),
            email: Value<String?>(caregiver.email),
            avatarPath: Value<String?>(caregiver.avatarPath),
          ),
        );
    emitUpsert('caregivers', caregiver.id, caregiver.toJson());
  }

  /// Drop the caregiver with this id (cascading to their memberships).
  /// No-op if absent.
  Future<void> deleteCaregiver(String id) async {
    await (_db.delete(_db.caregiversTable)..where((t) => t.id.equals(id)))
        .go();
    emitDelete('caregivers', id);
  }

  /// One caregiver by id, or null if absent.
  Future<Caregiver?> getCaregiver(String id) async {
    final CaregiversTableData? row = await (_db.select(_db.caregiversTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _decodeCaregiver(row);
  }

  /// Every caregiver, ordered by display name.
  Future<List<Caregiver>> listCaregivers() async {
    final List<CaregiversTableData> rows = await (_db
            .select(_db.caregiversTable)
          ..orderBy(<OrderClauseGenerator<$CaregiversTableTable>>[
            (t) => OrderingTerm(expression: t.displayName),
          ]))
        .get();
    return rows.map(_decodeCaregiver).toList();
  }

  // ---- Memberships ------------------------------------------------------

  /// Insert-or-replace [membership] by id.
  Future<void> upsertMembership(CareCircleMembership membership) async {
    await _db.into(_db.careCircleMembershipsTable).insertOnConflictUpdate(
          CareCircleMembershipsTableCompanion.insert(
            id: membership.id,
            caregiverId: membership.caregiverId,
            patientId: membership.patientId,
            permissionLevel: membership.permissionLevel.name,
            invitedAtMs: membership.invitedAt.millisecondsSinceEpoch,
            acceptedAtMs: Value<int?>(
              membership.acceptedAt?.millisecondsSinceEpoch,
            ),
          ),
        );
    emitUpsert(
        'care_circle_memberships', membership.id, membership.toJson());
  }

  /// Drop the membership with this id. No-op if absent.
  Future<void> deleteMembership(String id) async {
    await (_db.delete(_db.careCircleMembershipsTable)
          ..where((t) => t.id.equals(id)))
        .go();
    emitDelete('care_circle_memberships', id);
  }

  /// One membership by id, or null if absent.
  Future<CareCircleMembership?> getMembership(String id) async {
    final CareCircleMembershipsTableData? row =
        await (_db.select(_db.careCircleMembershipsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    return row == null ? null : _decodeMembership(row);
  }

  /// Every membership, oldest invite first.
  Future<List<CareCircleMembership>> listMemberships() async {
    final List<CareCircleMembershipsTableData> rows = await (_db
            .select(_db.careCircleMembershipsTable)
          ..orderBy(<OrderClauseGenerator<$CareCircleMembershipsTableTable>>[
            (t) => OrderingTerm(expression: t.invitedAtMs),
          ]))
        .get();
    return rows.map(_decodeMembership).toList();
  }

  // ---- Decoders ---------------------------------------------------------

  Caregiver _decodeCaregiver(CaregiversTableData row) => Caregiver(
        id: row.id,
        displayName: row.displayName,
        role: CaregiverRole.values.byName(row.role),
        phone: row.phone,
        email: row.email,
        avatarPath: row.avatarPath,
      );

  CareCircleMembership _decodeMembership(CareCircleMembershipsTableData row) =>
      CareCircleMembership(
        id: row.id,
        caregiverId: row.caregiverId,
        patientId: row.patientId,
        permissionLevel: PermissionLevel.values.byName(row.permissionLevel),
        invitedAt:
            DateTime.fromMillisecondsSinceEpoch(row.invitedAtMs, isUtc: true),
        acceptedAt: row.acceptedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row.acceptedAtMs!,
                isUtc: true),
      );
}

/// Riverpod-wired singleton (TASKS.md Phase 14.25). Care Team screens
/// reach for [careCircleRepositoryProvider] and never see the concrete
/// drift database — same indirection [documentsRepositoryProvider] uses.
///
/// In production the repo opens its own [HoldcloseDatabase] handle onto
/// the shared SQLite file; SQLite's per-connection serialization keeps
/// that safe. Tests build a [CareCircleRepository] directly against
/// `HoldcloseDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
@Riverpod(keepAlive: true)
CareCircleRepository careCircleRepositoryBackend(Ref ref) {
  final HoldcloseDatabase db = HoldcloseDatabase.open();
  ref.onDispose(db.close);
  return CareCircleRepository(db);
}

/// Alias for consumers — matches the `careCircleRepositoryProvider` name
/// the care-circle data exporter + shift/task/expense providers reach for.
final CareCircleRepositoryBackendProvider careCircleRepositoryProvider =
    careCircleRepositoryBackendProvider;
