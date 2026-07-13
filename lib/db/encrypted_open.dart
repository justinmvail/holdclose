/// At-rest encryption of the local drift/SQLite file with **SQLCipher**.
///
/// Security posture: the on-device DB holds plaintext PHI (meds, dose
/// windows, appointments, journal, the care circle). This module encrypts
/// that file so a lifted-off-disk copy (a stolen/jailbroken device, a
/// forensic image, a leaked backup) is ciphertext, not care data. The
/// encryption key is a strong random passphrase minted on first run and kept
/// in the OS keychain/keystore via `flutter_secure_storage` — NEVER
/// hardcoded, never in source, never in the DB file itself.
///
/// Scope: this wires the ONE real on-device file connection
/// (`HoldcloseDatabase.open()` → the `holdclose.sqlite` file). The in-memory
/// test path (`NativeDatabase.memory()` / `testInstance()`) stays UNENCRYPTED
/// and is untouched — the whole test suite runs against plaintext in-memory
/// DBs and never loads SQLCipher.
///
/// Key facts about the SQLCipher wiring:
/// - The project resolves `sqlite3: 2.x`, so it uses the classic
///   `sqlcipher_flutter_libs` (0.6.x) native lib + the `PRAGMA key` open
///   protocol. On Android the SQLCipher `libsqlcipher.so` is loaded
///   explicitly; on iOS/macOS SQLCipher is statically linked and its symbols
///   satisfy `DynamicLibrary.process()` (the sqlite3 default), so no override
///   is needed there.
/// - The key is applied via `PRAGMA key` as the FIRST statement on every
///   connection (drift's `setup` callback), which is how SQLCipher derives
///   the file encryption key. This runs in drift's background isolate, so the
///   `setup`/`isolateSetup` closures must only capture sendable values (the
///   key is a `String` — sendable).
/// - Existing testers have a PLAINTEXT `holdclose.sqlite` on disk. Opening it
///   with a key would fail ("file is not a database"). Before handing the
///   file to drift we detect that case on the main isolate and rekey-migrate
///   it in place via `sqlcipher_export` (see [_migratePlaintextIfNeeded]), so
///   an upgrading tester keeps their care data.
///
/// Key-lifecycle invariants (2026-07-13 hardening, after a real data-loss
/// bug where racing first-run opens each minted their own key and the last
/// keychain write stranded the file under a key nobody kept):
/// - The key read/mint is memoized process-wide ([obtainDatabaseKey]) —
///   concurrent opens share ONE future, so at most one mint ever runs.
/// - A key is NEVER minted while an encrypted database exists; a fresh mint
///   is read back from the keychain before anything is encrypted with it.
/// - An undecryptable database is never deleted and never wedges the app:
///   it is QUARANTINED (`holdclose.sqlite.quarantined`, kept one generation
///   deep for support/forensics) and a fresh encrypted DB is built, reported
///   through [databaseRecoveryObserver].
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
// The sqlite3 `open` resolver + `OperatingSystem` enum live in `open.dart`;
// the top-level `sqlite3` instance + `Database` in `sqlite3.dart`. Both are
// direct deps now (declared in pubspec) because this file calls them
// directly to run the pre-open plaintext→cipher migration.
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// `flutter_secure_storage` key under which the DB passphrase lives. Stable
/// forever — changing it would strand every existing encrypted DB (the old
/// key would be unrecoverable and the file unreadable). Namespaced so it
/// never collides with the auth-token / forum-session entries this app also
/// keeps in secure storage.
const String kDatabaseKeyStorageKey = 'holdclose.db.sqlcipher_key.v1';

/// Filename of the real on-device DB, matching `driftDatabase(name:
/// 'holdclose')`'s `$name.sqlite` convention. Kept here so the migration can
/// resolve the exact same file drift will later open.
const String _databaseFileName = 'holdclose.sqlite';

/// iOS-safe `AndroidOptions`: keep the key in `EncryptedSharedPreferences`
/// (Keystore-backed) rather than the legacy plaintext prefs. Mirrors the
/// hardening the auth-token storage would use.
const AndroidOptions _androidOptions =
    AndroidOptions(encryptedSharedPreferences: true);

/// iOS keychain class for the DB key: `first_unlock_this_device`.
///
/// - *this_device*: the key never leaves this device (no iCloud-keychain
///   sync, no restore onto another device). It matches the DB file, which is
///   itself backup-excluded — a key without its file is useless, and a
///   synced key is pure attack surface.
/// - *after first unlock*: a background wake (sync, a notification handler)
///   touching the DB after a reboot reads the key instead of erroring.
///
/// Only newly written keys carry this class; keys minted before this change
/// keep the plugin default (`unlocked`), which stays readable — the class is
/// applied on write, never required on read.
const IOSOptions _iosOptions =
    IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

