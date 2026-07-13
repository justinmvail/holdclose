/// Regression guards for the SQLCipher key lifecycle (2026-07-13 hardening).
///
/// The bug this protects against: `HoldcloseDatabase.open()` used to build a
/// THROWAWAY executor on every call, and each one ran the key read/mint in a
/// fire-and-forget future. On a first run (empty keychain) several mints
/// raced; the DB file was encrypted under one key while the LAST keychain
/// write stored another — every later launch then failed with
/// `SqliteException(26): file is not a database` and the care data was
/// unrecoverable. These tests pin the production invariants that make that
/// class of bug impossible:
///   1. one memoized key mint, ever (`obtainDatabaseKey`);
///   2. never mint while an ENCRYPTED database exists — quarantine it first;
///   3. verify a fresh mint persisted (read-back) before using it;
///   4. an undecryptable DB is quarantined — kept on disk, never deleted —
///      so the app recovers instead of wedging (`recoverIfUndecryptable`).
///
/// These run against the HOST sqlite3 (no SQLCipher), which is faithful for
/// everything under test: `PRAGMA key` is an unknown pragma the plain lib
/// ignores (modelling "the key opens the file"), and a garbage file throws
/// NOTADB exactly like a SQLCipher file does under the wrong key.
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/db/encrypted_open.dart';
import 'package:sqlite3/sqlite3.dart';

/// In-memory [FlutterSecureStorage] stand-in (pattern from
/// forum_jwt_provider_test), instrumented with read/write counters and a
/// drop-writes mode for the read-back-verification test.
class _FakeSecureStorage extends Fake implements FlutterSecureStorage {
  _FakeSecureStorage({this.dropWrites = false});

  final Map<String, String> values = <String, String>{};

