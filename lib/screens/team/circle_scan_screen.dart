import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../models/forum.dart';
import '../../services/circle_invite_link.dart';
import '../../services/forum_api_client.dart';
import '../../services/sync_service.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// "Scan to add" screen (care-circle connect, 2026-06-06) at
/// `/team/circle/scan`.
///
/// Reads a QR with [MobileScanner], parses the
/// `holdclose:circle:<token>` payload, redeems it via
/// `POST /circles/join`, and shows success (joined <circle name>) or a
/// friendly expired / invalid message.
///
/// The live camera sits behind [enableCamera] (default true). Widget
/// tests pass `enableCamera: false` and drive the parse + join path
/// through [debugHandlePayload] so no real camera is instantiated — the
/// same seam shape the feedback overlay uses for its capture override.
class CircleScanScreen extends ConsumerStatefulWidget {
  const CircleScanScreen({super.key, this.enableCamera = true});

  /// When false, the [MobileScanner] widget is replaced with a static
  /// placeholder so the test environment never opens a real camera.
  final bool enableCamera;

  static const Key statusKey = Key('circle-scan-status');
  static const Key scannerKey = Key('circle-scan-scanner');
  static const Key placeholderKey = Key('circle-scan-placeholder');

  @override
  ConsumerState<CircleScanScreen> createState() => _CircleScanScreenState();
}

/// What the scan surface is currently showing.
enum _ScanPhase { scanning, joining, joined, error }

class _CircleScanScreenState extends ConsumerState<CircleScanScreen> {
  _ScanPhase _phase = _ScanPhase.scanning;
  String _message = '';
  // Guards against the scanner firing onDetect repeatedly while a join
  // is already in flight or has resolved.
  bool _handled = false;

  /// Parse a scanned payload + join the circle. Public for widget tests
  /// (the camera seam is off there, so this is how the scan path is
  /// exercised).
  @visibleForTesting
  Future<void> debugHandlePayload(String? raw) => _handlePayload(raw);

  Future<void> _handlePayload(String? raw) async {
    if (_handled) return;
    final String? token = _parseToken(raw);
    if (token == null) {
      setState(() {
        _phase = _ScanPhase.error;
        _message = "That doesn't look like a care-circle code.";
      });
      return;
    }
    _handled = true;
    // Same consent gate as the deep-link path (2026-06-11): a scanned
    // code re-binds this device's circle and starts syncing care data
    // with its members — never join without an explicit yes.
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('circle_scan_confirm_dialog'),
        title: const Text('Join this care circle?'),
        content: const Text(
          'Joining shares caregiving with this circle’s members — '
          'schedules, medications, journal entries, and documents sync '
          'between you. Only join a circle from someone you know and '
          'trust.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('circle_scan_confirm_cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const Key('circle_scan_confirm_accept'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Join circle'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      // Declined — go back to scanning (a different code may be next).
      setState(() => _handled = false);
      return;
    }
    setState(() {
      _phase = _ScanPhase.joining;
      _message = 'Joining…';
    });
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      final CircleDto circle = await client.joinCircle(token);
      // Server-authoritative sync: adopt the circle's shared loved one +
      // pull the rest of the shared data so this device sees the same
      // person (and Stage 2 meds). FIRE-AND-FORGET + best-effort — the
      // join already succeeded server-side, so we never block the success
      // UI on the follow-up sync (adoptJoinedCircle swallows its own
      // errors and bootstrap retries on the next launch/tick).
      try {
        unawaited(ref.read(syncControllerProvider).adoptJoinedCircle(circle));
      } catch (_) {
        // Join already succeeded server-side; sync retries on next tick.
      }
      if (!mounted) return;
      setState(() {
        _phase = _ScanPhase.joined;
        _message = 'Joined ${circle.name}.';
      });
    } on ForumApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _ScanPhase.error;
        _handled = false;
        _message = switch (e.error) {
          'invite_expired' => 'That invite has expired. Ask for a new code.',
          'invite_not_found' => "That invite isn't valid anymore.",
          'invite_used' =>
            'That invite has already been used. Ask for a new code.',
          _ => "We couldn't join that circle. Please try again.",
        };
      });
    }
  }

  /// Extract the token from a `holdclose:circle:<token>` payload (or the
  /// link-style `holdclose://join/<token>`), or null if it isn't one of
  /// ours / is empty. Shares [parseCircleInviteTokenFromString] with the
  /// deep-link receiver so both channels parse identically.
  static String? _parseToken(String? raw) =>
      parseCircleInviteTokenFromString(raw);

  void _onDetect(BarcodeCapture capture) {
    if (capture.barcodes.isEmpty) return;
    _handlePayload(capture.barcodes.first.rawValue);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

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
                PathHeaderCrumb(label: 'Scan'),
              ],
              title: 'Scan to add',
              backLabel: 'Back to Care Circle',
              leadingIcon: Icons.qr_code_scanner,
            ),
            const SizedBox(height: 8),
            Text(
              "Point your camera at another caregiver's QR code to join "
              'their care circle.',
              style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
            ),
            const SizedBox(height: 20),
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: _phase == _ScanPhase.scanning
                    ? _scannerSurface()
                    : _resultSurface(textTheme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scannerSurface() {
    if (!widget.enableCamera) {
      return ColoredBox(
        key: CircleScanScreen.placeholderKey,
        color: context.hc.surfaceWarm,
        child: Center(
          child: Icon(
            Icons.qr_code_scanner,
            size: 64,
            color: context.hc.primarySoft,
          ),
        ),
      );
    }
    return MobileScanner(
      key: CircleScanScreen.scannerKey,
      onDetect: _onDetect,
    );
  }

  Widget _resultSurface(TextTheme textTheme) {
    final bool ok = _phase == _ScanPhase.joined;
    final bool busy = _phase == _ScanPhase.joining;
    return ColoredBox(
      color: context.hc.surfaceWarm,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (busy)
                const CircularProgressIndicator()
              else
                Icon(
                  ok ? Icons.check_circle : Icons.error_outline,
                  size: 56,
                  color: ok ? context.hc.link : context.hc.cta,
                ),
              const SizedBox(height: 16),
              Text(
                _message,
                key: CircleScanScreen.statusKey,
                textAlign: TextAlign.center,
                style: textTheme.bodyLarge?.copyWith(
                  color: context.hc.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_phase == _ScanPhase.error) ...<Widget>[
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: () => setState(() {
                    _phase = _ScanPhase.scanning;
                    _message = '';
                  }),
                  child: const Text('Scan again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
