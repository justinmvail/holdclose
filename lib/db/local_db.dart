/// Opens the local drift/SQLite file. Plain, unencrypted, boring — on purpose.
///
/// ## Why there is no app-level encryption here (2026-07-13)
///
/// The database used to be SQLCipher-encrypted with a random key in the OS
/// keychain. In ONE DAY that machinery caused three data-loss events on the
/// only device carrying it, and prevented zero attacks:
///
///   1. a first-run race let several opens each mint their own key, so the file
///      ended up encrypted under a key nobody kept;
///   2. an iOS keychain accessibility "hardening" made the existing key
///      unreadable (`flutter_secure_storage` >=9.1 puts `kSecAttrAccessible` in
///      the READ query; Apple only honours it on the first write), so the key
///      vanished and the caregiver's care record was quarantined;
///   3. the quarantine step deleted the previous quarantine, so one more false
///      alarm would have destroyed the only surviving copy.
///
/// And the decrypt that unwound it bricked the app a fourth way: `sqlcipher_export`
/// copies schema and data but NOT `user_version`, so drift saw version 0, ran
/// `onCreate` over a populated schema, and died on `CREATE INDEX ... already
/// exists` — on every launch, forever, with every write failing.
///
/// What it bought was narrow. BOTH platforms already encrypt app files at rest
/// (iOS Data Protection; Android file-based encryption, mandatory since Android
/// 10 — our floor is API 26), and the file is excluded from backups. SQLCipher
/// only added cover for a rooted/jailbroken device while UNLOCKED. That is not
/// worth four ways to destroy a caregiver's medication list.
///
/// **If anyone ever wants encryption back:** use drift's supported stack
/// (SQLite3MultipleCiphers on `sqlite3` 3.x — NOT the obsolete
/// `sqlcipher_flutter_libs`), keep the key lifecycle boring, never change
/// keychain options after release, and carry `user_version` across any
/// export/copy. See docs/DB_FRAGILITY.md before touching any of it.
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Filename of the on-device database.
const String databaseFileName = 'holdclose.sqlite';

/// The keychain entry the REMOVED SQLCipher key used to live under. Kept only
/// so we can delete it — a dead secret should not linger on a caregiver's
/// device. Never written.
const String kLegacyDatabaseKeyStorageKey = 'holdclose.db.sqlcipher_key.v1';

const AndroidOptions _androidOptions =
    AndroidOptions(encryptedSharedPreferences: true);

/// Suffix for a database we cannot read. Quarantines are ADDITIVE — see
/// [quarantineUnreadable].
const String quarantineSuffix = '.quarantined';

bool get _runningUnderFlutterTest {
  try {
    return const bool.fromEnvironment('FLUTTER_TEST') ||
        Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}

/// The executor for the real on-device database.
///
/// Lazily connected so `HoldcloseDatabase.open()` stays a synchronous factory.
QueryExecutor localFileExecutor({
  FlutterSecureStorage? secureStorage,
  int expectedSchemaVersion = 20,
}) {
  return DatabaseConnection.delayed(Future<DatabaseConnection>(() async {
    // A few widget/routing tests mount the real router without overriding
    // storageProvider and so reach open(). Under the test binding there is no
    // path_provider, so this future never completes — the same behaviour the
    // old `driftDatabase(name:)` path had, leaving no pending timers. Those
    // tests never query the store.
    if (_runningUnderFlutterTest) {
      return Completer<DatabaseConnection>().future;
    }

    final Directory dir = await getApplicationDocumentsDirectory();
    final String dbPath = p.join(dir.path, databaseFileName);

    // Repairs, in the order that keeps data safest. Each is a no-op on a
    // healthy install (the overwhelmingly common case).
    restoreQuarantinedIfReadable(dbPath);
    stampSchemaVersionIfMissing(dbPath, expectedSchemaVersion);
    quarantineUnreadable(dbPath);

    // The SQLCipher key can no longer decrypt anything. Don't leave a dead
    // secret on the device.
    unawaited(forgetLegacyEncryptionKey(secureStorage));

    return NativeDatabase.createBackgroundConnection(File(dbPath));
  }));
}

/// Repair the exact brick that stranded a tester for a whole afternoon.
///
/// `sqlcipher_export` — and `VACUUM INTO`, and several other ways of copying a
/// SQLite file — carry the schema and the rows but NOT `user_version`. Drift
/// keys its entire migration decision off that number: a database with every
/// table present but `user_version = 0` is treated as BRAND NEW, so `onCreate`
/// runs `createAll()` over a populated schema. `CREATE TABLE IF NOT EXISTS`
/// survives that; a bare `CREATE INDEX` does not:
///
///   SqliteException(1): index journal_entries_created_idx already exists
///
/// From then on EVERY write throws, on every launch, forever — and reinstalling
/// the app doesn't help, because the file outlives it. The caregiver is
/// stranded on onboarding with "Couldn't save just now" and no way out.
///
/// So: if the file already carries OUR schema but has no version stamp, stamp
/// it. Deliberately narrow — it only fires when `user_version == 0` AND the
/// tables are actually there, which cannot be true of a genuinely new database.
void stampSchemaVersionIfMissing(String dbPath, int expectedSchemaVersion) {
  if (!File(dbPath).existsSync()) return;

  Database? db;
  try {
    db = sqlite3.open(dbPath);
    final int version =
        db.select('PRAGMA user_version;').first.values.first as int? ?? 0;
    if (version != 0) return; // stamped already — nothing to do

    // Is our schema actually there? `patients` is created in v1 and has existed
    // ever since, so it is the safest witness.
    final ResultSet tables = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'patients';",
    );
    if (tables.isEmpty) return; // a genuinely fresh file — let drift create it

    db.execute('PRAGMA user_version = $expectedSchemaVersion;');
    _report(
      'repaired a database that had our schema but no version stamp '
      '(user_version 0 → $expectedSchemaVersion) — without this, drift treats '
      'it as new and every write fails on "index already exists"',
    );
  } catch (e) {
    // Never let a repair attempt wedge the launch.
    debugPrint('db: version-stamp repair skipped: $e');
  } finally {
    db?.dispose();
  }
}

