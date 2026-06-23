import 'dart:convert';

import 'package:drift/drift.dart'
    show OrderClauseGenerator, OrderingMode, OrderingTerm;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/forum.dart';
import '../services/forum_api_client.dart' show ForumPostSort;

part 'forum_post_cache_provider.g.dart';

/// Local read-cache of the community forum's first page, per sort. Lets the
/// Community feed render the last-seen posts instantly + OFFLINE (local-first)
/// instead of a skeleton / error when there's no signal. The feed still
/// refreshes from the backend in the background when online — this is the
/// cold-start / offline fallback only.
class ForumPostCacheRepository {
  ForumPostCacheRepository(this._db);

  final HoldcloseDatabase _db;

  /// Replace the cached first page for [sort] with [posts] (server order
  /// preserved via the row's rank). One transaction so a reader never sees a
  /// half-written page.
  Future<void> cacheFirstPage(
    ForumPostSort sort,
    List<ForumPost> posts, {
    DateTime Function()? clock,
  }) async {
    final int now = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    await _db.transaction(() async {
      await (_db.delete(_db.forumPostCacheTable)
            ..where((t) => t.sort.equals(sort.name)))
          .go();
      for (int i = 0; i < posts.length; i++) {
        await _db.into(_db.forumPostCacheTable).insertOnConflictUpdate(
              ForumPostCacheTableCompanion.insert(
                id: posts[i].id,
                sort: sort.name,
                rank: i,
                payload: jsonEncode(posts[i].toJson()),
                cachedAtMs: now,
              ),
            );
      }
    });
  }

  /// The cached first page for [sort], in server order. Empty before the first
  /// successful load.
  Future<List<ForumPost>> firstPage(ForumPostSort sort) async {
    final List<ForumPostCacheTableData> rows =
        await (_db.select(_db.forumPostCacheTable)
              ..where((t) => t.sort.equals(sort.name))
              ..orderBy(<OrderClauseGenerator<$ForumPostCacheTableTable>>[
                (t) => OrderingTerm(expression: t.rank, mode: OrderingMode.asc),
              ]))
            .get();
    return rows
        .map((ForumPostCacheTableData r) =>
            ForumPost.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }
}

/// Riverpod-wired singleton over the shared database connection.
@Riverpod(keepAlive: true)
ForumPostCacheRepository forumPostCacheRepositoryBackend(Ref ref) {
  final HoldcloseDatabase db = HoldcloseDatabase.open();
  return ForumPostCacheRepository(db);
}

/// Alias matching the `*RepositoryProvider` convention.
final ForumPostCacheRepositoryBackendProvider forumPostCacheRepositoryProvider =
    forumPostCacheRepositoryBackendProvider;
