import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// Drift-managed SQLite database (BUILD_SPEC.md §6.2). Holds three
/// tables: `journal_entries` (auto-logged decoder runs),
/// `patients` (the loved one — one row per install) and
/// `app_settings` (single-row preferences blob).
///
/// Construct with [CareblazersDatabase.open] in production — it lazily
/// opens a SQLite file under the platform's app-documents directory via
/// `drift_flutter`. Tests pass a `NativeDatabase.memory()` directly to
/// the unnamed constructor so each test gets an isolated DB.
@DriftDatabase(
  tables: <Type>[
    JournalEntriesTable,
    PatientsTable,
    AppSettingsTable,
  ],
)
class CareblazersDatabase extends _$CareblazersDatabase {
  CareblazersDatabase(super.executor);

  /// Opens the on-device SQLite file named `careblazers.sqlite` in the
  /// platform's app-documents directory. Used by production wiring;
  /// tests bypass this in favour of `NativeDatabase.memory()`.
  factory CareblazersDatabase.open() => CareblazersDatabase(
        driftDatabase(name: 'careblazers'),
      );

  @override
  int get schemaVersion => 1;

  /// Truncate every table — backs `StorageProvider.reset()` for the
  /// demo-mode "Reset on launch" toggle (BUILD_SPEC.md §6.2 + §9.3).
  Future<void> wipeAll() async {
    await transaction(() async {
      await delete(journalEntriesTable).go();
      await delete(patientsTable).go();
      await delete(appSettingsTable).go();
    });
  }
}
