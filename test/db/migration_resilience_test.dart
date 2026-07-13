/// Migration resilience — the tests that would have saved a tester's day.
///
/// On 2026-07-13 an install was bricked PERMANENTLY: every database write threw,
/// the caregiver was stranded on onboarding with "Couldn't save just now", and
/// reinstalling the app did not help because the database file outlives it. The
/// cause was not exotic. It was a migration that assumed it would only ever run
/// once, against a file whose version stamp said otherwise.
///
/// Two facts about drift make this a whole CLASS of bug, not a one-off:
///
///   * drift does NOT run migrations in a transaction, and it writes the new
///     `user_version` only AFTER every step succeeds. So any interruption — a
///     crash, an OOM kill, the user swiping the app away mid-launch — leaves a
///     half-migrated file that re-runs the SAME steps on the next launch.
///   * `CREATE TABLE IF NOT EXISTS` is drift's default, but `CREATE INDEX` and
///     `ALTER TABLE ADD COLUMN` are emitted BARE. Re-running either throws.
///
/// And `user_version` is not carried by `sqlcipher_export`, `VACUUM INTO`, or a
/// plain file copy — so any tool that duplicates the database hands drift a
/// populated schema stamped version 0, which drift reads as "brand new" and
/// tries to `createAll()` over.
///
/// So: **every migration step must be safe to run twice**, and a database
/// carrying our schema with no version stamp must be repaired rather than
/// recreated. These tests assert exactly that, against real files.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/db/local_db.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hc_migration');
    dbPath = '${tmp.path}/holdclose.sqlite';
  });

  tearDown(() {
    databaseRecoveryObserver = null;
    tmp.deleteSync(recursive: true);
  });

  /// Build a real, fully-migrated database file at [dbPath].
  Future<void> materialiseSchema() async {
    final HoldcloseDatabase db =
        HoldcloseDatabase(NativeDatabase(File(dbPath)));
    await db.customSelect('SELECT 1').get(); // forces open + migrations
    await db.close();
  }

  int versionOf(String path) {
    final raw.Database db = raw.sqlite3.open(path);
    try {
      return db.select('PRAGMA user_version;').first.values.first as int? ?? 0;
    } finally {
      db.dispose();
    }
  }

  group('every migration step must survive being run TWICE', () {
    test('re-running the FULL upgrade path over an already-migrated database '
        'does not throw', () async {
      // The interrupted-migration scenario: the steps ran, the version stamp
      // never landed, and the next launch runs them all again.
      await materialiseSchema();

      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase(File(dbPath)));
      addTearDown(db.close);
      final Migrator m = Migrator(db);

      // v1 → v20 over a database that ALREADY has every table, index and
      // column. Before the fixes this died on:
      //   "index journal_entries_created_idx already exists" (bare CREATE INDEX)
      //   "duplicate column name: attachment_key"           (bare ADD COLUMN)
      await expectLater(
        db.migration.onUpgrade(m, 1, 20),
        completes,
        reason: 'an interrupted migration re-runs from the SAME version — '
            'every step must tolerate work that is already done',
      );
    });

    test('re-running ONLY the v17 column backfill does not throw', () async {
      await materialiseSchema();
      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase(File(dbPath)));
      addTearDown(db.close);

      await expectLater(
        db.migration.onUpgrade(Migrator(db), 16, 17),
        completes,
        reason: 'ALTER TABLE ADD COLUMN is not idempotent on its own',
      );
    });

    test('re-running ONLY the v20 index backfill does not throw', () async {
      await materialiseSchema();
      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase(File(dbPath)));
      addTearDown(db.close);

      await expectLater(
        db.migration.onUpgrade(Migrator(db), 19, 20),
        completes,
        reason: 'CREATE INDEX is not idempotent on its own',
      );
    });
  });

  group('a schema with NO version stamp is repaired, not recreated', () {
    test('user_version 0 + our tables present → stamped, and the app opens',
        () async {
      // EXACTLY what bricked the tester's phone. `sqlcipher_export` (and
      // VACUUM INTO, and a plain file copy) carry schema + rows but NOT
      // user_version. Drift then reads 0, calls the database new, and runs
      // createAll() over a populated schema — dying on CREATE INDEX.
      await materialiseSchema();
      final raw.Database wipe = raw.sqlite3.open(dbPath);
      wipe.execute('PRAGMA user_version = 0;');
      wipe.dispose();
      expect(versionOf(dbPath), 0);

      stampSchemaVersionIfMissing(dbPath, 20);

      expect(versionOf(dbPath), 20, reason: 'the stamp must be restored');

      // ...and drift now opens it without trying to create anything.
      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase(File(dbPath)));
      addTearDown(db.close);
      await expectLater(db.customSelect('SELECT 1').get(), completes);
    });

    test('a genuinely EMPTY file is left alone for drift to create', () {
      // The repair must not stamp a version onto a database that has no schema
      // — that would tell drift "already migrated" and leave it with no tables.
      final raw.Database fresh = raw.sqlite3.open(dbPath);
      fresh.dispose();

      stampSchemaVersionIfMissing(dbPath, 20);

      expect(versionOf(dbPath), 0,
          reason: 'no schema → no stamp → drift creates the tables normally');
    });

    test('an already-stamped database is not touched', () async {
      await materialiseSchema();
      expect(versionOf(dbPath), 20);

      stampSchemaVersionIfMissing(dbPath, 999); // must be ignored

      expect(versionOf(dbPath), 20);
    });
  });

  group('an unreadable database never wedges the app, and is never deleted',
      () {
    test('a file we cannot read is moved aside and a fresh one is created',
        () async {
      // e.g. a SQLCipher file left by a build that predates the encryption
      // removal, or genuine corruption.
      File(dbPath).writeAsBytesSync(
        List<int>.generate(4096, (int i) => (i * 31 + 7) % 256),
      );

      quarantineUnreadable(dbPath);

      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath.quarantined').existsSync(), isTrue,
          reason: 'kept — a file we cannot read may still be their only copy');

      // The app comes up on a fresh database rather than failing forever.
      final HoldcloseDatabase db =
          HoldcloseDatabase(NativeDatabase(File(dbPath)));
      addTearDown(db.close);
      await expectLater(db.customSelect('SELECT 1').get(), completes);
    });

    test('a healthy database is never quarantined', () async {
      await materialiseSchema();

      quarantineUnreadable(dbPath);

      expect(File(dbPath).existsSync(), isTrue);
      expect(File('$dbPath.quarantined').existsSync(), isFalse);
    });
  });
}