  /// When true, [write] silently persists nothing — models a keychain whose
  /// writes fail without throwing.
  final bool dropWrites;

  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    // Yield once so concurrent callers genuinely interleave before any
    // write lands — the shape of the original race.
    await Future<void>.delayed(Duration.zero);
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    if (dropWrites) return;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// A few KiB of high-entropy-looking bytes that are definitely not a valid
/// SQLite header — how an SQLCipher-encrypted file looks to an unkeyed (or
/// wrong-keyed) open.
List<int> _encryptedLookingBytes() =>
    List<int>.generate(4096, (int i) => (i * 37 + 11) % 256);

/// Create a real PLAINTEXT SQLite database at [path] — the pre-encryption
/// upgrader shape.
void _writePlaintextDatabase(String path) {
  final Database db = sqlite3.open(path);
  db
    ..execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)')
    ..execute("INSERT INTO t (v) VALUES ('keep me')");
  db.dispose();
}

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    resetDatabaseKeyCache();
    tmp = Directory.systemTemp.createTempSync('hc_encrypted_open');
    dbPath = '${tmp.path}/holdclose.sqlite';
  });

  tearDown(() {
    resetDatabaseKeyCache();
    databaseRecoveryObserver = null;
    tmp.deleteSync(recursive: true);
  });

  group('obtainDatabaseKey — one mint, ever (the key-race regression)', () {
    test('concurrent first-run callers share ONE mint and ONE write',
        () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();

      final List<String> keys = await Future.wait(<Future<String>>[
        for (int i = 0; i < 8; i++)
          obtainDatabaseKey(dbPath: dbPath, secureStorage: storage),
      ]);

      expect(keys.toSet(), hasLength(1),
          reason: 'every concurrent caller must get the SAME key');
      expect(storage.writes, 1,
          reason: 'racing mints (several writes, last one wins) is exactly '
              'the bug that stranded a DB under an overwritten key');
      expect(storage.values[kDatabaseKeyStorageKey], keys.first,
          reason: 'the persisted key must be the one every caller uses');
    });

    test('an existing key is returned as-is and never overwritten', () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      storage.values[kDatabaseKeyStorageKey] = 'pre-existing-key';

      final String key =
          await obtainDatabaseKey(dbPath: dbPath, secureStorage: storage);

      expect(key, 'pre-existing-key');
      expect(storage.writes, 0);
    });

    test('a fresh mint that does not read back throws — and the memo clears '
        'so a later attempt can succeed', () async {
      // A keychain that silently drops writes: minting must FAIL (never
      // encrypt data under a key that did not persist).
      await expectLater(
        obtainDatabaseKey(
          dbPath: dbPath,
          secureStorage: _FakeSecureStorage(dropWrites: true),
        ),
        throwsStateError,
      );

      // The failed future must not be memoized forever: a retry against a
      // working keychain succeeds.
      final String key = await obtainDatabaseKey(
        dbPath: dbPath,
        secureStorage: _FakeSecureStorage(),
      );
      expect(key, isNotEmpty);
    });
  });

  group('mint gating — never mint over an encrypted database', () {
    test('encrypted DB + missing key → quarantined (kept, not deleted), '
        'then a fresh key is minted', () async {
      File(dbPath).writeAsBytesSync(_encryptedLookingBytes());
      File('$dbPath-wal').writeAsBytesSync(_encryptedLookingBytes());

      final _FakeSecureStorage storage = _FakeSecureStorage();
      final String key =
          await obtainDatabaseKey(dbPath: dbPath, secureStorage: storage);

      expect(key, isNotEmpty);
      expect(File(dbPath).existsSync(), isFalse,
          reason: 'the stranded file must be moved out of the way');
      expect(File('$dbPath.quarantined').existsSync(), isTrue,
          reason: 'quarantined — never deleted — for support/forensics');
      expect(File('$dbPath.quarantined-wal').existsSync(), isTrue,
          reason: 'WAL sidecar must travel with its database');
      expect(File('$dbPath-wal').existsSync(), isFalse);
    });

    test('PLAINTEXT DB + missing key → left in place for the sqlcipher '
        'migration (the normal pre-encryption upgrade)', () async {
      _writePlaintextDatabase(dbPath);

      final _FakeSecureStorage storage = _FakeSecureStorage();
      final String key =
          await obtainDatabaseKey(dbPath: dbPath, secureStorage: storage);

      expect(key, isNotEmpty);
      expect(File(dbPath).existsSync(), isTrue,
          reason: 'a plaintext upgrader keeps their data — migration, '
              'not quarantine');
      expect(File('$dbPath.quarantined').existsSync(), isFalse);
    });
  });

  group('restoreQuarantinedIfUsable — undo a WRONG quarantine', () {
    // Why this exists: a keychain-accessibility change (2026-07-13) made the
    // existing DB key unreadable on iOS, so this module concluded the key was
    // gone and quarantined a tester's ENTIRE CARE RECORD. The key was there all
    // along. Quarantine is non-destructive precisely so that mistake is
    // reversible — this is the reversal.

    test('a quarantined DB our key CAN open is restored', () {
      _writePlaintextDatabase('$dbPath.quarantined');
      File('$dbPath.quarantined-wal').writeAsStringSync('wal');

      restoreQuarantinedIfUsable(dbPath, 'deadbeef');

      expect(File(dbPath).existsSync(), isTrue,
          reason: 'the care record must come back');
      expect(File('$dbPath.quarantined').existsSync(), isFalse);
      expect(File('$dbPath-wal').existsSync(), isTrue,
          reason: 'sidecars travel with the database');
      // The rows survived the round trip.
      final Database db = sqlite3.open(dbPath);
      addTearDown(db.dispose);
      expect(db.select('SELECT v FROM t').single['v'], 'keep me');
    });

    test('a LIVE database is never clobbered by a restore', () {
      // Data written since the quarantine outranks the quarantined copy.
      _writePlaintextDatabase(dbPath);
      _writePlaintextDatabase('$dbPath.quarantined');

      restoreQuarantinedIfUsable(dbPath, 'deadbeef');

      expect(File('$dbPath.quarantined').existsSync(), isTrue,
          reason: 'the quarantined copy must be left alone');
    });

    test('a quarantined DB our key CANNOT open is left where it is', () {
      // Someone else's ciphertext, or a corrupt file — restoring it would just
      // wedge the app again.
      File('$dbPath.quarantined').writeAsBytesSync(_encryptedLookingBytes());

      restoreQuarantinedIfUsable(dbPath, 'deadbeef');

      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath.quarantined').existsSync(), isTrue);
    });

    test('no quarantine → no-op', () {
      restoreQuarantinedIfUsable(dbPath, 'deadbeef');
      expect(File(dbPath).existsSync(), isFalse);
    });
  });

  group('recoverIfUndecryptable — self-heal instead of wedging', () {
    test('a file the key cannot open is quarantined', () {
      File(dbPath).writeAsBytesSync(_encryptedLookingBytes());

      recoverIfUndecryptable(dbPath, 'deadbeef');

      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath.quarantined').existsSync(), isTrue);
    });

    test('a database the key opens is untouched', () {
      // On the host lib `PRAGMA key` is an ignored no-op, so a plaintext DB
      // models the key-opens-the-file arm.
      _writePlaintextDatabase(dbPath);

      recoverIfUndecryptable(dbPath, 'deadbeef');

      expect(File(dbPath).existsSync(), isTrue);
      expect(File('$dbPath.quarantined').existsSync(), isFalse);
    });

    test('no database file → no-op', () {
      recoverIfUndecryptable(dbPath, 'deadbeef');

      expect(File('$dbPath.quarantined').existsSync(), isFalse);
    });

    test('a repeat quarantine replaces the previous generation', () {
      File(dbPath).writeAsBytesSync(_encryptedLookingBytes());
      recoverIfUndecryptable(dbPath, 'deadbeef');
      File(dbPath).writeAsBytesSync(_encryptedLookingBytes());

      recoverIfUndecryptable(dbPath, 'deadbeef');

      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath.quarantined').existsSync(), isTrue);
    });

    test('each quarantine reports through databaseRecoveryObserver', () {
      final List<Object> reported = <Object>[];
      databaseRecoveryObserver =
          (Object error, StackTrace stack) => reported.add(error);
      File(dbPath).writeAsBytesSync(_encryptedLookingBytes());

      recoverIfUndecryptable(dbPath, 'deadbeef');

      expect(reported, hasLength(1));
      expect(reported.single, isA<DatabaseRecoveryException>());
      expect('${reported.single}', contains('quarantined'));
    });
  });
}
