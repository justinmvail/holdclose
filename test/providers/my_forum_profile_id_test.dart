import 'package:holdclose/models/forum.dart';
import 'package:holdclose/providers/my_forum_profile_provider.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Unit coverage for [myForumProfileIdProvider] — the ownership signal the
/// community surfaces gate their edit / delete affordances on. Synthesized
/// from [myForumProfileProvider] the same way [isForumAdminProvider] is:
/// the loaded profile's id when it resolves, null while it loads or errors
/// (so a momentary "who am I?" gap hides the owner controls rather than
/// flashing them onto someone else's content).

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

class _ProfileFake extends ForumApiClient {
  _ProfileFake({this.profileId = 'profile-me', this.error})
      : super(
          tokenLoader: _stub,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stub() async => 'fake-jwt';

  final String profileId;
  final Object? error;

  @override
  Future<ForumProfile> getMyProfile() async {
    if (error != null) throw error!;
    return ForumProfile(
      id: profileId,
      holdcloseUserId: 'cb-1',
      displayName: 'Me',
      joinedAt: _fixedNow.subtract(const Duration(days: 30)),
      role: 'user',
    );
  }
}

ProviderContainer _container(ForumApiClient client) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      forumApiClientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('myForumProfileIdProvider', () {
    test('is null while the profile is still loading', () {
      final ProviderContainer container = _container(_ProfileFake());
      // Synchronously, before the async profile fetch settles.
      expect(container.read(myForumProfileIdProvider), isNull);
    });

    test('resolves to the profile id once the fetch lands', () async {
      final ProviderContainer container =
          _container(_ProfileFake(profileId: 'profile-abc'));

      await container.read(myForumProfileProvider.future);

      expect(container.read(myForumProfileIdProvider), 'profile-abc');
    });

    test('stays null when the profile resolves to an error', () async {
      final ProviderContainer container = _container(
        _ProfileFake(error: ForumApiException(statusCode: 500, error: 'boom')),
      );

      // Pump microtasks until the async profile leaves its loading state,
      // then assert the id collapses to null on the error (mirrors how the
      // admin gate hides itself on a profile error). Bounded so a never-
      // settling build fails fast instead of hanging the suite.
      for (int i = 0; i < 50; i++) {
        if (!container.read(myForumProfileProvider).isLoading) break;
        await Future<void>.delayed(Duration.zero);
      }

      expect(container.read(myForumProfileProvider).hasError, isTrue);
      expect(container.read(myForumProfileIdProvider), isNull);
    });
  });
}
