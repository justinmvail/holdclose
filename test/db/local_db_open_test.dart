/// The local database open path, AFTER app-level encryption was dropped
/// (2026-07-13).
///
/// SQLCipher caused three data-loss events in one day and prevented none (see
/// the library doc on `lib/db/encrypted_open.dart`). What remains must uphold
/// two promises, and these tests keep them honest:
///
///   1. **An install that HAS an encrypted database keeps its data.** It is
///      decrypted to plaintext exactly once, and the encrypted original is kept
///      as a backup — never deleted.
///   2. **Nothing ever destroys care data.** A file we cannot read is moved
///      aside — never removed, never overwriting an earlier quarantine — and a
///      quarantine we can prove was a mistake is given back.
///
/// These run against the HOST sqlite3, which has no SQLCipher. That is faithful
/// for everything below EXCEPT a genuinely encrypted file: `PRAGMA key` is an
/// unknown pragma the plain library ignores, so "the key opens it" is modelled
/// by a readable file, and "we cannot read it" by bytes that are not a sqlite
/// database — exactly what a SQLCipher file looks like without its key. The
/// real decrypt is exercised ON DEVICE; that is the one thing a host test
/// cannot do, and the reason the migration build is dogfooded before the
/// SQLCipher libs are pulled.
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/db/encrypted_open.dart';
import 'package:sqlite3/sqlite3.dart';

/// In-memory [FlutterSecureStorage] stand-in.
class _FakeSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> values = <String, String>{};
  int deletes = 0;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];

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
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes++;
    values.remove(key);
  }
}

/// Bytes that are not a sqlite database — how a SQLCipher file looks to a
/// library that cannot decrypt it.
List<int> _unreadableBytes() =>
    List<int>.generate(4096, (int i) => (i * 37 + 11) % 256);

/// A real, readable sqlite database carrying one row.
void _writeDatabase(String path, {String value = 'keep me'}) {
  final Database db = sqlite3.open(path);
  db
    ..execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)')
    ..execute("INSERT INTO t (v) VALUES ('$value')");
  db.dispose();
}

