import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/forum.dart';
import '../../providers/circle_member_cache_provider.dart';
import '../../providers/my_forum_profile_provider.dart';
import '../../providers/sync_state_provider.dart';
import '../../services/circle_invite_link.dart';
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Share seam for the "Invite by link" action — pulled out as a top-level
/// hook so widget tests stub the OS share sheet (which would otherwise
/// hang the test harness) and assert the built message + link. Production
/// hands off to `share_plus`.
@visibleForTesting
Future<void> Function(String message) shareCircleInvite =
    (String message) => Share.share(message);

/// The care-circle members — LOCAL-FIRST (2026-06-10). Reads the on-device
/// [CircleMemberCacheTable] mirror of the backend roster, so the "People" list
/// renders instantly and OFFLINE (a rural-outage tester still sees who's in
/// the circle). A best-effort background refresh re-fetches `GET /circles` and
/// rewrites the cache when the device is online; the stream below re-emits the
/// moment that lands. Fail-safe: an offline / not-in-a-circle / unconfigured
/// refresh just leaves the last-known cache in place.
///
/// (Supersedes the 2026-06-07 design that read `GET /circles` live on every
/// open — that was the one screen that broke the app's local-first rule and
/// went blank with no signal.)
final syncedCircleMembersProvider =
    StreamProvider.autoDispose<List<CircleMemberDto>>((Ref ref) {
  // Kick a background refresh (never awaited) so the cache stays fresh when
  // online; the UI keeps rendering the cached roster meanwhile.
  unawaited(refreshCircleRoster(ref));
  return ref.watch(circleMemberCacheRepositoryProvider).watch();
});

/// Best-effort: pull the backend circle roster and rewrite the local cache.
/// Silent no-op when there's no configured backend / the device is offline /
/// the caregiver isn't in a circle yet — the cache (and the screen) keep
/// showing the last-known roster. Exposed for the connect flows (QR / scan /
/// username) to call after a membership change so the People list updates
/// without waiting for the next sync.
Future<void> refreshCircleRoster(Ref ref) async {
  if (!forumBackendConfigured) return;
  try {
    final List<CircleDto> circles =
        await ref.read(forumApiClientProvider).listCircles();
    if (circles.isEmpty) return;
    await ref
        .read(circleMemberCacheRepositoryProvider)
        .replaceForCircle(circles.first.id, circles.first.members);
  } catch (_) {
    // Keep the cache as-is — local-first never blanks on a failed refresh.
  }
}

/// Care Circle "People" roster at `/team/circle` (BUILD_SPEC.md §5.14).
///
/// A [PathHeader] (`Home › Care Circle › Care Circle`) sits above the
/// connect strip (set your @username, show your QR, scan to add, add by
/// @username) and the list of people actually in your backend circle. Each
/// row shows an avatar initial, the member's `@username` (falling back to
/// their display name), and an Owner / You badge where the backend exposes
/// it. There is no "invite pending" concept — a backend join is an
/// immediate, active membership. The empty state nudges the lone caregiver
/// to connect someone via the strip above.
class CareCircleScreen extends ConsumerWidget {
  const CareCircleScreen({super.key});

  static const Key listKey = Key('care-circle-list');
  static const Key emptyStateKey = Key('care-circle-empty');
  static const Key emptyInviteCtaKey = Key('care-circle-empty-invite');

  // Care-circle connect affordances (2026-06-06).
  static const Key usernameActionKey = Key('care-circle-username');
  static const Key showQrActionKey = Key('care-circle-show-qr');
  static const Key scanActionKey = Key('care-circle-scan');
  static const Key inviteByLinkActionKey = Key('care-circle-invite-by-link');
  static const Key addByUsernameActionKey = Key('care-circle-add-by-username');
  static const Key addByUsernameFieldKey = Key('care-circle-add-username-field');
  static const Key addByUsernameSubmitKey =
      Key('care-circle-add-by-username-submit');

  /// Stable per-row key derived from the member's profile id so tests
  /// target a node rather than a copy string.
  static Key rowKey(String profileId) => Key('care-circle-row-$profileId');

  static const String _usernameRoute = '/team/circle/username';
  static const String _qrRoute = '/team/circle/qr';
  static const String _scanRoute = '/team/circle/scan';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CircleMemberDto>> async =
        ref.watch(syncedCircleMembersProvider);
    final List<CircleMemberDto> members =
        async.asData?.value ?? const <CircleMemberDto>[];
    final String? myProfileId = ref.watch(myForumProfileIdProvider);

    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: ListView(
          key: CareCircleScreen.listKey,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            const PathHeader(
              breadcrumbs: <PathHeaderCrumb>[
                PathHeaderCrumb(label: 'Home', route: '/'),
                PathHeaderCrumb(label: 'Care Circle', route: '/team'),
                PathHeaderCrumb(label: 'Care Circle'),
              ],
              title: 'Care Circle',
              backLabel: 'Back to Care Circle',
              leadingIcon: Icons.diversity_3_outlined,
            ),
            const SizedBox(height: 8),
            const _ConnectActions(),
            const SizedBox(height: 20),
            if (members.isEmpty)
              const _EmptyState()
            else
              for (final CircleMemberDto m in members)
                _MemberRow(
                  member: m,
                  isSelf: myProfileId != null && m.profileId == myProfileId,
                ),
          ],
        ),
      ),
    );
  }
}