/// Give back a database an earlier build quarantined, when we can read it.
///
/// Quarantine is non-destructive precisely so a WRONG one is reversible — and
/// wrong ones happened. Guarded: never clobber a live database, and only
/// restore a file we can actually open.
void restoreQuarantinedIfReadable(String dbPath) {
  final File live = File(dbPath);
  final File quarantined = File('$dbPath$quarantineSuffix');
  if (live.existsSync() || !quarantined.existsSync()) return;
  if (!isReadableDatabase(quarantined.path)) return;

  for (final String suffix in const <String>['', '-wal', '-shm']) {
    final File src = File('$dbPath$quarantineSuffix$suffix');
    if (src.existsSync()) src.renameSync('$dbPath$suffix');
  }
  _report('restored a quarantined database we can read (care data recovered)');
}

/// Move an unreadable database aside so the app starts instead of failing every
/// query forever.
///
/// NEVER deletes, and NEVER overwrites an earlier quarantine: the first takes
/// the plain `.quarantined` name, later ones get timestamped siblings. A file we
/// cannot read might still be someone's only copy — including a SQLCipher file
/// left by a build that predates the encryption removal, which is exactly what
/// lands here now that the decryption code is gone.
void quarantineUnreadable(String dbPath) {
  if (!File(dbPath).existsSync()) return;
  if (isReadableDatabase(dbPath)) return;

  final String stamp =
      DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  final String plain = '$dbPath$quarantineSuffix';
  final String base =
      File(plain).existsSync() ? '$plain.$stamp' : plain;

  for (final String suffix in const <String>['', '-wal', '-shm']) {
    final File src = File('$dbPath$suffix');
    if (src.existsSync()) src.renameSync('$base$suffix');
  }
  _report(
    'quarantined a database we cannot read ($base) — a fresh one will be '
    'created; the file is kept, never deleted',
  );
}

/// True iff the file is a readable, unencrypted SQLite database.
bool isReadableDatabase(String dbPath) {
  Database? probe;
  try {
    probe = sqlite3.open(dbPath);
    probe.select('SELECT count(*) FROM sqlite_master;');
    return true;
  } catch (_) {
    return false;
  } finally {
    probe?.dispose();
  }
}

/// Delete the dead SQLCipher key. Best-effort; it decrypts nothing now.
Future<void> forgetLegacyEncryptionKey(FlutterSecureStorage? injected) async {
  final FlutterSecureStorage storage =
      injected ?? const FlutterSecureStorage(aOptions: _androidOptions);
  try {
    await storage.delete(
      key: kLegacyDatabaseKeyStorageKey,
      aOptions: _androidOptions,
    );
  } catch (e) {
    debugPrint('db: could not delete the legacy encryption key (harmless): $e');
  }
}

/// Something this module did to the database FILE (a repair, a quarantine, a
/// restore). Handed to [databaseRecoveryObserver]; never thrown. Carries only
/// file/reason words — never care data.
class DatabaseRecoveryException implements Exception {
  DatabaseRecoveryException(this.message);

  final String message;

  @override
  String toString() => 'DatabaseRecoveryException: $message';
}

/// Observer for the above. `main.dart` wires it to the on-device crash log and
/// the opt-in aggregator BEFORE the first DB touch. With none wired, the
/// breadcrumb still reaches LogBuffer via [debugPrint].
void Function(Object error, StackTrace stackTrace)? databaseRecoveryObserver;

void _report(String message) {
  debugPrint('db-recovery: $message');
  final void Function(Object, StackTrace)? observer = databaseRecoveryObserver;
  if (observer != null) {
    try {
      observer(DatabaseRecoveryException(message), StackTrace.current);
    } catch (_) {
      // Reporting must never break the thing it reports on.
    }
  }
}