/// Filename suffix of a quarantined (undecryptable) database. One quarantine
/// generation is kept — a newer one replaces it.
const String _quarantineSuffix = '.quarantined';

/// True only under `flutter test` (the harness exports `FLUTTER_TEST`).
/// Mirrors the guard the billing/llm/crash providers use to keep native
/// paths (StoreKit, Sentry, real capture) out of the test binding.
bool get _runningUnderFlutterTest {
  try {
    return const bool.fromEnvironment('FLUTTER_TEST') ||
        Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}

/// Builds the encrypted [QueryExecutor] for the real on-device DB.
///
/// Returned as a lazily-connected [DatabaseConnection.delayed] — the SAME
/// shape `driftDatabase(name: ...)` returns — so `HoldcloseDatabase.open()`
/// stays a plain synchronous factory: the async work (resolve app-docs dir →
/// read/mint key → migrate any plaintext file → open the encrypted
/// background connection) runs on the first query. Mirroring that shape (vs a
/// `LazyDatabase`) matters for `flutter test`: it lets the connection FAIL
/// LAZILY under the test binding exactly as the old path did, without leaving
/// a pending stream-query dispose timer.
///
/// [secureStorage] is injectable so a device/integration test can supply a
/// fake; production passes `null` and gets a real keychain-backed store.
QueryExecutor encryptedFileExecutor({FlutterSecureStorage? secureStorage}) {
  return DatabaseConnection.delayed(Future<DatabaseConnection>(() async {
    // `flutter test` short-circuit. A handful of widget/routing tests mount
    // the real router WITHOUT overriding `storageProvider`, so they reach
    // `HoldcloseDatabase.open()`. Under the test binding the native SQLCipher
    // open (path_provider + background isolates + the `libsqlcipher` ffi
    // load) can't run — so we return a connection future that NEVER completes,
    // faithfully reproducing how the previous `driftDatabase(name:...)` path
    // behaved: its first call was `getApplicationDocumentsDirectory()`, a
    // platform-channel call that stays UNRESOLVED under `flutter test` (there
    // is no path_provider mock). Because it never resolves, the DB never
    // connects and no drift stream-query machinery — hence no pending timer —
    // is ever created. (Throwing here instead surfaces as a test error via
    // the fake-async timer; a never-resolving future is the accurate model.)
    // These tests only render the tab shell + never query the store, so the
    // hung connection is invisible to them. The DB-dependent suites never
    // rely on `.open()` succeeding: they pass `NativeDatabase.memory()` /
    // `testInstance()` directly. The encryption path is production-only
    // (device-validated — see the module header + the commit's device-build
    // notes).
    if (_runningUnderFlutterTest) {
      return Completer<DatabaseConnection>().future;
    }

    // Point the sqlite3 ffi loader at the SQLCipher build on THIS (main)
    // isolate before we open the file for the plaintext probe/migration.
    installSqlCipherOverride();
    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();
    }

    final Directory dir = await getApplicationDocumentsDirectory();
    final String dbPath = p.join(dir.path, _databaseFileName);
    final String key =
        await obtainDatabaseKey(dbPath: dbPath, secureStorage: secureStorage);

    // Repair an existing plaintext install in place so upgraders keep data.
    await _migratePlaintextIfNeeded(dbPath, key);

    // Self-heal: if the file can't actually be opened with OUR key (wrong
    // key after a historical mint race, or a corrupt file), quarantine it so
    // the keyed open below builds a fresh encrypted DB instead of failing
    // "file is not a database" on every query forever.
    recoverIfUndecryptable(dbPath, key);

    return NativeDatabase.createBackgroundConnection(
      File(dbPath),
      // Runs in drift's background DB isolate: re-point the ffi loader at
      // SQLCipher there too (each isolate has its own `open` resolver).
      isolateSetup: installSqlCipherOverride,
      // Runs on every opened connection, FIRST — this is what unlocks the
      // encrypted file. `key` is a String, so this closure is isolate-safe.
      setup: (RawDatabase rawDb) {
        rawDb.execute("PRAGMA key = '${_escapeKeyForPragma(key)}';");
        assert(
          _debugHasCipher(rawDb),
          'SQLCipher library is not active — PRAGMA cipher_version returned '
          'nothing. The plain sqlite3_flutter_libs build was linked instead '
          'of sqlcipher_flutter_libs.',
        );
      },
    );
  }));
}