/// The care-circle connect strip (2026-06-06): set your @username, show
/// your invite QR, scan a QR to join, and add a caregiver by their
/// @handle.
class _ConnectActions extends ConsumerWidget {
  const _ConnectActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        _ConnectChip(
          key: CareCircleScreen.usernameActionKey,
          icon: Icons.alternate_email,
          label: 'Set your username',
          onTap: () => context.push(CareCircleScreen._usernameRoute),
        ),
        _ConnectChip(
          key: CareCircleScreen.showQrActionKey,
          icon: Icons.qr_code_2,
          label: 'Show my invite code',
          onTap: () => context.push(CareCircleScreen._qrRoute),
        ),
        _ConnectChip(
          key: CareCircleScreen.scanActionKey,
          icon: Icons.qr_code_scanner,
          label: 'Scan a code to add',
          onTap: () => context.push(CareCircleScreen._scanRoute),
        ),
        // Invite by LINK (2026-06-08): mints an invite + shares the
        // Worker's public /join/<token> link. Always shown alongside the
        // QR action; the tap handler degrades calmly (a SnackBar) when the
        // backend is unconfigured / unreachable, matching the QR path
        // rather than offering a dead link.
        _ConnectChip(
          key: CareCircleScreen.inviteByLinkActionKey,
          icon: Icons.link,
          label: 'Invite by link',
          onTap: () => _inviteByLink(context, ref),
        ),
        _ConnectChip(
          key: CareCircleScreen.addByUsernameActionKey,
          icon: Icons.person_search_outlined,
          label: 'Add by username',
          onTap: () => _openAddByUsername(context, ref),
        ),
      ],
    );
  }

  /// Mint an invite for the caller's circle (creating one if they have
  /// none, same as the QR path) and open the OS share sheet with a warm
  /// message + the `<origin>/join/<token>` link. Fail-safe: a backend /
  /// network error shows a calm SnackBar, never a crash.
  Future<void> _inviteByLink(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ForumApiClient client = ref.read(forumApiClientProvider);
    // No real backend origin = no shareable link. Degrade calmly rather
    // than sharing a dead, relative URL (local-only / demo builds).
    if (client.baseUrl.trim().isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Connect to share an invite link. Use Show my QR for now.',
          ),
        ),
      );
      return;
    }
    try {
      // Resolve (or create) the caller's circle — mirrors circle_qr_screen.
      final List<CircleDto> circles = await client.listCircles();
      final CircleDto circle;
      if (circles.isEmpty) {
        final ForumProfile me = await ref.read(myForumProfileProvider.future);
        circle = await client.createCircle(circleNameForOwner(me));
      } else {
        circle = circles.first;
      }
      // Bind active circle (best-effort, fire-and-forget) like the QR path.
      unawaited(_bindCircle(ref, circle.id));
      final CircleInviteDto invite = await client.createInvite(circle.id);
      // The shareable origin is the forum base WITHOUT the /api/v1 suffix.
      final String link = circleInviteLink(
        origin: client.baseUrl,
        token: invite.token,
      );
      await shareCircleInvite(
        'Join my care circle on Holdclose: $link',
      );
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

  Future<void> _bindCircle(WidgetRef ref, String circleId) async {
    try {
      await ref.read(syncStateStoreProvider).setCircleId(circleId);
    } catch (_) {
      // Non-fatal — bootstrap re-resolves the active circle next launch.
    }
  }

  Future<void> _openAddByUsername(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.hc.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) => const _AddByUsernameSheet(),
    );
  }
}

