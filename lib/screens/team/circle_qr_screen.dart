import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/forum.dart';
import '../../providers/my_forum_profile_provider.dart';
import '../../providers/share_provider.dart';
import '../../providers/sync_state_provider.dart';
import '../../services/circle_invite_link.dart';
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// QR payload scheme for a circle invite (care-circle connect,
/// 2026-06-06). The token is wrapped so [CircleScanScreen] can validate
/// that a scanned code is one of ours before redeeming it.
const String circleQrScheme = 'holdclose:circle:';

/// Build the QR payload for an invite [token].
String circleQrPayload(String token) => '$circleQrScheme$token';

/// "Show my QR" screen (care-circle connect, 2026-06-06) at
/// `/team/circle/qr`.
///
/// Ensures the caller owns a circle (creates "<displayName>'s circle" if
/// they have none), mints an invite via `POST /circles/:id/invites`, and
/// renders the token as a scannable QR with a "valid for 2 days" caption
/// and the caller's @username. A secondary "Share link" action under the
/// QR shares the Worker's public `/join/<token>` landing URL for the
/// no-camera / not-in-the-room case (tester fb_1780873144169986).
class CircleQrScreen extends ConsumerStatefulWidget {
  const CircleQrScreen({super.key});

  static const Key qrKey = Key('circle-qr-image');
  static const Key errorKey = Key('circle-qr-error');
  static const Key retryKey = Key('circle-qr-retry');
  static const Key shareLinkKey = Key('circle-qr-share-link');

  @override
  ConsumerState<CircleQrScreen> createState() => _CircleQrScreenState();
}

class _CircleQrScreenState extends ConsumerState<CircleQrScreen> {
  Future<CircleInviteDto>? _invite;

  @override
  void initState() {
    super.initState();
    _invite = _ensureInvite();
  }

  Future<CircleInviteDto> _ensureInvite() async {
    final ForumApiClient client = ref.read(forumApiClientProvider);
    final List<CircleDto> circles = await client.listCircles();
    final CircleDto circle;
    if (circles.isEmpty) {
      final ForumProfile me = await ref.read(myForumProfileProvider.future);
      circle = await client.createCircle(circleNameForOwner(me));
    } else {
      circle = circles.first;
    }
    // Server-authoritative sync: bind this as the active circle id so the
    // rest of the app syncs through the same circle the invite points at.
    // FIRE-AND-FORGET + best-effort so it can never block/hang the invite
    // resolution — a failure just leaves binding to the next bootstrap.
    unawaited(_bindCircle(circle.id));
    return client.createInvite(circle.id);
  }

  Future<void> _bindCircle(String circleId) async {
    try {
      await ref.read(syncStateStoreProvider).setCircleId(circleId);
    } catch (_) {
      // Non-fatal — bootstrap re-resolves the active circle on next launch.
    }
  }

  void _retry() => setState(() => _invite = _ensureInvite());

  /// Share the HTTPS `/join/<token>` landing URL (it opens in a plain
  /// browser for someone WITHOUT the app — the page bounces into the
  /// `holdclose://join` deep link, and the join itself still requires the
  /// in-app confirmation). Invites are SINGLE-USE, so this mints a FRESH
  /// token per tap rather than reusing [displayed] — otherwise whichever
  /// channel got redeemed first would burn the code still on screen
  /// (same per-tap semantics as the roster's "Invite by link").
  Future<void> _shareLink(CircleInviteDto displayed) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ForumApiClient client = ref.read(forumApiClientProvider);
    // No real backend origin = no shareable URL. Degrade calmly rather
    // than sharing a dead, relative link (local-only / demo builds).
    if (client.baseUrl.trim().isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Connect to share an invite link. Have them scan your QR '
            'instead.',
          ),
        ),
      );
      return;
    }
    try {
      final CircleInviteDto invite =
          await client.createInvite(displayed.circleId);
      final String link = circleInviteLink(
        origin: client.baseUrl,
        token: invite.token,
      );
      await ref
          .read(sharerProvider)
          .share('Join my care circle on Holdclose: $link');
    } on ForumApiException catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "We couldn't create your invite link. Please try again.",
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AsyncValue<ForumProfile> profile =
        ref.watch(myForumProfileProvider);
    final String? username = profile.maybeWhen(
      data: (ForumProfile p) => p.username,
      orElse: () => null,
    );

    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: <Widget>[
            const PathHeader(
              breadcrumbs: <PathHeaderCrumb>[
                PathHeaderCrumb(label: 'Home', route: '/'),
                PathHeaderCrumb(label: 'Care Circle', route: '/team'),
                PathHeaderCrumb(label: 'Care Circle', route: '/team/circle'),
                PathHeaderCrumb(label: 'My QR'),
              ],
              title: 'Show my QR',
              backLabel: 'Back to Care Circle',
              leadingIcon: Icons.qr_code_2,
            ),
            const SizedBox(height: 8),
            Text(
              'Have another caregiver scan this to join your care circle.',
              style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
            ),
            const SizedBox(height: 28),
            FutureBuilder<CircleInviteDto>(
              future: _invite,
              builder: (BuildContext context,
                  AsyncSnapshot<CircleInviteDto> snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError || !snapshot.hasData) {
                  return _ErrorBlock(onRetry: _retry);
                }
                final CircleInviteDto invite = snapshot.data!;
                return _QrBlock(
                  invite: invite,
                  username: username,
                  onShareLink: () => _shareLink(invite),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _QrBlock extends StatelessWidget {
  const _QrBlock({
    required this.invite,
    required this.username,
    required this.onShareLink,
  });

  final CircleInviteDto invite;
  final String? username;
  final VoidCallback onShareLink;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.hc.surfaceWarm, width: 2),
          ),
          child: QrImageView(
            key: CircleQrScreen.qrKey,
            data: circleQrPayload(invite.token),
            size: 240,
            backgroundColor: Colors.white,
            eyeStyle: QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: context.hc.primary,
            ),
            dataModuleStyle: QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: context.hc.primary,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (username != null)
          Text(
            '@$username',
            style: textTheme.titleLarge?.copyWith(
              color: context.hc.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'This code is valid for 2 days.',
          style: textTheme.bodyMedium?.copyWith(
            color: context.hc.primarySoft,
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          key: CircleQrScreen.shareLinkKey,
          onPressed: onShareLink,
          icon: const Icon(Icons.ios_share, size: 18),
          label: const Text('Share link'),
        ),
        const SizedBox(height: 8),
        Text(
          "Can't scan? Send a link they can tap to join instead.",
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(
            color: context.hc.primarySoft,
          ),
        ),
      ],
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      key: CircleQrScreen.errorKey,
      children: <Widget>[
        const SizedBox(height: 24),
        Icon(Icons.wifi_off, size: 48, color: context.hc.primarySoft),
        const SizedBox(height: 16),
        Text(
          "We couldn't create your QR code. Check your connection and try "
          'again.',
          style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        OutlinedButton(
          key: CircleQrScreen.retryKey,
          onPressed: onRetry,
          child: const Text('Try again'),
        ),
      ],
    );
  }
}