/// A sqlite3 [Database] as drift hands it to `setup` (a raw, un-delegated
/// native handle). Named locally for readability — drift's `DatabaseSetup`
/// typedef is `void Function(Database)`.
typedef RawDatabase = Database;

/// Register the SQLCipher `libsqlite3` with the sqlite3 ffi loader.
///
/// Idempotent, and safe to call on any isolate (each isolate keeps its own
/// `open` resolver, so both the main-isolate migration and drift's DB isolate
/// must call it). A TOP-LEVEL function on purpose: it's sent to drift's
/// background isolate as `isolateSetup`, so it must not capture state.
///
/// - Android: load the bundled `libsqlcipher.so` (falls back to the absolute
///   `/data/data/<id>/lib/...` path on quirky old devices — see
///   `openCipherOnAndroid`).
/// - iOS/macOS: SQLCipher is statically linked into the app binary and its
///   symbols replace the system sqlite3, so the default `DynamicLibrary.process()`
///   already resolves to SQLCipher — no override needed (and overriding to a
///   named lib would fail).
void installSqlCipherOverride() {
  open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
}

/// Process-wide memo behind [obtainDatabaseKey]: every caller shares one
/// read/mint, so concurrent opens can never each mint their own key.
Future<String>? _cachedKey;

/// Drop the memoized key future so a test can exercise the key logic
/// repeatedly. Production never calls this.
@visibleForTesting
void resetDatabaseKeyCache() {
  _cachedKey = null;
}

/// The DB passphrase, memoized process-wide.
///
/// Concurrent callers await the SAME future, so exactly one keychain read —
/// and at most one mint — is ever in flight. This is the first line of
/// defense against the 2026-07 data-loss bug where racing first-run opens
/// each minted a key, the file was encrypted under one, and the LAST
/// keychain write stranded it under another (every later launch then died
/// with "file is not a database"). A failed attempt clears the memo so the
/// next open retries cleanly.
///
/// [secureStorage] and [dbPath] only take effect on the first call of a
/// process (or after [resetDatabaseKeyCache]) — later calls join the memo.
Future<String> obtainDatabaseKey({
  required String dbPath,
  FlutterSecureStorage? secureStorage,
}) {
  return _cachedKey ??= () async {
    try {
      return await _readOrCreateKey(secureStorage, dbPath);
    } catch (_) {
      _cachedKey = null;
      rethrow;
    }
  }();
}

/// Read the stored DB passphrase, minting + persisting a fresh strong one
/// when none exists. The key is 32 random bytes (256 bits) hex-encoded —
/// SQLCipher treats a quoted `PRAGMA key` string as a passphrase and runs it
/// through PBKDF2, so this is ample entropy.
///
/// Two invariants guard the mint (both born from the 2026-07 key-race bug —
/// see [obtainDatabaseKey]):
///  1. NEVER mint while an ENCRYPTED database exists. An encrypted file
///     whose key can't be read is quarantined FIRST, so a mint only ever
///     applies to a fresh install or a plaintext upgrader — it can never
///     silently strand data. (A PLAINTEXT file with no key is the normal
///     pre-encryption upgrade; minting is exactly right there.)
///  2. A fresh mint is READ BACK before use — a keychain write that didn't
///     persist fails the open (harmlessly, since only an empty install can
///     reach a mint) rather than encrypting data under an unrecoverable key.
Future<String> _readOrCreateKey(
    FlutterSecureStorage? injected, String dbPath) async {
  final FlutterSecureStorage storage = injected ??
      const FlutterSecureStorage(
        aOptions: _androidOptions,
        iOptions: _iosOptions,
      );

  final String? existing = await storage.read(
    key: kDatabaseKeyStorageKey,
    aOptions: _androidOptions,
    iOptions: _iosOptions,
  );
  if (existing != null && existing.isNotEmpty) return existing;

  // No key on file. An encrypted DB at [dbPath] is unrecoverable without
  // one — quarantine it (kept on disk, see [_quarantineDatabase]) rather
  // than minting "over" it.
  final File dbFile = File(dbPath);
  if (dbFile.existsSync() && !_isPlaintextDatabase(dbPath)) {
    _quarantineDatabase(
      dbPath,
      reason: 'encrypted database present but no key in secure storage',
    );
  }

  final String fresh = _generatePassphrase();
  await storage.write(
    key: kDatabaseKeyStorageKey,
    value: fresh,
    aOptions: _androidOptions,
    iOptions: _iosOptions,
  );
  final String? readBack = await storage.read(
    key: kDatabaseKeyStorageKey,
    aOptions: _androidOptions,
    iOptions: _iosOptions,
  );
  if (readBack != fresh) {
    throw StateError(
      'holdclose db key: keychain write did not persist — refusing to '
      'encrypt with an unrecoverable key',
    );
  }
  return fresh;
}

