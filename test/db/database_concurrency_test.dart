import 'dart:io';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/chat.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/sync_service.dart' show SyncOutbox;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the alpha "database is locked" (`SQLITE_BUSY`) bug
/// (2026-06-08).
///
/// In production each repository AND the sync engine opened a SEPARATE
/// `HoldcloseDatabase` connection to the SAME on-disk file. Once
/// sync-everything wired feature writes (chat, loved-one setup, …) to fire
/// alongside the sync engine, a write on one connection racing a write on
/// another threw `SqliteException(5): database is locked` — surfacing as
/// "Couldn't reach the coach" and a setup form stuck on "Saving…".
///
/// Every OTHER db test uses `NativeDatabase.memory()`, which can't surface
/// this — single connection, never on disk. The first cut of THIS test
/// proved the point the hard way: two real connections to one file STILL
/// throw "database is locked" even with WAL + busy_timeout (they fight for
/// ~2 min then fail). So WAL alone is not the fix — the fix is using ONE
/// connection. These tests guard exactly that:
///   1. [HoldcloseDatabase.open] returns a process-wide SINGLETON, so the
///      whole app shares one connection (drift serialises its writes).
///   2. that single connection takes concurrent writes from a feature repo
///      AND the sync engine without locking — the user-visible behaviour.
///   3. closing it from one provider's dispose is a no-op (it must outlive
///      any single consumer).
void main() {
  group('shared single DB connection (the real lock fix)', () {
    tearDown(HoldcloseDatabase.resetSharedForTest);

    test('open() returns the SAME instance every call (one connection)', () {
      final Directory tmp = Directory.systemTemp.createTempSync('cb_singleton');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Two opens with DIFFERENT executors: the second executor is ignored
      // and the first shared instance is returned — proving there is exactly
      // one connection no matter how many providers call open().
      final HoldcloseDatabase a = HoldcloseDatabase.openShared(
          NativeDatabase(File('${tmp.path}/a.sqlite')));
      final HoldcloseDatabase b = HoldcloseDatabase.openShared(
          NativeDatabase(File('${tmp.path}/b.sqlite')));

      expect(identical(a, b), isTrue,
          reason: 'open() must memoise a single connection');
    });

    test('a provider disposing it is a no-op — the shared connection lives on',
        () async {
      final Directory tmp = Directory.systemTemp.createTempSync('cb_noopclose');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final HoldcloseDatabase db = HoldcloseDatabase.openShared(
          NativeDatabase(File('${tmp.path}/c.sqlite')));

      // Simulate one keepAlive provider's `ref.onDispose(db.close)` firing.
      await db.close();

      // The connection everyone else shares must still work.
      final QueryRow row =
          await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), db.schemaVersion);
    });

    test('one connection serialises racing chat + sync writes — no lock',
        () async {
      final Directory tmp = Directory.systemTemp.createTempSync('cb_serialise');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // The production shape AFTER the fix: a feature repo and the sync
      // engine share ONE connection. drift serialises the writes, so the
      // exact race that used to throw "database is locked" now just works.
      final HoldcloseDatabase db = HoldcloseDatabase.openShared(
          NativeDatabase(File('${tmp.path}/d.sqlite')));
      final ChatRepository chat = ChatRepository(db);
      final SyncOutbox outbox = SyncOutbox(db);
      final DateTime now = DateTime(2026, 6, 8, 12);

      await chat.createConversation(id: 'c1', title: 'race', createdAt: now);

      await expectLater(
        Future.wait<void>(<Future<void>>[
          for (int i = 0; i < 25; i++)
            chat.appendMessage(Message(
              id: 'm-$i',
              conversationId: 'c1',
              role: MessageRole.user,
              body: 'message $i',
              citations: const <String>[],
              createdAt: now,
              streamingDone: true,
            )),
          for (int i = 0; i < 25; i++)
            outbox.enqueue(
              collection: 'patient',
              docId: 'd-$i',
              payload: <String, dynamic>{'n': i},
              clientUpdatedAt: i,
              deleted: false,
            ),
        ]),
        completes,
      );

      // Both write streams actually landed — no silent loss.
      expect(await chat.loadMessages('c1'), hasLength(25));
      expect(await outbox.listPending(limit: 100), hasLength(25));
    });
  });
}
