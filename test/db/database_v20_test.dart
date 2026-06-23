import 'package:holdclose/db/database.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

/// v20 schema work (2026-06-11): secondary indices on the hot FK/sort
/// columns + the one-shot repair for the window entries v15 orphaned
/// (its DELETE assumed an FK cascade that never fired during migration —
/// `PRAGMA foreign_keys = ON` runs in beforeOpen, AFTER onUpgrade).
void main() {
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
