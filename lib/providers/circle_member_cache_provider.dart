import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/forum.dart';

part 'circle_member_cache_provider.g.dart';

/// Local read-cache of the backend care-circle roster (the `@username`-based
/// people served by the forum API's `GET /circles`). Mirrors that REST
/// resource into [CircleMemberCacheTable] so the Care Circle "People" screen
/// reads it LOCALLY — instant + offline (local-first). A background refresh
/// (see `SyncController.refreshCircleRoster`) replaces the active circle's
/// rows when the device is online.
///
/// Not a [SyncSinkHost]: this cache is a one-way mirror of a server resource,
/// never pushed back through the server-authoritative sync queue.
class CircleMemberCacheRepository {
  CircleMemberCacheRepository(this._db);

  final CareblazersDatabase _db;

  /// Replace the cached roster for [circleId] with [members]. Done as one
  /// transaction so the screen never sees a half-written roster. Deleting the
  /// whole table first keeps it consistent when the active circle changes —
  /// the app tracks a single active circle at a time.
  Future<void> replaceForCircle(
    String circleId,
    List<CircleMemberDto> members, {
    DateTime Function()? clock,
  }) async {
    final int now = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    await _db.transaction(() async {
      await _db.delete(_db.circleMemberCacheTable).go();
      for (final CircleMemberDto m in members) {
        await _db.into(_db.circleMemberCacheTable).insertOnConflictUpdate(
              CircleMemberCacheTableCompanion.insert(
                profileId: m.profileId,
                circleId: circleId,
                payload: jsonEncode(m.toJson()),
                cachedAtMs: now,
              ),
            );
      }
    });
  }

  /// The cached roster, decoded. Empty before the first successful refresh.
  Future<List<CircleMemberDto>> list() async {
    final List<CircleMemberCacheTableData> rows =
        await _db.select(_db.circleMemberCacheTable).get();
    return rows.map(_decode).toList();
  }

  /// Reactive view for the Care Circle screen — re-emits whenever a refresh
  /// rewrites the cache, so a freshly-pulled roster lands without a manual
  /// reload.
  Stream<List<CircleMemberDto>> watch() {
    return _db.select(_db.circleMemberCacheTable).watch().map(
          (List<CircleMemberCacheTableData> rows) =>
              rows.map(_decode).toList(),
        );
  }

  CircleMemberDto _decode(CircleMemberCacheTableData row) =>
      CircleMemberDto.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
}

/// Riverpod-wired singleton over the shared database connection — mirrors the
/// `*RepositoryBackend` pattern the other repositories use.
@Riverpod(keepAlive: true)
CircleMemberCacheRepository circleMemberCacheRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  return CircleMemberCacheRepository(db);
}

/// Alias matching the `*RepositoryProvider` convention consumers reach for.
final CircleMemberCacheRepositoryBackendProvider
    circleMemberCacheRepositoryProvider =
    circleMemberCacheRepositoryBackendProvider;
