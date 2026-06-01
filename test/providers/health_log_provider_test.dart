import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/health_log_entry.dart';
import 'package:careblazers/providers/health_log_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

HealthLogEntry _entry({
  required String id,
  required DateTime recordedAt,
  String patientId = 'mary',
  HealthLogKind kind = HealthLogKind.note,
  int? severity,
  int? systolic,
  int? diastolic,
  int? heartRate,
  double? temperatureF,
  String? notes,
}) =>
    HealthLogEntry(
      id: id,
      patientId: patientId,
      recordedAt: recordedAt,
      kind: kind,
      severity: severity,
      systolic: systolic,
      diastolic: diastolic,
      heartRate: heartRate,
      temperatureF: temperatureF,
      notes: notes,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---- Repository CRUD via the in-memory ("fake") database --------------

  group('HealthLogRepository — Phase 14.16 (in-memory DB)', () {
    late CareblazersDatabase db;
    late HealthLogRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = HealthLogRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('upsert + getById round-trips the model through SQLite', () async {
      final HealthLogEntry e = _entry(
        id: 'hl-1',
        recordedAt: DateTime.utc(2026, 6, 1, 8, 30),
        kind: HealthLogKind.vitals,
        systolic: 128,
        diastolic: 82,
        heartRate: 74,
        temperatureF: 98.6,
        notes: 'Resting',
      );
      await repo.upsert(e);

      expect(await repo.getById('hl-1'), equals(e));
    });

    test('getById returns null for an unknown id', () async {
      expect(await repo.getById('never-existed'), isNull);
    });

    test('upsert replaces an existing row by id (update path)', () async {
      final HealthLogEntry original = _entry(
        id: 'hl-1',
        recordedAt: DateTime.utc(2026, 6, 1, 8),
        kind: HealthLogKind.symptom,
        severity: 2,
      );
      await repo.upsert(original);

      final HealthLogEntry edited = original.copyWith(severity: 5);
      await repo.upsert(edited);

      expect(await repo.getById('hl-1'), equals(edited));
      expect(await repo.listAll(), hasLength(1));
    });

    test('delete removes the row; no-op for a missing id', () async {
      await repo.upsert(_entry(id: 'hl-1', recordedAt: DateTime.utc(2026, 6, 1)));
      await repo.delete('hl-1');
      expect(await repo.getById('hl-1'), isNull);

      // Deleting again is harmless.
      await repo.delete('hl-1');
      expect(await repo.listAll(), isEmpty);
    });

    test('listAll returns every row newest-first', () async {
      await repo.upsert(_entry(id: 'old', recordedAt: DateTime.utc(2026, 6, 1, 8)));
      await repo.upsert(_entry(id: 'new', recordedAt: DateTime.utc(2026, 6, 1, 20)));
      await repo.upsert(_entry(id: 'mid', recordedAt: DateTime.utc(2026, 6, 1, 12)));

      final List<HealthLogEntry> all = await repo.listAll();
      expect(all.map((HealthLogEntry e) => e.id).toList(),
          <String>['new', 'mid', 'old']);
    });

    test('byPatient filters to one loved one, newest-first', () async {
      await repo.upsert(_entry(
          id: 'm1', patientId: 'mary', recordedAt: DateTime.utc(2026, 6, 1, 8)));
      await repo.upsert(_entry(
          id: 'm2', patientId: 'mary', recordedAt: DateTime.utc(2026, 6, 1, 18)));
      await repo.upsert(_entry(
          id: 'j1', patientId: 'john', recordedAt: DateTime.utc(2026, 6, 1, 9)));

      final List<HealthLogEntry> mary = await repo.byPatient('mary');
      expect(mary.map((HealthLogEntry e) => e.id).toList(),
          <String>['m2', 'm1']);
      expect(await repo.byPatient('nobody'), isEmpty);
    });
  });

  // ---- Notifier: CRUD + selectors ---------------------------------------

  group('HealthLog notifier — Phase 14.16', () {
    late CareblazersDatabase db;

    // A fixed LOCAL clock at noon on 2026-06-01 so the today-bucket test
    // is deterministic regardless of the host machine's timezone.
    DateTime fixedLocalNow() => DateTime(2026, 6, 1, 12);

    ProviderContainer makeContainer() {
      db = CareblazersDatabase(NativeDatabase.memory());
      final HealthLogRepository repo = HealthLogRepository(db);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          healthLogRepositoryProvider.overrideWithValue(repo),
          healthLogClockProvider.overrideWithValue(fixedLocalNow),
        ],
      );
      // Keep the notifier subscription alive for the test's duration.
      container.listen<AsyncValue<List<HealthLogEntry>>>(
        healthLogProvider,
        (AsyncValue<List<HealthLogEntry>>? _,
            AsyncValue<List<HealthLogEntry>> __) {},
        fireImmediately: true,
      );
      return container;
    }

    tearDown(() async {
      await db.close();
    });

    test('build starts empty, then add/updateEntry/delete persist', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      expect(await container.read(healthLogProvider.future), isEmpty);

      final HealthLog notifier = container.read(healthLogProvider.notifier);
      final HealthLogEntry e = _entry(
        id: 'hl-1',
        recordedAt: DateTime(2026, 6, 1, 9),
        kind: HealthLogKind.symptom,
        severity: 3,
      );
      await notifier.add(e);
      expect(container.read(healthLogProvider).requireValue.single, equals(e));

      await notifier.updateEntry(e.copyWith(severity: 5));
      expect(
          container.read(healthLogProvider).requireValue.single.severity, 5);

      await notifier.delete('hl-1');
      expect(container.read(healthLogProvider).requireValue, isEmpty);
    });

    test('byPatient selector filters the loaded list', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final HealthLog notifier = container.read(healthLogProvider.notifier);
      await notifier.add(_entry(
          id: 'm1', patientId: 'mary', recordedAt: DateTime(2026, 6, 1, 9)));
      await notifier.add(_entry(
          id: 'j1', patientId: 'john', recordedAt: DateTime(2026, 6, 1, 10)));

      expect(notifier.byPatient('mary').map((HealthLogEntry e) => e.id),
          <String>['m1']);
      expect(notifier.byPatient('john').map((HealthLogEntry e) => e.id),
          <String>['j1']);
      expect(notifier.byPatient('nobody'), isEmpty);
    });

    test('todayByKind buckets correctly across local-midnight', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final HealthLog notifier = container.read(healthLogProvider.notifier);

      // Clock = local noon 2026-06-01.
      // Today, one second before midnight — in bucket.
      await notifier.add(_entry(
        id: 'today-late',
        kind: HealthLogKind.vitals,
        recordedAt: DateTime(2026, 6, 1, 23, 59, 59),
      ));
      // Tomorrow, one minute after midnight — out of bucket.
      await notifier.add(_entry(
        id: 'tomorrow-early',
        kind: HealthLogKind.vitals,
        recordedAt: DateTime(2026, 6, 2, 0, 1),
      ));
      // Yesterday, one second before midnight — out of bucket.
      await notifier.add(_entry(
        id: 'yesterday-late',
        kind: HealthLogKind.vitals,
        recordedAt: DateTime(2026, 5, 31, 23, 59, 59),
      ));
      // Today but a different kind — excluded by the kind filter.
      await notifier.add(_entry(
        id: 'today-symptom',
        kind: HealthLogKind.symptom,
        recordedAt: DateTime(2026, 6, 1, 10),
      ));

      final List<HealthLogEntry> todayVitals =
          notifier.todayByKind(HealthLogKind.vitals);
      expect(todayVitals.map((HealthLogEntry e) => e.id).toList(),
          <String>['today-late']);

      // The lone same-day symptom is found under its own kind.
      expect(
          notifier.todayByKind(HealthLogKind.symptom).single.id,
          'today-symptom');
      // No notes today.
      expect(notifier.todayByKind(HealthLogKind.note), isEmpty);
    });
  });
}