/// 256 bits from the platform CSPRNG (`Random.secure()`), lowercase hex.
/// Hand-rolled hex (no `package:convert` dep) so the only new dependency this
/// feature adds is `sqlcipher_flutter_libs`.
String _generatePassphrase() {
  final Random rng = Random.secure();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < 32; i++) {
    out.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// If [dbPath] holds an existing PLAINTEXT database (a pre-encryption install
/// upgrading to this build), rekey it in place to SQLCipher so the tester
/// keeps their care data. No-op when the file is absent (fresh install) or
/// already encrypted (normal launch).
///
/// Approach — the ATTACH + `sqlcipher_export` pattern (the SQLCipher-blessed
/// rekey, safer than editing the file's page format underneath live pages):
/// 1. Open the file with no key and probe it. If the probe succeeds, it's
///    plaintext and must be migrated; if it throws, it's already encrypted
///    (an unkeyed handle can't read a SQLCipher file) and we return.
/// 2. `ATTACH` a brand-new sibling file keyed with our passphrase, copy the
///    whole schema+data into it via `sqlcipher_export('encrypted')`, detach.
/// 3. Atomically swap the encrypted sibling over the original path.
///
/// Why in-place-with-swap rather than a fresh empty DB: silently dropping an
/// upgrader's meds/appointments/journal would be data loss. The swap only
/// replaces the original AFTER the encrypted copy is fully written and the
/// handles are closed, so a crash mid-migration leaves the original intact
/// (the temp file is just orphaned and retried next launch).
///
/// If migration itself throws (a corrupt or partially-written legacy file),
/// we DELETE the unreadable original and start fresh-encrypted. That is the
/// documented fallback: older data may not carry over in that rare case, and
/// the demo-backfill / `ensurePatient` path repopulates a usable profile so
/// no screen is left broken. We prefer a working encrypted install over
/// wedging the app on an unreadable legacy file.
Future<void> _migratePlaintextIfNeeded(String dbPath, String key) async {
  final File dbFile = File(dbPath);
  if (!dbFile.existsSync()) return; // fresh install — nothing to migrate

  final bool isPlaintext = _isPlaintextDatabase(dbPath);
  if (!isPlaintext) return; // already encrypted (or unreadable-as-plaintext)

  final String tempPath = '$dbPath.migrating';
  // Clean up any orphan from a prior interrupted attempt.
  final File tempFile = File(tempPath);
  if (tempFile.existsSync()) tempFile.deleteSync();

  Database? plain;
  try {
    plain = sqlite3.open(dbPath);
    final String escapedTemp = _escapeKeyForPragma(tempPath);
    final String escapedKey = _escapeKeyForPragma(key);
    plain
      ..execute("ATTACH DATABASE '$escapedTemp' AS encrypted KEY '$escapedKey';")
      ..execute("SELECT sqlcipher_export('encrypted');")
      ..execute('DETACH DATABASE encrypted;');
    plain.dispose();
    plain = null;

    // Swap the encrypted copy in. Keep a one-shot backup of the original so a
    // failed rename can't destroy data.
    final String backupPath = '$dbPath.plaintext-backup';
    final File backupFile = File(backupPath);
    if (backupFile.existsSync()) backupFile.deleteSync();
    dbFile.renameSync(backupPath);
    tempFile.renameSync(dbPath);
    // Encrypted copy is now in place. Remove the plaintext backup so the PHI
    // doesn't linger unencrypted on disk.
    backupFile.deleteSync();
  } catch (_) {
    // Migration failed on a corrupt/partial legacy file. Fall back to a
    // fresh encrypted DB (see doc comment): QUARANTINE the unreadable
    // original (+ its WAL/SHM side files — kept on disk for support, never
    // deleted) and drop the temp, so drift's onCreate builds a clean
    // encrypted file and the seed/backfill repopulates. DOCUMENTED: older
    // data may not carry over in this case.
    plain?.dispose();
    if (tempFile.existsSync()) tempFile.deleteSync();
    _quarantineDatabase(
      dbPath,
      reason: 'plaintext-to-SQLCipher migration failed',
    );
  }
}

/// Move the database at [dbPath] (plus its `-wal`/`-shm` sidecars) aside to
/// `<db>.quarantined` instead of deleting it.
///
/// Quarantining is the ONLY destructive move this module makes on an
/// unreadable file: the bytes stay on disk (one generation deep — a newer
/// quarantine replaces the last) for support/forensic recovery, while drift
/// gets a clean path to build a fresh encrypted DB — the app recovers
/// instead of failing every query forever. Each quarantine is reported
/// through [databaseRecoveryObserver].
void _quarantineDatabase(String dbPath, {required String reason}) {
  for (final String suffix in const <String>['', '-wal', '-shm']) {
    final File src = File('$dbPath$suffix');
    final File dst = File('$dbPath$_quarantineSuffix$suffix');
    if (dst.existsSync()) dst.deleteSync();
    if (src.existsSync()) src.renameSync(dst.path);
  }
  _reportRecovery('quarantined undecryptable database: $reason');
}

/// True iff [key] actually opens the database at [dbPath] — the header
/// decrypts and the schema page reads. Runs on the main isolate, which has
/// the SQLCipher `open` override installed by [encryptedFileExecutor].
bool _keyOpensDatabase(String dbPath, String key) {
  Database? db;
  try {
    db = sqlite3.open(dbPath);
    db.execute("PRAGMA key = '${_escapeKeyForPragma(key)}';");
    db.select('SELECT count(*) FROM sqlite_master;');
    return true;
  } catch (_) {
    return false;
  } finally {
    db?.dispose();
  }
}

/// Pre-open self-heal: verify [key] opens the file at [dbPath]; when it
/// doesn't (wrong key from a historical mint race, or a corrupt file),
/// quarantine the file so drift's keyed open right after gets a fresh path
/// instead of surfacing "file is not a database" on every query forever.
/// No-op when the file doesn't exist. Costs one extra key derivation on the
/// (lazy, once-per-launch) first DB query.
void recoverIfUndecryptable(String dbPath, String key) {
  if (!File(dbPath).existsSync()) return;
  if (_keyOpensDatabase(dbPath, key)) return;
  _quarantineDatabase(dbPath, reason: 'keyed open failed');
}

/// Describes a destructive recovery action this module took. Handed to
/// [databaseRecoveryObserver] (never thrown) so crash aggregation groups
/// recoveries apart from real crashes. [message] carries file/reason words
/// only — never care data (the quarantined content stays on disk,
/// encrypted).
class DatabaseRecoveryException implements Exception {
  DatabaseRecoveryException(this.message);

  /// What was recovered and why.
  final String message;

  @override
  String toString() => 'DatabaseRecoveryException: $message';
}

/// Observer for destructive recovery steps (quarantining an undecryptable
/// DB). `main.dart` wires this to the on-device crash log + the opt-in
/// crash aggregator BEFORE the first DB touch. When null (low-level tests),
/// the breadcrumb still reaches the console/LogBuffer via [debugPrint].
void Function(Object error, StackTrace stackTrace)? databaseRecoveryObserver;

void _reportRecovery(String message) {
  // debugPrint tees into LogBuffer (main._captureLogs), so the breadcrumb
  // rides along with the next feedback report even with no observer wired.
  debugPrint('db-recovery: $message');
  final void Function(Object, StackTrace)? observer = databaseRecoveryObserver;
  if (observer != null) {
    try {
      observer(DatabaseRecoveryException(message), StackTrace.current);
    } catch (_) {
      // Recovery reporting must never break recovery itself.
    }
  }
}

/// Probe whether the file at [dbPath] is a PLAINTEXT sqlite DB.
///
/// Opens it with NO key and reads the schema. A plaintext file reads fine; a
/// SQLCipher file throws ("file is not a database", because the header is
/// encrypted). Any throw is treated as "not plaintext" (i.e. leave it for the
/// keyed open to handle). The handle is always disposed.
bool _isPlaintextDatabase(String dbPath) {
  Database? probe;
  try {
    probe = sqlite3.open(dbPath);
    // Force a read of the (unencrypted) header/schema page.
    probe.select('SELECT count(*) FROM sqlite_master;');
    return true;
  } catch (_) {
    return false;
  } finally {
    probe?.dispose();
  }
}

/// True iff the active `libsqlite3` is a SQLCipher build (asserts only).
bool _debugHasCipher(Database database) {
  try {
    final ResultSet rs = database.select('PRAGMA cipher_version;');
    return rs.isNotEmpty && (rs.first.values.first?.toString().isNotEmpty ?? false);
  } catch (_) {
    return false;
  }
}

/// Escape a value for interpolation inside a single-quoted SQL string in a
/// `PRAGMA` / `ATTACH`. The key is our own hex (no quotes) and the path is
/// app-owned, but doubling single quotes keeps this correct + injection-safe
/// regardless. (SQLCipher's `PRAGMA key` has no bound-parameter form, so
/// interpolation is unavoidable here — hence the escaping.)
String _escapeKeyForPragma(String value) => value.replaceAll("'", "''");
