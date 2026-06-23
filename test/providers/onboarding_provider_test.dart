import 'package:holdclose/providers/onboarding_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the alpha bug "intro screen shows on every launch": the
/// onboarding-complete flag must now PERSIST across launches, not reset to
/// false in memory each time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('readOnboardingCompleted round-trips the persisted flag', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await readOnboardingCompleted(), isFalse);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(onboardingCompletedPrefsKey, true);
    expect(await readOnboardingCompleted(), isTrue);
  });

  test('provider starts from the preloaded initial value', () {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        onboardingInitialProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(onboardingCompletedProvider), isTrue);
  });

  test('defaults to false (first launch) when nothing is preloaded', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(onboardingCompletedProvider), isFalse);
  });

  test('complete() flips state and persists for the next launch', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(onboardingCompletedProvider), isFalse);
    container.read(onboardingCompletedProvider.notifier).complete();
    // In-memory flip is synchronous.
    expect(container.read(onboardingCompletedProvider), isTrue);

    // _persist() is fire-and-forget; give it a beat to land, then a fresh
    // launch (readOnboardingCompleted) must see it.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await readOnboardingCompleted(), isTrue);
  });
}
