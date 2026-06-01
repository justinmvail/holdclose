import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/care_circle_membership.dart';
import '../models/caregiver.dart';

part 'care_circle_provider.g.dart';

/// One care-circle row pairing a [Caregiver] with their
/// [CareCircleMembership] (TASKS.md Phase 14.25).
///
/// The roster (BUILD_SPEC.md §5.14) renders one of these per member — the
/// caregiver supplies the name / role / contact + avatar, the membership
/// supplies the permission badge and the pending-invite state. Bundled so
/// the screen consumes a single joined shape rather than re-joining two
/// lists itself.
@immutable
class CareCircleMember {
  const CareCircleMember({required this.caregiver, required this.membership});

  final Caregiver caregiver;
  final CareCircleMembership membership;

  /// True while the invite hasn't been accepted (acceptedAt still null).
  bool get isPending => membership.acceptedAt == null;
}

/// Persistence for the care circle — caregivers + their memberships
/// (TASKS.md Phase 14.25).
///
/// Backs Care Team → Care Circle (BUILD_SPEC.md §5.14). Like the documents
/// repository it maps each model field onto a typed column rather than
/// blobbing a `payload`. Enums persist as `.name`; `DateTime`s persist as
/// epoch-ms. The membership table FKs onto the caregiver table with
/// `ON DELETE CASCADE`, so [deleteCaregiver] also clears that caregiver's
/// membership rows.
class CareCircleRepository {
  CareCircleRepository(this._db);

  final CareblazersDatabase _db;

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
  }

  /// Drop the caregiver with this id (cascading to their memberships).
  /// No-op if absent.
  Future<void> deleteCaregiver(String id) async {
    await (_db.delete(_db.caregiversTable)..where((t) => t.id.equals(id)))
        .go();
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
  }

  /// Drop the membership with this id. No-op if absent.
  Future<void> deleteMembership(String id) async {
    await (_db.delete(_db.careCircleMembershipsTable)
          ..where((t) => t.id.equals(id)))
        .go();
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
/// In production the repo opens its own [CareblazersDatabase] handle onto
/// the shared SQLite file; SQLite's per-connection serialization keeps
/// that safe. Tests build a [CareCircleRepository] directly against
/// `CareblazersDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
@Riverpod(keepAlive: true)
CareCircleRepository careCircleRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return CareCircleRepository(db);
}

/// Alias for consumers — matches the `careCircleRepositoryProvider` name
/// the Care Circle screens reach for.
final CareCircleRepositoryBackendProvider careCircleRepositoryProvider =
    careCircleRepositoryBackendProvider;

/// Wall clock used to stamp invite acceptance. Overridable so tests pin a
/// fixed time and the accept-invite transition stays deterministic.
@Riverpod(keepAlive: true)
DateTime Function() careCircleClock(Ref ref) => DateTime.now;

/// The loved one's care circle (TASKS.md Phase 14.25).
///
/// `build()` joins every caregiver to their membership, newest-permission
/// first (owner → editor → viewer) then by display name, so the roster
/// renders deterministically. The mutators ([addMember] / [acceptInvite]
/// / [editRole] / [editPermission] / [removeMember]) write through
/// [careCircleRepositoryProvider] and re-read the join so the screen
/// reflects the change without a manual invalidate. [pendingInvites]
/// filters the already-loaded state synchronously.
@Riverpod(keepAlive: true)
class CareCircle extends _$CareCircle {
  @override
  Future<List<CareCircleMember>> build() async {
    final CareCircleRepository repo = ref.watch(careCircleRepositoryProvider);
    return _load(repo);
  }

  /// Members whose invite hasn't been accepted yet. Empty while the first
  /// load is still in flight.
  List<CareCircleMember> get pendingInvites =>
      (state.asData?.value ?? const <CareCircleMember>[])
          .where((CareCircleMember m) => m.isPending)
          .toList();

  /// Add a caregiver and their membership in one step, then refresh.
  Future<void> addMember({
    required Caregiver caregiver,
    required CareCircleMembership membership,
  }) =>
      _mutate((CareCircleRepository repo) async {
        await repo.upsertCaregiver(caregiver);
        await repo.upsertMembership(membership);
      });

  /// Flip a pending invite's `acceptedAt` to the current time, then
  /// refresh. No-op if the membership is gone or already accepted.
  Future<void> acceptInvite(String membershipId) =>
      _mutate((CareCircleRepository repo) async {
        final CareCircleMembership? existing =
            await repo.getMembership(membershipId);
        if (existing == null || existing.acceptedAt != null) return;
        final DateTime now = ref.read(careCircleClockProvider)();
        await repo.upsertMembership(existing.copyWith(acceptedAt: now));
      });

  /// Change a caregiver's [role], then refresh. No-op if absent.
  Future<void> editRole(String caregiverId, CaregiverRole role) =>
      _mutate((CareCircleRepository repo) async {
        final Caregiver? existing = await repo.getCaregiver(caregiverId);
        if (existing == null) return;
        await repo.upsertCaregiver(existing.copyWith(role: role));
      });

  /// Change a membership's [permissionLevel], then refresh. No-op if
  /// absent.
  Future<void> editPermission(String membershipId, PermissionLevel level) =>
      _mutate((CareCircleRepository repo) async {
        final CareCircleMembership? existing =
            await repo.getMembership(membershipId);
        if (existing == null) return;
        await repo.upsertMembership(
          existing.copyWith(permissionLevel: level),
        );
      });

  /// Remove a caregiver from the circle, cascading to their membership,
  /// then refresh.
  Future<void> removeMember(String caregiverId) =>
      _mutate((CareCircleRepository repo) => repo.deleteCaregiver(caregiverId));

  Future<List<CareCircleMember>> _load(CareCircleRepository repo) async {
    final List<Caregiver> caregivers = await repo.listCaregivers();
    final List<CareCircleMembership> memberships = await repo.listMemberships();
    final Map<String, Caregiver> byId = <String, Caregiver>{
      for (final Caregiver c in caregivers) c.id: c,
    };

    final List<CareCircleMember> members = <CareCircleMember>[];
    for (final CareCircleMembership m in memberships) {
      final Caregiver? caregiver = byId[m.caregiverId];
      if (caregiver != null) {
        members.add(CareCircleMember(caregiver: caregiver, membership: m));
      }
    }

    members.sort((CareCircleMember a, CareCircleMember b) {
      final int byPermission = _permissionRank(a.membership.permissionLevel)
          .compareTo(_permissionRank(b.membership.permissionLevel));
      if (byPermission != 0) return byPermission;
      return a.caregiver.displayName
          .toLowerCase()
          .compareTo(b.caregiver.displayName.toLowerCase());
    });
    return members;
  }

  Future<void> _mutate(
    Future<void> Function(CareCircleRepository repo) op,
  ) async {
    final CareCircleRepository repo = ref.read(careCircleRepositoryProvider);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return _load(repo);
    });
  }
}

/// Sort rank for [PermissionLevel] so owners surface above editors above
/// viewers on the roster.
int _permissionRank(PermissionLevel level) {
  switch (level) {
    case PermissionLevel.owner:
      return 0;
    case PermissionLevel.editor:
      return 1;
    case PermissionLevel.viewer:
      return 2;
  }
}
