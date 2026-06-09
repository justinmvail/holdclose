import 'package:flutter/material.dart';

import '../services/forum_api_client.dart' show ForumApiException;
import '../theme.dart';

/// Shared "we couldn't reach the network" failure surface (#19 — offline /
/// network-error resilience).
///
/// Every network-dependent surface that can blank-screen on an unreachable
/// backend (the community feed, the post detail) renders this instead of an
/// empty list or a thrown exception: a soft cloud-off glyph, a branded
/// headline the caller supplies, a one-line plain-language detail, and a
/// salmon "Try again" button wired to [onRetry].
///
/// The copy intentionally avoids any "server / API / 500" framing — the
/// caregiver audience just needs to know it didn't connect and that tapping
/// retries. A *transport* failure (no response at all — DNS, TCP refused,
/// TLS, timeout; surfaced by [ForumApiException] with `statusCode == 0`)
/// swaps the generic detail for an explicit "check your connection" nudge
/// via [networkErrorDetail].
class NetworkErrorView extends StatelessWidget {
  const NetworkErrorView({
    super.key,
    required this.headline,
    required this.detail,
    required this.onRetry,
    this.retryButtonKey,
    this.retryLabel = 'Try again',
  });

  /// The branded, surface-specific headline — e.g. "We couldn't load the
  /// community feed." The caller owns this so each surface keeps its own
  /// voice; the widget owns the layout + the retry button.
  final String headline;

  /// One-line plain-language detail under the headline. Build it from
  /// [networkErrorDetail] so a transport failure reads "Check your
  /// connection and try again." rather than a raw exception string.
  final String detail;

  /// Re-runs the failed fetch. Async so the caller can hand its notifier's
  /// `refresh()` / `loadMore()` future straight through.
  final Future<void> Function() onRetry;

  /// Optional key on the retry button so a surface can target its own
  /// retry affordance in tests (the feed + detail screens already key
  /// their error *container*; this lets a test tap the button directly).
  final Key? retryButtonKey;

  /// Button label. Defaults to "Try again"; overridable for surfaces that
  /// want a verb closer to their domain.
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: context.cb.primarySoft,
            ),
            const SizedBox(height: 12),
            Text(
              headline,
              style: textTheme.bodyLarge?.copyWith(
                color: context.cb.text,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              style: textTheme.bodyMedium?.copyWith(
                color: context.cb.primarySoft,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Semantics(
              button: true,
              label: '$retryLabel. Reconnect and reload.',
              child: ElevatedButton(
                key: retryButtonKey,
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.cb.cta,
                  foregroundColor: Colors.white,
                ),
                onPressed: onRetry,
                child: Text(
                  retryLabel,
                  style: textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// True when [error] looks like a *transport* failure — the request never
/// reached the backend (no HTTP response at all). [ForumApiException] models
/// that as `statusCode == 0` (see `forum_api_client.dart` `_send`'s
/// `DioException` catch). Used to pick the "check your connection" copy.
bool isTransportError(Object? error) =>
    error is ForumApiException && error.statusCode == 0;

/// Caregiver-facing one-liner for the detail row under a [NetworkErrorView]
/// headline.
///
/// A transport failure (offline, DNS, refused, timeout) gets the actionable
/// "check your connection" nudge; any other failure (a 4xx/5xx the Worker
/// did answer with) falls back to a neutral "Something went wrong" — we
/// never dump a raw `ForumApiException(500, …)` at an exhausted caregiver.
String networkErrorDetail(Object? error) {
  if (isTransportError(error)) {
    return 'Check your connection and try again.';
  }
  return 'Something went wrong. Try again in a moment.';
}
