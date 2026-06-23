import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/forum.dart';
import 'package:holdclose/providers/circle_member_cache_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HoldcloseDatabase db;
  late CircleMemberCacheRepository repo;

  DateTime clock() => DateTime(2026, 6, 10, 9);

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    repo = CircleMemberCacheRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  CircleMemberDto member(String id, String name, {String role = 'member'}) =>
      CircleMemberDto(
          profileId: id, displayName: name, role: role, username: id);

  test('starts empty', () async {
    expect(await repo.list(), isEmpty);
  });

  test('replaceForCircle caches + round-trips the roster', () async {
    await repo.replaceForCircle(
      'circle-1',
      <CircleMemberDto>[
        member('p1', 'Sarah', role: 'owner'),
        member('p2', 'David'),
      ],
      clock: clock,
    );

    final List<CircleMemberDto> got = await repo.list();
    expect(got, hasLength(2));
    expect(got.map((CircleMemberDto m) => m.displayName),
        containsAll(<String>['Sarah', 'David']));
    expect(got.any((CircleMemberDto m) => m.role == 'owner'), isTrue);
  });

  test('replaceForCircle replaces the prior roster (no stale rows)', () async {
    await repo.replaceForCircle('circle-1',
        <CircleMemberDto>[member('p1', 'Sarah'), member('p2', 'David')],
        clock: clock);
    await repo.replaceForCircle('circle-1',
        <CircleMemberDto>[member('p1', 'Sarah')],
        clock: clock);

    final List<CircleMemberDto> got = await repo.list();
    expect(got, hasLength(1));
    expect(got.single.displayName, 'Sarah');
  });

  test('watch() re-emits when the cache is rewritten', () async {
    final List<int> lengths = <int>[];
    final sub = repo.watch().listen((List<CircleMemberDto> m) {
      lengths.add(m.length);
    });
    await Future<void>.delayed(Duration.zero);
    await repo.replaceForCircle('c',
        <CircleMemberDto>[member('p1', 'A'), member('p2', 'B')], clock: clock);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(lengths.last, 2);
  });
}
