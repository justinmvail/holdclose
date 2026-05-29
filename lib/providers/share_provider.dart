import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

part 'share_provider.g.dart';

/// Outbound share-sheet handoff (BUILD_SPEC.md §5.8 — library card
/// detail AppBar share action).
///
/// Behind an interface so widget tests can override the riverpod
/// provider with [RecordingSharer] and assert the text + subject the
/// caller handed off, without the share_plus platform channel firing.
/// Mirrors the [LinkLauncher] surface — same shape, same test
/// affordance.
abstract class Sharer {
  /// Hand [text] to the platform share sheet. [subject] populates the
  /// email subject line when the caregiver picks Mail. Completes when
  /// the sheet closes — callers don't usually need the [ShareResult]
  /// payload, so the interface returns void.
  Future<void> share(String text, {String? subject});
}

/// Production `share_plus`-backed [Sharer]. Delegates to [Share.share]
/// and discards the [ShareResult] — we don't surface "user picked X"
/// in the UI yet, so swallowing the return keeps the interface void.
class RealSharer implements Sharer {
  const RealSharer();

  @override
  Future<void> share(String text, {String? subject}) async {
    await share_plus.Share.share(text, subject: subject);
  }
}

/// Records every [share] call without firing a platform call. Used by
/// widget tests so they can assert the AppBar share action's text +
/// subject without the share_plus method channel triggering.
class RecordingSharer implements Sharer {
  RecordingSharer();

  final List<({String text, String? subject})> shared =
      <({String text, String? subject})>[];

  @override
  Future<void> share(String text, {String? subject}) async {
    shared.add((text: text, subject: subject));
  }
}

/// Riverpod-wired sharer. Widgets read `ref.watch(sharerProvider)` and
/// get whichever impl the host overrode (or the real one in
/// production). Kept alive so multiple consumers share a single
/// instance.
@Riverpod(keepAlive: true)
Sharer sharer(Ref ref) => const RealSharer();
