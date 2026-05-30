import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'guidelines_acknowledged_provider.g.dart';

/// SharedPreferences key holding the one-shot "user has read the
/// community guidelines" bool (BUILD_SPEC.md §13 / Phase 13.12).
/// Persisted so the acknowledgement modal opens at most once per
/// install — caregivers who tap-back after acknowledging shouldn't get
/// re-prompted on the second post.
const String guidelinesAcknowledgedPrefsKey =
    'careblazers.community.guidelines_acknowledged.v1';

/// One-shot bool tracking whether the caregiver has acknowledged the
/// community guidelines (BUILD_SPEC.md §13 / Phase 13.12). Phase 13.12's
/// compose screen reads this on submit — `false` opens the modal and
/// blocks `createPost` until the caregiver taps "I've read them"; `true`
/// short-circuits past the modal and posts directly.
///
/// Tests inject mock prefs via
/// `SharedPreferences.setMockInitialValues({...})` before pumping —
/// the platform plugin's standard test entry point — so the notifier
/// stays single-source-of-truth for the persisted bool without
/// dragging a wrapper provider into the dep graph.
@Riverpod(keepAlive: true)
class GuidelinesAcknowledged extends _$GuidelinesAcknowledged {
  @override
  Future<bool> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(guidelinesAcknowledgedPrefsKey) ?? false;
  }

  /// Flip the persisted flag to `true` and surface the new value to
  /// every consumer. Idempotent — a second call is a no-op except for
  /// the redundant prefs write (cheap, no contention).
  Future<void> markAcknowledged() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(guidelinesAcknowledgedPrefsKey, true);
    state = const AsyncValue<bool>.data(true);
  }
}