class _ConnectChip extends StatelessWidget {
  const _ConnectChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: context.hc.surfaceWarm,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: context.hc.primarySoft),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18, color: context.hc.cta),
              const SizedBox(width: 8),
              Text(
                label,
                style: textTheme.bodyMedium?.copyWith(
                  color: context.hc.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet that resolves a caregiver by their `@username`
/// (`GET /profiles/by-username/:username`) and, on a hit, mints a circle
/// invite they can redeem. Reuses the forum client — no new auth.
class _AddByUsernameSheet extends ConsumerStatefulWidget {
  const _AddByUsernameSheet();

  @override
  ConsumerState<_AddByUsernameSheet> createState() =>
      _AddByUsernameSheetState();
}

class _AddByUsernameSheetState extends ConsumerState<_AddByUsernameSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final String handle = _controller.text.toLowerCase().trim();
    if (handle.isEmpty) {
      setState(() => _error = 'Enter a username.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      final ForumPublicProfile found =
          await client.getProfileByUsername(handle);
      // Ensure the caller has a circle, then mint an invite to share.
      final List<CircleDto> circles = await client.listCircles();
      final CircleDto circle;
      if (circles.isEmpty) {
        final ForumProfile me = await ref.read(myForumProfileProvider.future);
        circle = await client.createCircle(circleNameForOwner(me));
      } else {
        circle = circles.first;
      }
      // Server-authoritative sync: bind this as the active circle id
      // (best-effort, fire-and-forget) so the app syncs through it without
      // blocking the invite flow.
      unawaited(_bindCircle(circle.id));
      await client.createInvite(circle.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Invite ready for @${found.username ?? handle}. '
            'Share your QR so they can join.',
          ),
        ),
      );
    } on ForumApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.error == 'profile_not_found'
            ? 'No caregiver found with that username.'
            : "We couldn't reach the directory. Please try again.";
      });
    }
  }

  Future<void> _bindCircle(String circleId) async {
    try {
      await ref.read(syncStateStoreProvider).setCircleId(circleId);
    } catch (_) {
      // Non-fatal — bootstrap re-resolves the active circle next launch.
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Add by @username',
            style: textTheme.titleLarge?.copyWith(
              color: context.hc.primary,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: CareCircleScreen.addByUsernameFieldKey,
            controller: _controller,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              prefixText: '@',
              labelText: 'Their username',
              hintText: 'sarah_h',
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style:
                  textTheme.bodyMedium?.copyWith(color: context.hc.ctaFilled),
            ),
          ],
          const SizedBox(height: 24),
          ElevatedButton(
            key: CareCircleScreen.addByUsernameSubmitKey,
            onPressed: _busy ? null : _submit,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              backgroundColor: context.hc.ctaFilled,
              foregroundColor: Theme.of(context).colorScheme.onSecondary,
            ),
            child: Text(
              _busy ? 'Looking…' : 'Find caregiver',
              style: textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// One person in the backend circle. Renders an avatar initial, their
/// `@username` (fallback display name), and an Owner / You badge.
class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.isSelf});

  final CircleMemberDto member;
  final bool isSelf;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String handle =
        member.username != null ? '@${member.username}' : member.displayName;
    final bool isOwner = member.role == 'owner';

    return Padding(
      key: CareCircleScreen.rowKey(member.profileId),
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        label: '$handle'
            '${isOwner ? ', circle owner' : ''}'
            '${isSelf ? ', you' : ''}.',
        child: Material(
          color: context.hc.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _Avatar(seed: handle),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        handle,
                        style: textTheme.bodyLarge?.copyWith(
                          color: context.hc.primary,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (isOwner || isSelf) ...<Widget>[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            if (isOwner) const _Tag(label: 'Owner'),
                            if (isSelf) const _Tag(label: 'You'),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.seed});

  final String seed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return CircleAvatar(
      radius: 24,
      backgroundColor: context.hc.primarySoft.withValues(alpha: 0.14),
      child: Text(
        _initial(seed),
        style: textTheme.titleLarge?.copyWith(
          color: context.hc.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: context.hc.primarySoft.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: textTheme.bodyMedium?.copyWith(
          color: context.hc.primarySoft,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: CareCircleScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(8, 24, 8, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.diversity_3_outlined,
            size: 56,
            color: context.hc.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            "You're the only one here so far.",
            style: textTheme.titleMedium?.copyWith(
              color: context.hc.primary,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Invite a family member or friend so you can share the caregiving '
            '— schedules, medications, and updates stay in sync between you.',
            style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Semantics(
            button: true,
            label: 'Invite someone to your care circle.',
            child: ElevatedButton.icon(
              key: CareCircleScreen.emptyInviteCtaKey,
              onPressed: () => _openInvite(context),
              icon: Icon(
                Icons.person_add_alt_1_outlined,
                color: Theme.of(context).colorScheme.onSecondary,
              ),
              label: const Text('Invite someone'),
              style: ElevatedButton.styleFrom(
                backgroundColor: context.hc.ctaFilled,
                foregroundColor: Theme.of(context).colorScheme.onSecondary,
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Open the invite options — shows the same connect sheet the strip's
  /// "Add by @username" action uses, so the empty-state CTA leads straight
  /// to inviting someone rather than dead-ending on jargon.
  void _openInvite(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.hc.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) => const _AddByUsernameSheet(),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Single uppercase initial from a `@handle` or display name; `?` when
/// empty. Strips a leading `@` so an `@sarah` handle reads `S`.
String _initial(String value) {
  final String trimmed = value.replaceFirst('@', '').trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.substring(0, 1).toUpperCase();
}