String _readValue(String path) {
  final Database db = sqlite3.open(path);
  try {
    return db.select('SELECT v FROM t').single['v'] as String;
  } finally {
    db.dispose();
  }
}

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hc_db_open');
    dbPath = '${tmp.path}/holdclose.sqlite';
  });

  tearDown(() {
    databaseRecoveryObserver = null;
    tmp.deleteSync(recursive: true);
  });

  group('the legacy decrypt migration (SQLCipher → plaintext)', () {
    test('an install with NO key is left completely alone', () async {
      _writeDatabase(dbPath);
      final _FakeSecureStorage storage = _FakeSecureStorage();

      await decryptLegacyDatabaseIfNeeded(dbPath, null, storage);

      expect(_readValue(dbPath), 'keep me');
      expect(File('$dbPath.quarantined').existsSync(), isFalse);
    });

    test('an ALREADY-plaintext database is untouched, and the dead key is '
        'forgotten', () async {
      // Every launch after the migration has run once.
      _writeDatabase(dbPath);
      final _FakeSecureStorage storage = _FakeSecureStorage();
      storage.values[kDatabaseKeyStorageKey] = 'legacy-key';

      await decryptLegacyDatabaseIfNeeded(dbPath, 'legacy-key', storage);

      expect(_readValue(dbPath), 'keep me', reason: 'no needless rewrite');
      expect(storage.values.containsKey(kDatabaseKeyStorageKey), isFalse,
          reason: 'the key decrypts nothing now — drop it');
      expect(storage.deletes, 1);
    });

    test('a database the key CANNOT open is NOT touched (left for quarantine)',
        () async {
      // Someone else's ciphertext, or corruption. The one thing we must never
      // do is destroy it.
      File(dbPath).writeAsBytesSync(_unreadableBytes());
      final _FakeSecureStorage storage = _FakeSecureStorage();

      await decryptLegacyDatabaseIfNeeded(dbPath, 'wrong-key', storage);

      expect(File(dbPath).existsSync(), isTrue,
          reason: 'never delete a file we merely cannot read');
      expect(File(dbPath).readAsBytesSync(), _unreadableBytes());
    });

    test('no database + a stale key → the key is dropped, nothing is created',
        () async {
      final _FakeSecureStorage storage = _FakeSecureStorage();
      storage.values[kDatabaseKeyStorageKey] = 'legacy-key';

      await decryptLegacyDatabaseIfNeeded(dbPath, 'legacy-key', storage);

      expect(File(dbPath).existsSync(), isFalse);
      expect(storage.values.containsKey(kDatabaseKeyStorageKey), isFalse);
    });
  });

  group('quarantine — may MOVE care data, may NEVER delete it', () {
    test('an unreadable database is moved aside, not removed', () {
      File(dbPath).writeAsBytesSync(_unreadableBytes());

      quarantineIfUnreadable(dbPath);

      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath.quarantined').readAsBytesSync(), _unreadableBytes(),
          reason: 'the bytes must survive, byte for byte');
    });

    test('a healthy database is never quarantined', () {
      _writeDatabase(dbPath);

      quarantineIfUnreadable(dbPath);

      expect(_readValue(dbPath), 'keep me');
      expect(File('$dbPath.quarantined').existsSync(), isFalse);
    });

    test('a SECOND quarantine never destroys the FIRST', () {
      // The hazard, pinned: the first cut deleted the previous quarantine
      // before moving the new file in. Two false quarantines happened in one
      // day — a third would have destroyed the only surviving copy of the
      // caregiver's care record.
      File(dbPath).writeAsStringSync('FIRST GENERATION - the real care data');
      quarantineIfUnreadable(dbPath);
      File(dbPath).writeAsStringSync('SECOND GENERATION');

      quarantineIfUnreadable(dbPath);

      expect(
        File('$dbPath.quarantined').readAsStringSync(),
        'FIRST GENERATION - the real care data',
      );
      final int quarantines = tmp
          .listSync()
          .where((FileSystemEntity e) => e.path.contains('.quarantined'))
          .length;
      expect(quarantines, 2, reason: 'generations accumulate; none are lost');
    });

    test('each quarantine is reported through databaseRecoveryObserver', () {
      final List<Object> reported = <Object>[];
      databaseRecoveryObserver = (Object e, StackTrace _) => reported.add(e);
      File(dbPath).writeAsBytesSync(_unreadableBytes());

      quarantineIfUnreadable(dbPath);

      expect(reported.single, isA<DatabaseRecoveryException>());
    });
  });

  group('restoring a quarantine that was a mistake', () {
    test('a readable quarantined database is given back', () {
      _writeDatabase('$dbPath.quarantined');
      File('$dbPath.quarantined-wal').writeAsStringSync('wal');

      restoreQuarantinedIfUsable(dbPath, null);

      expect(_readValue(dbPath), 'keep me',
          reason: 'the care record must come back');
      expect(File('$dbPath-wal').existsSync(), isTrue,
          reason: 'sidecars travel with the database');
      expect(File('$dbPath.quarantined').existsSync(), isFalse);
    });

    test('a LIVE database is never clobbered by a restore', () {
      _writeDatabase(dbPath, value: 'live');
      _writeDatabase('$dbPath.quarantined', value: 'older');

      restoreQuarantinedIfUsable(dbPath, null);

      expect(_readValue(dbPath), 'live', reason: 'newer data outranks older');
      expect(File('$dbPath.quarantined').existsSync(), isTrue);
    });

    test('a quarantine we cannot read is left where it is', () {
      File('$dbPath.quarantined').writeAsBytesSync(_unreadableBytes());

      restoreQuarantinedIfUsable(dbPath, null);

      expect(File(dbPath).existsSync(), isFalse,
          reason: 'restoring an unreadable file would only wedge the app again');
      expect(File('$dbPath.quarantined').existsSync(), isTrue);
    });

    test('no quarantine → no-op', () {
      restoreQuarantinedIfUsable(dbPath, null);
      expect(File(dbPath).existsSync(), isFalse);
    });
  });
}
