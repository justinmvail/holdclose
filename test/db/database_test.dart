import 'package:careblazers/db/database.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CareblazersDatabase.testInstance() (TASKS.md Phase 15.2)', () {
    late CareblazersDatabase db;

    setUp(() {
      db = CareblazersDatabase.testInstance();
    });

    tearDown(() async {
      await db.close();
    });

    test('opens at the current schema version', () async {
      // The Dart-side constant the migration runs against.
      expect(db.schemaVersion, 20);

      // And the in-memory file itself is stamped to that version once it's
      // actually opened. `user_version` is written by drift after the
      // `onCreate` migration completes, so this read (which forces the lazy
      // open) proves the migration ran and pinned the right version.
      final QueryRow row =
          await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), db.schemaVersion);
    });

    test('applies migrations cleanly — every table is materialised', () async {
      // `onCreate` runs `createAll()` against the blank in-memory file. If
      // any table failed to materialise, selecting from it throws. Sweeping
      // every registered table proves the create migration covered the full
      // schema (all registered tables) with no orphan definitions.
      for (final TableInfo<Table, dynamic> table in db.allTables) {
        final List<QueryRow> rows =
            await db.customSelect('SELECT * FROM ${table.actualTableName}')
                .get();
        expect(rows, isEmpty,
            reason: '${table.actualTableName} should open empty');
      }

      // beforeOpen pins `PRAGMA foreign_keys = ON` per connection — the
      // cascade deletes elsewhere are no-ops without it, so the harness's
      // isolated instance must come up with enforcement live.
      final QueryRow fk =
          await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(fk.read<int>('foreign_keys'), 1);
    });

    test('multiple instances are independent — no shared on-disk file',
        () async {
      final CareblazersDatabase other = CareblazersDatabase.testInstance();
      addTearDown(other.close);

      // A write into one instance must never surface in the other; each
      // `NativeDatabase.memory()` is its own private connection.
      await db.into(db.patientsTable).insert(
            PatientsTableCompanion.insert(
              id: 'only-in-first',
              payload: '{}',
            ),
          );

      expect(await db.select(db.patientsTable).get(), hasLength(1));
      expect(await other.select(other.patientsTable).get(), isEmpty);

      // And the reverse direction, so the isolation isn't one-way.
      await other.into(other.patientsTable).insert(
            PatientsTableCompanion.insert(
              id: 'only-in-second',
              payload: '{}',
            ),
          );

      expect(
        (await db.select(db.patientsTable).get())
            .map((PatientsTableData r) => r.id)
            .toList(),
        <String>['only-in-first'],
      );
      expect(
        (await other.select(other.patientsTable).get())
            .map((PatientsTableData r) => r.id)
            .toList(),
        <String>['only-in-second'],
      );
    });
  });
}
