import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/providers/forum_post_cache_provider.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

ForumPost _post(String id) => ForumPost(
      id: id,
      authorId: 'profile-$id',
      title: 'Post $id',
      body: 'Body $id',
      createdAt: DateTime.utc(2026, 5, 30, 12),
      updatedAt: DateTime.utc(2026, 5, 30, 12),
      voteCount: 0,
      hidden: false,
    );

void main() {
  late CareblazersDatabase db;
  late ForumPostCacheRepository repo;
  DateTime clock() => DateTime(2026, 6, 10, 9);

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    repo = ForumPostCacheRepository(db);
  });
  tearDown(() async => db.close());

  test('starts empty', () async {
    expect(await repo.firstPage(ForumPostSort.hot), isEmpty);
  });

  test('cacheFirstPage round-trips posts in server order', () async {
    await repo.cacheFirstPage(
      ForumPostSort.hot,
      <ForumPost>[_post('a'), _post('b'), _post('c')],
      clock: clock,
    );
    final List<ForumPost> got = await repo.firstPage(ForumPostSort.hot);
    expect(got.map((ForumPost p) => p.id).toList(), <String>['a', 'b', 'c']);
  });

  test('caches each sort independently', () async {
    await repo.cacheFirstPage(ForumPostSort.hot, <ForumPost>[_post('hot')],
        clock: clock);
    await repo.cacheFirstPage(ForumPostSort.top, <ForumPost>[_post('top')],
        clock: clock);

    expect((await repo.firstPage(ForumPostSort.hot)).single.id, 'hot');
    expect((await repo.firstPage(ForumPostSort.top)).single.id, 'top');
  });

  test('a re-cache replaces the prior page for that sort', () async {
    await repo.cacheFirstPage(
        ForumPostSort.hot, <ForumPost>[_post('a'), _post('b')],
        clock: clock);
    await repo.cacheFirstPage(ForumPostSort.hot, <ForumPost>[_post('c')],
        clock: clock);
    final List<ForumPost> got = await repo.firstPage(ForumPostSort.hot);
    expect(got.map((ForumPost p) => p.id).toList(), <String>['c']);
  });
}
