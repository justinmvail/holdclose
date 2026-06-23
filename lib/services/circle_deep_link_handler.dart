import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/forum.dart';
import '../providers/auth_provider.dart';
import 'circle_invite_link.dart';
import 'forum_api_client.dart';
import 'sync_service.dart';

/// Outcome of processing an incoming care-circle invite link, so the UI
/// layer (app.dart's listener) can show the right SnackBar / navigation
/// without owning the join logic.
sealed class CircleJoinOutcome {
  const CircleJoinOutcome();
}

/// We weren't signed in yet — the token was stashed and will be processed
/// once sign-in completes. No SnackBar; the join happens later.
class CircleJoinStashed extends CircleJoinOutcome {
  const CircleJoinStashed();
}

/// The link carries a valid-looking invite token and the caregiver is
/// signed in — but joining is GATED on explicit consent. The UI must ask
/// ("Join this care circle?") and only then call
/// [CircleDeepLinkHandler.confirmJoin] with [token]. Nothing has been
/// sent to the backend yet; dismissing the prompt abandons the token.
///
/// This gate is the defense against a tapped `holdclose://join/<x>`
/// link silently re-binding the device to an attacker's circle (which
/// would sync the caregiver's data to strangers). No join without a yes.
class CircleJoinConfirmationRequired extends CircleJoinOutcome {
  const CircleJoinConfirmationRequired(this.token);
  final String token;
}

/// The link didn't carry one of our tokens (ignored, no UI).
class CircleJoinNotALink extends CircleJoinOutcome {
  const CircleJoinNotALink();
}

/// Successfully joined [circle]; navigate to the Care Circle screen + show
/// "Joined <name>".
class CircleJoinSucceeded extends CircleJoinOutcome {
  const CircleJoinSucceeded(this.circle);
  final CircleDto circle;
}

/// The invite was invalid / expired (or transport failed); show [message],
/// no crash, no navigation.
class CircleJoinFailed extends CircleJoinOutcome {
  const CircleJoinFailed(this.message);
  final String message;
}

/// Processes care-circle invite deep links (`holdclose://join/<token>` and
/// the QR-style `holdclose:circle:<token>`). Pure of any widget/navigation
/// concerns — it parses + joins + adopts and returns a [CircleJoinOutcome];
/// the caller drives the SnackBar + navigation. This is the testable seam:
/// widget tests + unit tests inject a fake [ForumApiClient] and assert the
/// outcome without a real backend or navigator.
class CircleDeepLinkHandler {
  CircleDeepLinkHandler(this._ref);

  final Ref _ref;

  /// A token captured while signed out, replayed once the caller observes a
  /// sign-in. Null when nothing is pending.
  String? _pendingToken;

  /// Whether a token is waiting for sign-in.
  bool get hasPending => _pendingToken != null;

  /// Handle a raw incoming URI string (from app_links cold-start or stream).
  /// Returns the outcome so the caller can react. Never throws.
  Future<CircleJoinOutcome> handleUri(String? raw) async {
    final String? token = parseCircleInviteTokenFromString(raw);
    if (token == null) return const CircleJoinNotALink();
    return handleToken(token);
  }

  /// Handle a parsed invite [token]: stash it when signed out, otherwise
  /// ask the UI to CONFIRM before any join happens. Never throws, never
  /// joins on its own — redemption only occurs through [confirmJoin].
  Future<CircleJoinOutcome> handleToken(String token) async {
    if (!await _isSignedIn()) {
      _pendingToken = token;
      return const CircleJoinStashed();
    }
    return CircleJoinConfirmationRequired(token);
  }

  /// Replay a stashed token after sign-in completes. No-op (returns null)
  /// when nothing is pending. Like the live path, this only surfaces the
  /// confirmation request — the join still waits for an explicit yes.
  Future<CircleJoinOutcome?> processPending() async {
    final String? token = _pendingToken;
    if (token == null) return null;
    _pendingToken = null;
    return CircleJoinConfirmationRequired(token);
  }

  Future<bool> _isSignedIn() async {
    try {
      final AuthState state =
          await _ref.read(authProvider).watchAuthState().first;
      return state is AuthStateSignedIn;
    } catch (_) {
      // If we can't determine auth, treat as signed out + stash so the
      // token isn't lost — it replays on the next explicit process call.
      return false;
    }
  }

  /// Redeem [token] after the caregiver explicitly confirmed the join in
  /// the UI. This is the ONLY path that talks to the backend.
  Future<CircleJoinOutcome> confirmJoin(String token) async {
    final ForumApiClient client = _ref.read(forumApiClientProvider);
    try {
      final CircleDto circle = await client.joinCircle(token);
      // Server-authoritative sync: adopt the shared loved one + pull the
      // rest. Best-effort, fire-and-forget — the join already succeeded
      // server-side, so we never block success on the follow-up sync. The
      // adopt step is read through [circleAdoptProvider] so tests can
      // stub it without standing up the whole SyncController graph.
      try {
        unawaited(_ref.read(circleAdoptProvider)(circle));
      } catch (_) {
        // Join already succeeded; sync retries on the next tick.
      }
      return CircleJoinSucceeded(circle);
    } on ForumApiException catch (e) {
      return CircleJoinFailed(switch (e.error) {
        'invite_expired' => 'That invite has expired. Ask for a new link.',
        'invite_not_found' => "That invite isn't valid anymore.",
        'invite_used' =>
          'That invite has already been used. Ask for a new link.',
        _ => "We couldn't join that circle. Please try again.",
      });
    } catch (_) {
      return const CircleJoinFailed(
        "We couldn't join that circle. Please try again.",
      );
    }
  }
}

/// Adopt seam for a freshly-joined circle (server-authoritative sync).
/// Defaults to [SyncController.adoptJoinedCircle]; tests override this with
/// a recording closure so the deep-link handler can be exercised without
/// constructing the full SyncController (drift db + every repository).
final circleAdoptProvider = Provider<Future<void> Function(CircleDto)>(
  (Ref ref) =>
      (CircleDto circle) => ref.read(syncControllerProvider).adoptJoinedCircle(
            circle,
          ),
);

/// App-wide handler instance. `keepAlive` so a stashed token survives the
/// rebuilds between a cold-start link and a later sign-in.
final circleDeepLinkHandlerProvider = Provider<CircleDeepLinkHandler>(
  (Ref ref) => CircleDeepLinkHandler(ref),
);
