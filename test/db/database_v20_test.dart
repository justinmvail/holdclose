import 'package:holdclose/db/database.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

/// v20 schema work (2026-06-11): secondary indices on the hot FK/sort
/// columns + the one-shot repair for the window entries v15 orphaned
/// (its DELETE assumed an FK cascade that never fired during migration —
/// `PRAGMA foreign_keys = ON` runs in beforeOpen, AFTER onUpgrade).
void main() {
  test('the v20 upgrade step is IDEMPOTENT — re-running it over indices that '
      'already exist must NOT throw (fb: "Couldn\'t save just now")', () async {
    // The bug this pins, from a tester's phone (2026-07-13):
    //
    //   SqliteException(1): index journal_entries_created_idx already exists
    //   Causing statement: CREATE INDEX journal_entries_created_idx ...
    //
    // Drift emits `CREATE TABLE IF NOT EXISTS` but a BARE `CREATE INDEX`. If a
    // migration is interrupted after the indices are created but before the
    // schema version is committed, the next launch re-runs this step, the
    // CREATE INDEX blows up, and EVERY database write throws from then on —
    // forever. The caregiver is stranded on onboarding with "Couldn't save
    // just now", and reinstalling the app doesn't help because the file
    // survives. It cost most of a day, hidden behind an unrelated encryption
    // bug we were chasing at the time.
    //
    // A migration step must be safe to run TWICE. This runs it a second time
    // against a database that already has every v20 index.
    final HoldcloseDatabase db = HoldcloseDatabase.testInstance();
    addTearDown(db.close);
    // Materialise the schema (and therefore the indices).
    await db.customSelect('SELECT 1').get();

    // Re-run the exact upgrade step against the already-migrated database.
    await expectLater(
      db.customStatement(
        'CREATE INDEX IF NOT EXISTS journal_entries_created_idx '
        'ON journal_entries (created_at_ms)',
      ),
      completes,
      reason: 'the migration must tolerate indices that are already there',
    );

    final Migrator m = Migrator(db);
    await expectLater(
      db.migration.onUpgrade(m, 19, 20),
      completes,
      reason: 'a re-run of the v20 upgrade must not throw',
    );
  });

  test('a fresh install carries the v20 secondary indices', () async {
    final HoldcloseDatabase db = HoldcloseDatabase.testInstance();
    addTearDown(db.close);

    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    final Set<String> names =
        rows.map((QueryRow r) => r.read<String>('name')).toSet();

    expect(
      names,
      containsAll(<String>[
        'chat_messages_conversation_idx',
        'medication_window_entries_window_idx',
        'medication_window_entries_medication_idx',
        'dose_logs_medication_scheduled_idx',
        'journal_entries_created_idx',
        'health_log_entries_patient_recorded_idx',
      ]),
    );
  });

  test('the orphan-repair SQL removes window entries whose window is gone '
      'and leaves intact ones alone', () async {
    final HoldcloseDatabase db = HoldcloseDatabase.testInstance();
    addTearDown(db.close);

    // Build the v15 orphan state by hand: with FKs OFF (exactly the
    // condition during onUpgrade), delete a window out from under its
    // entry so the cascade never fires.
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.customStatement(
      "INSERT INTO medications (id, name, payload) "
      "VALUES ('med-1', 'Donepezil', '{}')",
    );
    await db.customStatement(
      "INSERT INTO dose_windows (id, patient_id, anchor_minute, payload) "
      "VALUES ('win-live', 'p1', 480, '{}')",
    );
    await db.customStatement(
      "INSERT INTO medication_window_entries "
      "(id, medication_id, window_id, payload) VALUES "
      "('entry-live', 'med-1', 'win-live', '{}'), "
      "('entry-orphan', 'med-1', 'win-deleted-by-v15', '{}')",
    );
    await db.customStatement('PRAGMA foreign_keys = ON');

    await db.customStatement(
      HoldcloseDatabase.cleanupOrphanedWindowEntriesSql,
    );

    final List<QueryRow> left = await db
        .customSelect('SELECT id FROM medication_window_entries')
        .get();
    expect(
      left.map((QueryRow r) => r.read<String>('id')).toList(),
      <String>['entry-live'],
    );
  });
}
