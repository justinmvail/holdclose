import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/forum.dart';
import '../../providers/my_forum_profile_provider.dart';
import '../../providers/sync_state_provider.dart';
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// QR payload scheme for a circle invite (care-circle connect,
/// 2026-06-06). The token is wrapped so [CircleScanScreen] can validate
/// that a scanned code is one of ours before redeeming it.
const String circleQrScheme = 'careblazers:circle:';

/// Build the QR payload for an invite [token].
String circleQrPayload(String token) => '$circleQrScheme$token';

/// "Show my QR" screen (care-circle connect, 2026-06-06) at
/// `/team/circle/qr`.
///
/// Ensures the caller owns a circle (creates "<displayName>'s circle" if
/// they have none), mints an invite via `POST /circles/:id/invites`, and
/// renders the token as a scannable QR with a "valid for 7 days" caption
/// and the caller's @username.
class CircleQrScreen extends ConsumerStatefulWidget {
  const CircleQrScreen({super.key});

  static const Key qrKey = Key('circle-qr-image');
  static const Key errorKey = Key('circle-qr-error');
  static const Key retryKey = Key('circle-qr-retry');

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
      backgroundColor: context.cb.background,
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
              style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
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
                return _QrBlock(
                  invite: snapshot.data!,
                  username: username,
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
  const _QrBlock({required this.invite, required this.username});

  final CircleInviteDto invite;
  final String? username;

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
            border: Border.all(color: context.cb.surfaceWarm, width: 2),
          ),
          child: QrImageView(
            key: CircleQrScreen.qrKey,
            data: circleQrPayload(invite.token),
            size: 240,
            backgroundColor: Colors.white,
            eyeStyle: QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: context.cb.primary,
            ),
            dataModuleStyle: QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: context.cb.primary,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (username != null)
          Text(
            '@$username',
            style: textTheme.titleLarge?.copyWith(
              color: context.cb.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'This code is valid for 7 days.',
          style: textTheme.bodyMedium?.copyWith(
            color: context.cb.primarySoft,
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
        Icon(Icons.wifi_off, size: 48, color: context.cb.primarySoft),
        const SizedBox(height: 16),
        Text(
          "We couldn't create your QR code. Check your connection and try "
          'again.',
          style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
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
