import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/forum.dart';
import '../services/forum_api_client.dart';

part 'my_forum_profile_provider.g.dart';

/// The signed-in caregiver's own [ForumProfile] (BUILD_SPEC.md §13 /
/// Phase 13.12 + 13.4). Fetched once per session via
/// `GET /profiles/me`; `keepAlive: true` so admin-tab visibility +
/// the post-compose author header don't re-fetch on every screen
/// mount.
///
/// First-load failures (404 → not bootstrapped yet) call
/// `POST /profiles/bootstrap` and try once more. Other errors surface
/// as an [AsyncValue.error] so the caller can decide whether to swallow
/// (admin gate → treat as non-admin) or surface (compose → block submit
/// with a retry).
@Riverpod(keepAlive: true)
class MyForumProfile extends _$MyForumProfile {
  @override
  Future<ForumProfile> build() async {
    final ForumApiClient client = ref.watch(forumApiClientProvider);
    try {
      return await client.getMyProfile();
    } on ForumApiException catch (e) {
      if (e.statusCode == 404) {
        return client.bootstrapProfile();
      }
      rethrow;
    }
  }

  /// Force a re-fetch — e.g. after a Settings → display-name update.
  Future<void> refresh() async {
    state = const AsyncValue<ForumProfile>.loading();
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      final ForumProfile next = await client.getMyProfile();
      state = AsyncValue<ForumProfile>.data(next);
    } catch (e, st) {
      state = AsyncValue<ForumProfile>.error(e, st);
    }
  }
}

/// Whether the signed-in caregiver is the forum admin (BUILD_SPEC.md
/// §13 / Phase 13.12). Synthesized from [myForumProfileProvider]:
/// `true` only when the profile loads cleanly AND `role == 'admin'`.
/// Errors and the loading state collapse to `false` — the admin
/// surfaces are additive and a momentary "is the user admin?" gap
/// should hide them rather than flicker them in.
@Riverpod(keepAlive: true)
bool isForumAdmin(Ref ref) {
  final AsyncValue<ForumProfile> profile = ref.watch(myForumProfileProvider);
  return profile.maybeWhen(
    data: (ForumProfile p) => p.role == 'admin',
    orElse: () => false,
  );
}

@visibleForTesting
const String forumAdminRole = 'admin';
