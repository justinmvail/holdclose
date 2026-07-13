/// Opens the local drift/SQLite file — and, for installs that have one,
/// DECRYPTS a legacy SQLCipher database back to plaintext on the way.
///
/// ## Why we stopped encrypting the local database (decided 2026-07-13)
///
/// The app used to encrypt this file with SQLCipher, with a random passphrase
/// in the OS keychain. In one day that machinery caused THREE data-loss events
/// on the single device carrying it, and zero attacks:
///
///   1. a first-run race where several opens each minted their own key, so the
///      file ended up encrypted under a key nobody kept ("file is not a
///      database", on every launch, forever);
///   2. an iOS keychain "hardening" (an accessibility class) that made the
///      existing key unreadable — `flutter_secure_storage` ≥9.1 puts
///      `kSecAttrAccessible` in the READ query, and Apple only honours it on
///      the first write, so the key vanished, the DB looked unopenable, the
///      caregiver's whole care record was quarantined, and every save failed;
///   3. a quarantine step that DELETED the previous quarantine — one more false
///      alarm would have destroyed the only surviving copy of that record.
///
/// What it bought, meanwhile, is narrow: **both platforms already encrypt this
/// file at rest.** iOS Data Protection covers app files, and Android has
/// mandated file-based encryption since Android 10 (with FDE below that; our
/// floor is API 26). App data also sits in credential-encrypted storage, so it
/// isn't readable before the first unlock after boot. On top of that the file
/// is excluded from iCloud/iTunes backup and `allowBackup="false"` is set. What
/// SQLCipher added on top was protection against a JAILBROKEN/ROOTED device
/// while unlocked, or a raw copy lifted from a running phone.
///
/// Weighed against three losses of a caregiver's medication list, that trade
/// was not worth it. A caregiver never notices encryption; they absolutely
/// notice their loved one's meds disappearing.
///
/// ## What this file does now
///
/// * **Decrypts, once.** An install whose DB is still SQLCipher-encrypted gets
///   it exported back to plaintext (`sqlcipher_export`) on first launch of this
///   build, and the now-useless key is removed from the keychain. The SQLCipher
///   native lib is still linked purely so we CAN read those files — see
///   `sqlcipher_flutter_libs` in pubspec, and the phase-2 note below.
/// * **Never encrypts again.** No `PRAGMA key`, and the key is never minted.
/// * **Never destroys.** A file we cannot read is moved aside (never deleted,
///   never overwriting an earlier quarantine), and a quarantine we can prove
///   was a mistake is restored.
///
/// PHASE 2 (after this build is verified on a real device with real data): drop
/// `sqlcipher_flutter_libs`, put back the plain sqlite3 lib, and delete the
/// decryption path along with this comment. Do NOT do that until an install
/// that HAD an encrypted DB has been seen to come through with its data — pull
/// the lib too early and those files become unreadable forever.
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// `flutter_secure_storage` key the legacy SQLCipher passphrase lives under.
///
/// Read-only now: we look for it to DECRYPT an old database, then delete it.
/// It is never written.
///
/// ⚠ The options used to read it must match the options it was WRITTEN with —
/// the plugin's defaults. Never pass an iOS `accessibility` class here: on
/// `flutter_secure_storage` ≥9.1 that attribute goes into the read query, Apple
/// only honours it on the first write, and the key silently becomes unfindable.
/// That is incident #2 above.
const String kDatabaseKeyStorageKey = 'holdclose.db.sqlcipher_key.v1';

/// Filename of the real on-device DB.
const String _databaseFileName = 'holdclose.sqlite';

/// Keep the Keystore-backed store on Android — same options the key was
/// written with, so it stays findable.
const AndroidOptions _androidOptions =
    AndroidOptions(encryptedSharedPreferences: true);

/// Suffix of a quarantined (unreadable) database. Quarantines are ADDITIVE —
/// see [_quarantineDatabase].
const String _quarantineSuffix = '.quarantined';

