import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'onboarding_provider.g.dart';

/// SharedPreferences key for the persisted onboarding-complete flag.
const String onboardingCompletedPrefsKey = 'holdclose.onboarding_completed';

/// The startup value for [OnboardingCompleted], overridden in `main()`
/// with the persisted flag so a returning caregiver doesn't see the
/// welcome carousel flash before an async hydrate snaps it true. Defaults
/// false (first launch, and tests that don't override it).
final Provider<bool> onboardingInitialProvider =
    Provider<bool>((Ref ref) => false);

/// Read the persisted onboarding-complete flag. Call in `main()` before
/// `runApp` and feed the result into [onboardingInitialProvider].
Future<bool> readOnboardingCompleted() async {
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(onboardingCompletedPrefsKey) ?? false;
  } catch (_) {
    return false;
  }
}

/// "Has the caregiver finished the welcome carousel?" (BUILD_SPEC.md §5.11).
///
/// Flipped true by the carousel's "Get started" CTA on page 3 and read by
/// the `go_router` redirect so the welcome flow is skipped on subsequent
/// launches. The flip now **persists** across launches via
/// SharedPreferences (the alpha bug "intro screen shows on every launch"
/// — it was in-memory only before); the startup value comes from
/// [onboardingInitialProvider], preloaded in `main()`.
///
/// `keepAlive: true` so the flip survives screen rebuilds within the
/// session (the carousel pops itself once the user signs in, so a
/// non-keepAlive notifier would lose the value the moment it routes).
@Riverpod(keepAlive: true)
class OnboardingCompleted extends _$OnboardingCompleted {
  @override
  bool build() => ref.read(onboardingInitialProvider);

  /// Mark onboarding finished + persist so subsequent launches skip the
  /// welcome carousel. Called from the carousel's "Get started" CTA on the
  /// third page — the same press also navigates to `/sign-in`.
  void complete() {
    state = true;
    _persist();
  }

  /// Best-effort persistence — a missing platform channel in a unit test
  /// must never crash the flip.
  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(onboardingCompletedPrefsKey, true);
    } catch (_) {
      // Swallowed: the in-memory flip already happened for this session.
    }
  }
}
