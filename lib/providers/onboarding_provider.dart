import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'onboarding_provider.g.dart';

/// "Has the caregiver finished the welcome carousel?" (BUILD_SPEC.md §5.11).
///
/// Flipped true by the carousel's "Get started" CTA on page 3. Task 31
/// will read this in a `go_router` redirect so the welcome flow is
/// skipped on subsequent launches; in v1 the value lives in-memory only
/// — wiring it through [StorageProvider] for cross-launch persistence
/// is task 31's concern, not this task's.
///
/// `keepAlive: true` so the flip survives screen rebuilds within the
/// session (the carousel pops itself once the user signs in, so a
/// non-keepAlive notifier would lose the value the moment it routes).
@Riverpod(keepAlive: true)
class OnboardingCompleted extends _$OnboardingCompleted {
  @override
  bool build() => false;

  /// Mark onboarding finished. Called from the carousel's "Get started"
  /// CTA on the third page — the same press also navigates to `/sign-in`.
  void complete() {
    state = true;
  }
}