/// True only under `flutter test`.
bool get _runningUnderFlutterTest {
  try {
    return const bool.fromEnvironment('FLUTTER_TEST') ||
        Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}

/// Builds the [QueryExecutor] for the real on-device DB (PLAINTEXT).
///
/// Lazily connected, so `HoldcloseDatabase.open()` stays a synchronous factory
/// and the async work runs on the first query.
///
/// [secureStorage] is injectable for tests; production passes null.
QueryExecutor localFileExecutor({FlutterSecureStorage? secureStorage}) {
  return DatabaseConnection.delayed(Future<DatabaseConnection>(() async {
    // `flutter test` short-circuit: a few widget/routing tests mount the real
    // router without overriding storageProvider and so reach open(). Under the
    // test binding there is no path_provider, so this future never completes —
    // faithfully reproducing the old `driftDatabase(name:)` behaviour and
    // leaving no pending timers. Those tests never query the store.
    if (_runningUnderFlutterTest) {
      return Completer<DatabaseConnection>().future;
    }

    // The linked sqlite3 is still the SQLCipher build (see the library doc): it
    // reads plaintext databases perfectly well, and we need it to decrypt the
    // legacy ones.
    installSqlCipherOverride();
    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();
    }

    final Directory dir = await getApplicationDocumentsDirectory();
    final String dbPath = p.join(dir.path, _databaseFileName);

    // The legacy passphrase, if this install ever had one. NEVER minted.
    final String? key = await _readLegacyKey(secureStorage);

    // Give back a database an earlier build quarantined by mistake, before
    // anything can create an empty one over the top of it.
    restoreQuarantinedIfUsable(dbPath, key);

    // The one-time migration: SQLCipher → plaintext.
    await decryptLegacyDatabaseIfNeeded(dbPath, key, secureStorage);

    // Anything still unreadable here is not ours (or is corrupt): move it aside
    // rather than failing every query forever. Never deleted.
    quarantineIfUnreadable(dbPath);

    // No `setup:` — no PRAGMA key. The file is plaintext from here on.
    return NativeDatabase.createBackgroundConnection(
      File(dbPath),
      isolateSetup: installSqlCipherOverride,
    );
  }));
}

/// Register the SQLCipher `libsqlite3` with the sqlite3 ffi loader. Top-level
/// (it is sent to drift's background isolate) and idempotent. Android loads the
/// bundled `libsqlcipher.so`; on iOS/macOS the lib is statically linked and the
/// default `DynamicLibrary.process()` already resolves it.
void installSqlCipherOverride() {
  open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
}

/// Read the legacy passphrase. Returns null when this install never had one
/// (the common case now, and every fresh install).
///
/// Uses the plugin's DEFAULT options — the ones it was written with. See the
/// warning on [kDatabaseKeyStorageKey].
Future<String?> _readLegacyKey(FlutterSecureStorage? injected) async {
  final FlutterSecureStorage storage =
      injected ?? const FlutterSecureStorage(aOptions: _androidOptions);
  try {
    final String? key = await storage.read(
      key: kDatabaseKeyStorageKey,
      aOptions: _androidOptions,
    );
    return (key == null || key.isEmpty) ? null : key;
  } catch (e) {
    // A keychain read that throws must not wedge the app: worst case we treat
    // the install as having no key, and an encrypted DB gets quarantined
    // (moved aside, never deleted) rather than lost.
    debugPrint('db: legacy key read failed: $e');
    return null;
  }
}

