import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/care_shift.dart';
import 'package:careblazers/providers/care_shifts_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

CareShift _shift({
  required String id,
  required String caregiverId,
  required DateTime start,
  required DateTime end,
  String? notes,
}) =>
    CareShift(
      id: id,
      caregiverId: caregiverId,
      start: start,
      end: end,
      patientId: _patientId,
      notes: notes,
    );

/// A shift on the local day [DateTime(2026, 6, 1)] from hour [fromHour] to
/// hour [toHour] (24h clock), covered by [caregiverId].
CareShift _onDay1({
  required String id,
  required String caregiverId,
  required int fromHour,
  required int toHour,
}) =>
    _shift(
      id: id,
      caregiverId: caregiverId,
      start: DateTime(2026, 6, 1, fromHour),
      end: DateTime(2026, 6, 1, toHour),
    );

final DateTime _day1 = DateTime(2026, 6, 1);

void main() {
  group('CareShift — model', () {
    test('duration clamps a non-positive window to zero', () {
      expect(
        _onDay1(id: 's', caregiverId: 'c1', fromHour: 6, toHour: 14).duration,
        const Duration(hours: 8),
      );
      // end == start.
      final CareShift zero = _shift(
        id: 's',
        caregiverId: 'c1',
        start: DateTime(2026, 6, 1, 8),
        end: DateTime(2026, 6, 1, 8),
      );
      expect(zero.duration, Duration.zero);
    });

    test('spansMidnight is true only across a calendar-day boundary', () {
      expect(
        _onDay1(id: 's', caregiverId: 'c1', fromHour: 9, toHour: 17)
            .spansMidnight,
        isFalse,
      );
      final CareShift overnight = _shift(
        id: 's',
        caregiverId: 'c1',
        start: DateTime(2026, 6, 1, 22),
        end: DateTime(2026, 6, 2, 6),
      );
      expect(overnight.spansMidnight, isTrue);
    });

    test('round-trips through JSON', () {
      final CareShift shift = _shift(
        id: 's1',
        caregiverId: 'c1',
        start: DateTime.utc(2026, 6, 1, 8),
        end: DateTime.utc(2026, 6, 1, 16),
        notes: 'Lunch is in the fridge.',
      );
      expect(CareShift.fromJson(shift.toJson()), shift);
    });
  });

  group('gapsFor — coverage math', () {
    test('an empty day is one full-day gap', () {
      final List<DayInterval> gaps = gapsFor(const <CareShift>[], _day1);
      expect(gaps, hasLength(1));
      expect(gaps.single.start, _day1);
      expect(gaps.single.end, _day1.add(const Duration(days: 1)));
      expect(gaps.single.duration, const Duration(hours: 24));
    });

    test('a single mid-day shift leaves a leading + trailing gap', () {
      final List<DayInterval> gaps = gapsFor(
        <CareShift>[_onDay1(id: 's', caregiverId: 'c1', fromHour: 6, toHour: 8)],
        _day1,
      );
      expect(gaps, hasLength(2));
      // Leading 12am–6am, trailing 8am–12am.
      expect(gaps[0].start, _day1);
      expect(gaps[0].end, DateTime(2026, 6, 1, 6));
      expect(gaps[1].start, DateTime(2026, 6, 1, 8));
      expect(gaps[1].end, _day1.add(const Duration(days: 1)));
    });

    test('shifts that exactly tile the day leave no gap', () {
      final List<DayInterval> gaps = gapsFor(
        <CareShift>[
          _onDay1(id: 'a', caregiverId: 'c1', fromHour: 0, toHour: 12),
          _onDay1(id: 'b', caregiverId: 'c2', fromHour: 12, toHour: 24),
        ],
        _day1,
      );
      // Adjacent shifts (one ends exactly where the next begins) merge with
      // no gap at the boundary.
      expect(gaps, isEmpty);
    });

    test('a one-hour gap between two adjacent-ish shifts is found', () {
      final List<DayInterval> gaps = gapsFor(
        <CareShift>[
          _onDay1(id: 'a', caregiverId: 'c1', fromHour: 0, toHour: 6),
          _onDay1(id: 'b', caregiverId: 'c2', fromHour: 8, toHour: 24),
        ],
        _day1,
      );
      expect(gaps, hasLength(1));
      expect(gaps.single.start, DateTime(2026, 6, 1, 6));
      expect(gaps.single.end, DateTime(2026, 6, 1, 8));
      expect(gaps.single.duration, const Duration(hours: 2));
    });

    test('overlapping multi-caregiver shifts merge into one covered span',
        () {
      // 6–10 (c1) and 8–14 (c2) overlap 8–10; merged coverage is 6–14.
      final List<DayInterval> gaps = gapsFor(
        <CareShift>[
          _onDay1(id: 'a', caregiverId: 'c1', fromHour: 6, toHour: 10),
          _onDay1(id: 'b', caregiverId: 'c2', fromHour: 8, toHour: 14),
        ],
        _day1,
      );
      // Leading 12am–6am and trailing 2pm–12am only — no gap inside 6–14.
      expect(gaps, hasLength(2));
      expect(gaps[0].end, DateTime(2026, 6, 1, 6));
      expect(gaps[1].start, DateTime(2026, 6, 1, 14));
    });

    test('a shift fully containing another leaves the inner one no effect',
        () {
      final List<DayInterval> gaps = gapsFor(
        <CareShift>[
          _onDay1(id: 'outer', caregiverId: 'c1', fromHour: 6, toHour: 18),
          _onDay1(id: 'inner', caregiverId: 'c2', fromHour: 9, toHour: 12),
        ],
        _day1,
      );
      expect(gaps, hasLength(2));
      expect(gaps[0].end, DateTime(2026, 6, 1, 6));
      expect(gaps[1].start, DateTime(2026, 6, 1, 18));
    });

    test('a midnight-spanning shift only covers its in-day slice', () {
      // 10pm on day 1 → 6am on day 2: covers 10pm–12am of day 1 and
      // 12am–6am of day 2.
      final CareShift overnight = _shift(
        id: 's',
        caregiverId: 'c1',
        start: DateTime(2026, 6, 1, 22),
        end: DateTime(2026, 6, 2, 6),
      );

      final List<DayInterval> day1Gaps = gapsFor(<CareShift>[overnight], _day1);
      // Day 1: covered 10pm–12am, so the gap is 12am–10pm.
      expect(day1Gaps, hasLength(1));
      expect(day1Gaps.single.start, _day1);
      expect(day1Gaps.single.end, DateTime(2026, 6, 1, 22));

      final List<DayInterval> day2Gaps =
          gapsFor(<CareShift>[overnight], DateTime(2026, 6, 2));
      // Day 2: covered 12am–6am, so the gap is 6am–12am.
      expect(day2Gaps, hasLength(1));
      expect(day2Gaps.single.start, DateTime(2026, 6, 2, 6));
      expect(day2Gaps.single.end, DateTime(2026, 6, 3));
    });
  });

  group('coverageFor — day summary', () {
    test('counts distinct caregivers touching the day', () {
      final DayCoverage coverage = coverageFor(
        <CareShift>[
          _onDay1(id: 'a', caregiverId: 'c1', fromHour: 0, toHour: 8),
          _onDay1(id: 'b', caregiverId: 'c2', fromHour: 8, toHour: 16),
          // Same caregiver twice → still one distinct caregiver.
          _onDay1(id: 'c', caregiverId: 'c1', fromHour: 16, toHour: 24),
        ],
        _day1,
      );
      expect(coverage.caregiverCount, 2);
      expect(coverage.isFullyCovered, isTrue);
      expect(coverage.uncovered, Duration.zero);
    });

    test('shifts on other days are excluded from the day', () {
      final DayCoverage coverage = coverageFor(
        <CareShift>[
          _onDay1(id: 'a', caregiverId: 'c1', fromHour: 6, toHour: 14),
          _shift(
            id: 'other-day',
            caregiverId: 'c2',
            start: DateTime(2026, 6, 5, 6),
            end: DateTime(2026, 6, 5, 14),
          ),
        ],
        _day1,
      );
      expect(coverage.shifts.map((CareShift s) => s.id), <String>['a']);
      expect(coverage.uncovered, const Duration(hours: 16));
    });
  });

  group('CareShiftsRepository — CRUD', () {
    late CareblazersDatabase db;
    late CareShiftsRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = CareShiftsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('shift round-trips through the payload blob', () async {
      await repo.upsertShift(_onDay1(
        id: 's1',
        caregiverId: 'c1',
        fromHour: 9,
        toHour: 17,
      ));

      final CareShift? loaded = await repo.getShift('s1');
      expect(loaded, isNotNull);
      expect(loaded!.caregiverId, 'c1');
      expect(loaded.start, DateTime(2026, 6, 1, 9));
      expect(loaded.end, DateTime(2026, 6, 1, 17));
    });

    test('listShifts orders by start time', () async {
      await repo.upsertShift(_onDay1(
        id: 'late',
        caregiverId: 'c1',
        fromHour: 16,
        toHour: 24,
      ));
      await repo.upsertShift(_onDay1(
        id: 'early',
        caregiverId: 'c2',
        fromHour: 0,
        toHour: 8,
      ));

      final List<CareShift> all = await repo.listShifts();
      expect(all.map((CareShift s) => s.id), <String>['early', 'late']);
    });

    test('deleteShift removes the row; wipeAll truncates the table', () async {
      await repo.upsertShift(
          _onDay1(id: 's1', caregiverId: 'c1', fromHour: 0, toHour: 8));
      await repo.deleteShift('s1');
      expect(await repo.getShift('s1'), isNull);

      await repo.upsertShift(
          _onDay1(id: 's2', caregiverId: 'c1', fromHour: 0, toHour: 8));
      await db.wipeAll();
      expect(await repo.listShifts(), isEmpty);
    });
  });

  group('CareShifts notifier + shiftWeek', () {
    late CareblazersDatabase db;
    late CareShiftsRepository repo;
    final DateTime clock = DateTime(2026, 6, 1, 12);

    ProviderContainer makeContainer() {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          careShiftsRepositoryProvider.overrideWithValue(repo),
          careShiftsClockProvider.overrideWithValue(() => clock),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = CareShiftsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('addShift lands a shift; removeShift drops it', () async {
      final ProviderContainer container = makeContainer();
      await container.read(careShiftsProvider.future);

      await container.read(careShiftsProvider.notifier).addShift(
            _onDay1(id: 's1', caregiverId: 'c1', fromHour: 9, toHour: 17),
          );
      expect(await container.read(careShiftsProvider.future), hasLength(1));

      await container.read(careShiftsProvider.notifier).removeShift('s1');
      expect(await container.read(careShiftsProvider.future), isEmpty);
    });

    test('shiftWeek yields 7 days starting today, folding in coverage',
        () async {
      await repo.upsertShift(
          _onDay1(id: 's1', caregiverId: 'c1', fromHour: 6, toHour: 8));
      final ProviderContainer container = makeContainer();

      final List<DayCoverage> week =
          await container.read(shiftWeekProvider.future);

      expect(week, hasLength(7));
      // First day is today (the clock's calendar day), and it carries the
      // single mid-day shift with two surrounding gaps.
      expect(week.first.day, DateTime(2026, 6, 1));
      expect(week.first.gaps, hasLength(2));
      // The remaining days are uncovered (one full-day gap each).
      expect(week.last.day, DateTime(2026, 6, 7));
      expect(week.last.shifts, isEmpty);
      expect(week.last.gaps.single.duration, const Duration(hours: 24));
    });
  });
}
