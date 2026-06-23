import 'package:holdclose/models/forum.dart';
import 'package:holdclose/services/fake_forum_api_client.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contract pin for [FakeForumApiClient]'s sync engine.
///
/// All Dart-side sync confidence (sync_service_test.dart's 21-collection
/// LWW/tombstone round-trips) rests on the fake faithfully mimicking the
/// Cloudflare Worker. This test encodes the SAME observable contract the
/// Worker's own suite pins (backend/test/sync.test.ts) — LWW by
/// `client_updated_at` with `>=` ties, monotonic per-circle revs, delta
/// `since` semantics, tombstone propagation, and shared-backend
/// visibility — so the fake can't silently drift from the protocol it
/// stands in for. When the Worker contract changes, BOTH suites should
/// move together; a mismatch here is the early warning.
void main() {
  SyncDocWrite doc(String id, int updatedAt, {bool deleted = false}) =>
      SyncDocWrite(
        id: id,
        collection: 'journal_entries',
        payload: <String, dynamic>{'id': id},
        clientUpdatedAt: updatedAt,
        deleted: deleted,
      );

  group('FakeForumApiClient sync ⟷ Worker contract', () {
    test('a pushed doc comes back on pull with rev > 0', () async {
      final FakeForumApiClient client = FakeForumApiClient();
      final CircleDto circle = await client.createCircle('Mary');

      await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 1000)]);
      final SyncPullResult pulled = await client.syncPull(circle.id, since: 0);

      expect(pulled.docs, hasLength(1));
      expect(pulled.docs.single.id, 'd1');
      expect(pulled.docs.single.rev, greaterThan(0));
    });

    test('LWW: a stale (older client_updated_at) write is rejected; a newer '
        'one is accepted', () async {
      final FakeForumApiClient client = FakeForumApiClient();
      final CircleDto circle = await client.createCircle('Mary');

      await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 5000)]);
      final SyncPushResult stale =
          await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 4000)]);
      expect(stale.applied.single.accepted, isFalse,
          reason: 'older timestamp loses LWW');

      final SyncPushResult newer =
          await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 6000)]);
      expect(newer.applied.single.accepted, isTrue,
          reason: 'newer timestamp wins LWW');
    });

    test('LWW: an equal client_updated_at is accepted (>= tie rule)',
        () async {
      final FakeForumApiClient client = FakeForumApiClient();
      final CircleDto circle = await client.createCircle('Mary');

      await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 5000)]);
      final SyncPushResult equalTs =
          await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 5000)]);
      expect(equalTs.applied.single.accepted, isTrue);
    });

    test('revs are monotonic across pushes (delta cursor is skew-proof)',
        () async {
      final FakeForumApiClient client = FakeForumApiClient();
      final CircleDto circle = await client.createCircle('Mary');

      final SyncPushResult first =
          await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 1000)]);
      final SyncPushResult second =
          await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d2', 1000)]);
      expect(second.cursor, greaterThan(first.cursor));
    });

    test('delta pull returns only docs newer than the cursor', () async {
      final FakeForumApiClient client = FakeForumApiClient();
      final CircleDto circle = await client.createCircle('Mary');

      await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 1000)]);
      final SyncPullResult firstPull =
          await client.syncPull(circle.id, since: 0);
      final int cursor = firstPull.cursor;

      // Nothing new since the cursor.
      final SyncPullResult emptyDelta =
          await client.syncPull(circle.id, since: cursor);
      expect(emptyDelta.docs, isEmpty);

      // A new push shows up in the next delta.
      await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d2', 2000)]);
      final SyncPullResult delta =
          await client.syncPull(circle.id, since: cursor);
      expect(delta.docs.map((SyncDoc d) => d.id), <String>['d2']);
    });

    test('a tombstone (deleted:true) propagates on pull', () async {
      final FakeForumApiClient client = FakeForumApiClient();
      final CircleDto circle = await client.createCircle('Mary');

      await client.syncPush(circle.id, docs: <SyncDocWrite>[doc('d1', 1000)]);
      await client.syncPush(circle.id,
          docs: <SyncDocWrite>[doc('d1', 2000, deleted: true)]);

      final SyncPullResult pulled = await client.syncPull(circle.id, since: 0);
      final SyncDoc d1 =
          pulled.docs.firstWhere((SyncDoc d) => d.id == 'd1');
      expect(d1.deleted, isTrue);
    });

    test('two clients on ONE shared backend see each other\'s pushes',
        () async {
      final FakeForumBackend shared = FakeForumBackend();
      final FakeForumApiClient a = FakeForumApiClient(backend: shared);
      final FakeForumApiClient b = FakeForumApiClient(backend: shared);
      final CircleDto circle = await a.createCircle('Mary');

      await a.syncPush(circle.id, docs: <SyncDocWrite>[doc('from-a', 1000)]);
      final SyncPullResult bPull = await b.syncPull(circle.id, since: 0);
      expect(bPull.docs.map((SyncDoc d) => d.id), contains('from-a'));
    });

    test('the patient round-trips via the dedicated patient field', () async {
      final FakeForumApiClient client = FakeForumApiClient();
      final CircleDto circle = await client.createCircle(
        'Mary',
        patient: const SyncPatientWrite(
          payload: <String, dynamic>{'id': 'p1', 'name': 'Mary'},
          clientUpdatedAt: 1000,
        ),
      );
      final SyncPullResult pulled = await client.syncPull(circle.id, since: 0);
      expect(pulled.patient, isNotNull);
      expect(pulled.patient!.payload, contains('Mary'));
      expect(pulled.patient!.rev, greaterThan(0));
    });
  });
}