/// One-time migration: export a SQLCipher-encrypted database back to PLAINTEXT
/// and forget the key.
///
/// No-op unless there is a key AND a file AND that file is actually encrypted.
/// The SQLCipher-blessed decrypt is the mirror of the old encrypt: open WITH
/// the key, ATTACH an empty sibling with `KEY ''` (no encryption),
/// `sqlcipher_export` into it, detach, then swap it over the original.
///
/// Ordering is deliberately paranoid: the original is only replaced AFTER the
/// plaintext copy is fully written and both handles are closed, so a crash
/// mid-migration leaves the encrypted original intact and the next launch just
/// retries. On failure the original is left exactly where it is — the caller's
/// [quarantineIfUnreadable] then moves it aside rather than deleting it.
Future<void> decryptLegacyDatabaseIfNeeded(
  String dbPath,
  String? key,
  FlutterSecureStorage? secureStorage,
) async {
  if (key == null) return;
  final File dbFile = File(dbPath);
  if (!dbFile.existsSync()) {
    // Nothing to decrypt, but the key is dead weight — drop it.
    await _forgetLegacyKey(secureStorage);
    return;
  }
  if (_isPlaintextDatabase(dbPath)) {
    // Already migrated on an earlier launch (or never encrypted).
    await _forgetLegacyKey(secureStorage);
    return;
  }
  if (!_keyOpensDatabase(dbPath, key)) {
    // Encrypted, but not with this key. Leave it alone — the caller
    // quarantines it (moved aside, never deleted) so it stays recoverable.
    _reportRecovery(
      'a legacy encrypted database did not open with the stored key — leaving '
      'it for quarantine rather than touching it',
    );
    return;
  }

  final String tempPath = '$dbPath.plaintext-migrating';
  final File tempFile = File(tempPath);
  if (tempFile.existsSync()) tempFile.deleteSync();

  Database? encrypted;
  try {
    encrypted = sqlite3.open(dbPath);
    encrypted.execute("PRAGMA key = '${_escapeForSql(key)}';");
    // KEY '' → the attached database is NOT encrypted.
    encrypted
      ..execute("ATTACH DATABASE '${_escapeForSql(tempPath)}' AS plaintext KEY '';")
      ..execute("SELECT sqlcipher_export('plaintext');")
      ..execute('DETACH DATABASE plaintext;');
    encrypted.dispose();
    encrypted = null;

    // Prove the copy is readable BEFORE we stand down the original.
    if (!_isPlaintextDatabase(tempPath)) {
      throw StateError('the exported copy is not a readable plaintext database');
    }

    // Keep the encrypted original as a quarantine generation (additive, never
    // overwriting) rather than deleting it: if anything about this migration is
    // wrong, the caregiver's data is still on disk.
    _quarantineDatabase(dbPath, reason: 'decrypted to plaintext (kept as a backup)');
    tempFile.renameSync(dbPath);

    await _forgetLegacyKey(secureStorage);
    _reportRecovery('decrypted the local database to plaintext (SQLCipher removed)');
  } catch (e) {
    encrypted?.dispose();
    if (tempFile.existsSync()) tempFile.deleteSync();
    // The original is untouched. Say so loudly; do not delete anything.
    _reportRecovery('decrypting the local database FAILED (original untouched): $e');
  }
}

/// Delete the legacy passphrase once it can no longer decrypt anything.
Future<void> _forgetLegacyKey(FlutterSecureStorage? injected) async {
  final FlutterSecureStorage storage =
      injected ?? const FlutterSecureStorage(aOptions: _androidOptions);
  try {
    await storage.delete(key: kDatabaseKeyStorageKey, aOptions: _androidOptions);
  } catch (e) {
    // Harmless if it lingers — it opens nothing now.
    debugPrint('db: could not delete the legacy key (harmless): $e');
  }
}

/// Undo a quarantine that should never have happened.
///
/// On every open: if there is NO live database but a quarantined one exists that
/// we can actually READ, put it back. Quarantine is non-destructive precisely so
/// a wrong one is reversible — and one happened (see the library doc).
///
/// Guarded hard, because getting this wrong is worse than the bug it fixes:
/// never clobber a live DB; only restore a file we can genuinely open (as
/// plaintext, or with the legacy [key]); sidecars travel with it.
void restoreQuarantinedIfUsable(String dbPath, String? key) {
  final File live = File(dbPath);
  final File quarantined = File('$dbPath$_quarantineSuffix');
  if (live.existsSync() || !quarantined.existsSync()) return;

  final bool readable = _isPlaintextDatabase(quarantined.path) ||
      (key != null && _keyOpensDatabase(quarantined.path, key));
  if (!readable) return;

  for (final String suffix in const <String>['', '-wal', '-shm']) {
    final File src = File('$dbPath$_quarantineSuffix$suffix');
    if (src.existsSync()) src.renameSync('$dbPath$suffix');
  }
  _reportRecovery(
    'restored a quarantined database we CAN read — the quarantine was a false '
    'alarm (care data recovered)',
  );
}

