import 'package:careblazers/db/database.dart';
import 'package:careblazers/providers/forum_post_cache_provider.dart';
import 'package:drift/native.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Override the forum-post cache repository with an in-memory database so a
/// widget/golden test that mounts the (local-first) community feed never opens
/// the real on-disk DB — which, unmocked, hangs `pumpAndSettle` on path
/// resolution. Add this to the test's ProviderScope overrides.
Override forumPostCacheTestOverride() =>
    forumPostCacheRepositoryProvider.overrideWithValue(
      ForumPostCacheRepository(CareblazersDatabase(NativeDatabase.memory())),
    );
