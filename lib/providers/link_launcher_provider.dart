import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

part 'link_launcher_provider.g.dart';

/// Outbound URL launcher (BUILD_SPEC.md §5.4 — decoder result's "Talk to
/// Natali" CTA; §5.8 — future library card share/help links).
///
/// Behind an interface so widget tests can override the riverpod
/// provider with [RecordingLinkLauncher] and assert what URL was passed
/// without the platform plugin firing. Production wires
/// [RealLinkLauncher] which calls into `url_launcher`.
abstract class LinkLauncher {
  /// Open [url] in whichever browser/app the OS prefers for that scheme.
  /// Resolves true when the platform reports a successful handoff.
  Future<bool> launch(Uri url);
}

/// Production `url_launcher`-backed [LinkLauncher].
///
/// Uses [url_launcher.LaunchMode.externalApplication] so https links open
/// in the system browser (Safari/Chrome) rather than an in-app web view.
/// The §5.4 spec says "in-app browser" — the platform default mode does
/// embed for HTTPS on iOS 16+, but routing to the external app is the
/// safer fallback for the v1 demo since the holdclose.com page hosts
/// its own video player which doesn't always reliably play inside
/// SFSafariViewController.
class RealLinkLauncher implements LinkLauncher {
  const RealLinkLauncher();

  @override
  Future<bool> launch(Uri url) {
    return url_launcher.launchUrl(
      url,
      mode: url_launcher.LaunchMode.externalApplication,
    );
  }
}

/// Records every [launch] call without firing a platform call. Used by
/// widget tests so they can assert the URL the decoder result screen
/// hands off when the caregiver taps "I need to talk to Natali".
class RecordingLinkLauncher implements LinkLauncher {
  RecordingLinkLauncher();

  final List<Uri> launched = <Uri>[];

  @override
  Future<bool> launch(Uri url) async {
    launched.add(url);
    return true;
  }
}

/// Riverpod-wired link launcher. Widgets read `ref.watch(linkLauncherProvider)`
/// and get whichever impl the host overrode (or the real one in
/// production). Kept alive so multiple consumers share a single instance.
@Riverpod(keepAlive: true)
LinkLauncher linkLauncher(Ref ref) => const RealLinkLauncher();