/// Move an unreadable database aside so the app can start fresh instead of
/// failing every query forever. NEVER deletes; never overwrites an earlier
/// quarantine. A file we can't read might still be someone's only copy.
void quarantineIfUnreadable(String dbPath) {
  if (!File(dbPath).existsSync()) return;
  if (_isPlaintextDatabase(dbPath)) return; // healthy
  _quarantineDatabase(dbPath, reason: 'not a readable plaintext database');
}

/// Move [dbPath] (+ sidecars) aside. ADDITIVE: the first quarantine takes the
/// plain `<db>.quarantined` name (what [restoreQuarantinedIfUsable] looks for);
/// every later one gets a timestamped sibling. Nothing is ever deleted —
/// deleting the previous generation would have destroyed the only surviving
/// copy of a caregiver's care record (incident #3 in the library doc).
void _quarantineDatabase(String dbPath, {required String reason}) {
  final String stamp =
      DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  final String base = _quarantineTargetBase(dbPath, stamp);
  for (final String suffix in const <String>['', '-wal', '-shm']) {
    final File src = File('$dbPath$suffix');
    if (src.existsSync()) src.renameSync('$base$suffix');
  }
  _reportRecovery('quarantined a database ($base): $reason');
}

String _quarantineTargetBase(String dbPath, String stamp) {
  final String plain = '$dbPath$_quarantineSuffix';
  if (!File(plain).existsSync()) return plain;
  return '$plain.$stamp';
}

/// True iff the file at [dbPath] is a readable, UNENCRYPTED sqlite database.
bool _isPlaintextDatabase(String dbPath) {
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

/// True iff the legacy [key] decrypts the database at [dbPath].
bool _keyOpensDatabase(String dbPath, String key) {
  Database? db;
  try {
    db = sqlite3.open(dbPath);
    db.execute("PRAGMA key = '${_escapeForSql(key)}';");
    db.select('SELECT count(*) FROM sqlite_master;');
    return true;
  } catch (_) {
    return false;
  } finally {
    db?.dispose();
  }
}

/// Describes something this module did to the database file. Handed to
/// [databaseRecoveryObserver] (never thrown). Carries file/reason words only —
/// never care data.
class DatabaseRecoveryException implements Exception {
  DatabaseRecoveryException(this.message);

  final String message;

  @override
  String toString() => 'DatabaseRecoveryException: $message';
}

/// Observer for anything this module does to the DB file (a decrypt, a
/// quarantine, a restore). `main.dart` wires it to the on-device crash log +
/// the opt-in aggregator BEFORE the first DB touch. With no observer the
/// breadcrumb still reaches LogBuffer via [debugPrint].
void Function(Object error, StackTrace stackTrace)? databaseRecoveryObserver;

void _reportRecovery(String message) {
  debugPrint('db-recovery: $message');
  final void Function(Object, StackTrace)? observer = databaseRecoveryObserver;
  if (observer != null) {
    try {
      observer(DatabaseRecoveryException(message), StackTrace.current);
    } catch (_) {
      // Reporting must never break the thing it is reporting on.
    }
  }
}

/// Escape a value for a single-quoted SQL string (`PRAGMA key` / `ATTACH` take
/// no bound parameters, so interpolation is unavoidable — hence the escaping).
String _escapeForSql(String value) => value.replaceAll("'", "''");

/// Drop any memoized state so a test can re-exercise the open path. No-op in
/// production (nothing calls it).
@visibleForTesting
void resetDatabaseKeyCache() {}
