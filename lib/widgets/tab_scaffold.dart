import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/community_feed_provider.dart';
import '../providers/community_subnav_provider.dart';
import '../providers/voice_capture_provider.dart';
import '../screens/chat/conversation_list_screen.dart';
import '../services/chat_service.dart';
import '../services/voice_intake.dart';
import '../theme.dart';

/// Bottom-tab shell for the fixed four-tab bar (IA refactor 2026-06-06):
/// `Home · Care · Chat · Community`. All four tabs are ALWAYS visible.
/// The old "Medical" tab was renamed **Care** (the clinical word was
/// off-brand) and the separate "Team" tab was folded into Care as a
/// gated "Care Circle" hub — so the bar slot index is the shell-branch
/// index directly.
///
/// Care is a tile-hub landing; Chat + Community are direct landings.
/// Branch indices line up 1:1 with [tabBranchPaths]. The Care branch's
/// route path stays `/medical` internally (users never see URLs) so
/// every existing deep link keeps resolving.
///
/// Re-tapping the already-active tab resets that branch to its hub via
/// `goBranch(..., initialLocation: true)` — the iOS-style "tap the
/// active tab to pop to root" affordance the spec calls for.
///
/// The bar renders the four tabs spread two-left / two-right around a
/// raised salmon **voice button** sitting INLINE in the center slot
/// (#fb_1780962131440334 / IMG_0725 — the mic was previously a floating
/// FAB that hovered above the bar and missed taps). The mic is an action,
/// NOT a fifth navigation destination, so the four-tab invariant holds.
class TabScaffold extends ConsumerWidget {
  const TabScaffold({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// Branch paths in shell-branch order. Index `i` is the path the
  /// router restores when the bar switches to that branch. MUST match
  /// the StatefulShellRoute branch order in `lib/routing/router.dart`.
  static const List<String> tabBranchPaths = <String>[
    '/',
    '/medical',
    '/chat',
    '/community',
  ];

  /// The inline center voice button (#fb_1780962131440334). It lives in
  /// the middle slot of [TabScaffoldBar], at the same vertical level as
  /// the four tabs — NOT a docked/floating FAB and NOT a tab.
  static const Key centerVoiceButtonKey = Key('tab-scaffold-center-voice');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: TabScaffoldBar(
        currentIndex: navigationShell.currentIndex,
        onDestinationSelected: (int index) {
          // Selecting the Community destination — a switch from another
          // tab OR an active-tab re-tap — drops the caregiver back on the
          // Feed segment of the in-tab sub-nav (Phase 14.36). The segment
          // lives in CommunityFeedScreen's local state, so the bottom bar
          // signals the reset rather than reaching into the screen.
          if (tabBranchPaths[index] == '/community') {
            ref.read(communityTabReentryProvider.notifier).bump();
          }
          if (tabBranchPaths[index] == '/') {
            // Landing on Home rebuilds the community feed from scratch so the
            // "From the Community" recap reflects posts created on the
            // Community tab while Home sat offstage in the shell (alpha
            // fb_1780965223686636 — "added a post and Home isn't updating").
            // invalidate (not .refresh()) so the recap's OWN watched instance
            // re-fetches — .refresh() on this autoDispose provider would just
            // touch a throwaway instance with no live listener.
            ref.invalidate(communityFeedProvider);
          }
          if (index == navigationShell.currentIndex) {
            // Re-tap the active tab — pop the branch back to its hub.
            navigationShell.goBranch(index, initialLocation: true);
          } else {
            context.go(tabBranchPaths[index]);
          }
        },
      ),
    );
  }
}

/// The custom bottom bar rendered by [TabScaffold]: four tabs spread
/// around the inline center voice button.
///
/// Extracted from the shell so widget + golden tests can render the
/// bar without spinning up a full router. (It still needs a ProviderScope
/// ancestor because the center mic is a [ConsumerWidget].)
///
/// Layout: `[Home] [Care] (mic) [Chat] [Community]` — five equal-width
/// slots. The four labelled tabs map to branch indices 0..3 via
/// [destinations]; the mic occupies the middle slot and carries no branch.
class TabScaffoldBar extends StatelessWidget {
  const TabScaffoldBar({
    super.key,
    required this.currentIndex,
    required this.onDestinationSelected,
  });

  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;

  /// Tab destinations in shell-branch order (IA refactor 2026-06-06).
  /// The Cupertino-style outlined glyphs read as calm on the day the
  /// audience is running on three hours of sleep. "Care" replaces the
  /// clinical "Medical"; the caring-hands glyph keeps it warm.
  static const List<TabScaffoldDestination> destinations =
      <TabScaffoldDestination>[
    TabScaffoldDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    TabScaffoldDestination(
      label: 'Care',
      icon: Icons.volunteer_activism_outlined,
      selectedIcon: Icons.volunteer_activism,
    ),
    TabScaffoldDestination(
      label: 'Chat',
      icon: Icons.chat_bubble_outline,
      selectedIcon: Icons.chat_bubble,
    ),
    TabScaffoldDestination(
      label: 'Community',
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    // Slots, left → right: Home(0), Care(1), [mic], Chat(2), Community(3).
    // The mic sits between the two left and two right tabs so the four-tab
    // order Home·Care·Chat·Community is preserved visually.
    return Material(
      color: context.cb.background,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          // Nudge the whole row down so the icons + labels aren't biased to
          // the top of the bar, sitting closer to vertical-centre of the
          // visible bar above the home-indicator inset (fb_1781135834656216 /
          // fb_1781138782074336).
          padding: const EdgeInsets.only(top: 10),
          child: SizedBox(
            height: 64,
            child: Row(
              children: <Widget>[
                _TabItem(
                  destination: destinations[0],
                  selected: currentIndex == 0,
                  onTap: () => onDestinationSelected(0),
                ),
                _TabItem(
                  destination: destinations[1],
                  selected: currentIndex == 1,
                  onTap: () => onDestinationSelected(1),
                ),
                const Expanded(child: Center(child: _CenterVoiceButton())),
                _TabItem(
                  destination: destinations[2],
                  selected: currentIndex == 2,
                  onTap: () => onDestinationSelected(2),
                ),
                _TabItem(
                  destination: destinations[3],
                  selected: currentIndex == 3,
                  onTap: () => onDestinationSelected(3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One labelled, tappable tab in [TabScaffoldBar]. Occupies an equal share
/// of the bar width (wrapped in [Expanded]) so the four tabs spread evenly
/// two-left / two-right of the center mic.
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final TabScaffoldDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? context.cb.primary : context.cb.primarySoft;
    return Expanded(
      child: InkResponse(
        onTap: onTap,
        radius: 40,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              selected ? destination.selectedIcon : destination.icon,
              size: 26,
              color: color,
            ),
            const SizedBox(height: 2),
            // Single-line, clipped — never wrap. A wrapped label would grow
            // the column past the bar height and trip a RenderFlex overflow
            // (the wide test font surfaced this; "Community" is the worst case).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                destination.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Raised, salmon center voice button sitting INLINE in the middle of the
/// bottom bar (#fb_1780962131440334 / fb_1781029699933602 — "make it work
/// like Siri").
///
/// Tap → it starts listening and shows a live-dictation bubble right above
/// the button (the transcript streams in as the caregiver speaks, via the
/// shared [voiceCaptureProvider] seam's `onPartial`). When they stop, it
/// hands the final transcript to [ChatService.routeVoiceIntent], which lets
/// the coach DECIDE:
///   - a clear command (log this, add that) → the coach performs it; the
///     bubble flashes a short confirmation and we stay put — NO chat opens;
///   - a question or anything ambiguous → a thread is minted with the
///     answer already in it and we navigate to `/chat/<id>`.
///
/// Fail-safe: a blank/cancelled capture is a silent no-op (no thread); a
/// denied mic surfaces the standard permission snackbar; tapping the button
/// again while listening cancels.
class _CenterVoiceButton extends ConsumerStatefulWidget {
  const _CenterVoiceButton();

  @override
  ConsumerState<_CenterVoiceButton> createState() => _CenterVoiceButtonState();
}

enum _MicPhase { listening, thinking, done }

class _MicOverlayData {
  const _MicOverlayData(this.phase, this.text);
  final _MicPhase phase;
  final String text;
}

class _CenterVoiceButtonState extends ConsumerState<_CenterVoiceButton> {
  bool _busy = false;
  bool _cancelled = false;
  OverlayEntry? _overlay;
  final ValueNotifier<_MicOverlayData> _data = ValueNotifier<_MicOverlayData>(
      const _MicOverlayData(_MicPhase.listening, ''));

  @override
  void dispose() {
    _removeOverlay();
    _data.dispose();
    super.dispose();
  }

  void _showOverlay() {
    _data.value = const _MicOverlayData(_MicPhase.listening, '');
    _overlay = OverlayEntry(
      builder: (BuildContext ctx) => _MicOverlayCard(
        data: _data,
        onCancel: _cancel,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _reset() {
    _removeOverlay();
    if (mounted) setState(() => _busy = false);
  }

  /// Cancel an in-flight listen — drop the overlay and ignore whatever the
  /// recognizer ultimately returns (it stops itself on silence).
  void _cancel() {
    _cancelled = true;
    _reset();
  }

  Future<void> _capture() async {
    if (_busy) {
      // A second tap while listening means "never mind".
      _cancel();
      return;
    }
    setState(() => _busy = true);
    _cancelled = false;
    _showOverlay();

    String? transcript;
    try {
      transcript = await ref.read(voiceCaptureProvider).capture(
        onPartial: (String partial) {
          if (!_cancelled) {
            _data.value = _MicOverlayData(_MicPhase.listening, partial);
          }
        },
      );
    } on VoiceCapturePermissionDeniedException {
      _reset();
      if (mounted) showVoiceCapturePermissionDeniedSnackBar(context);
      return;
    } catch (_) {
      // Any other capture failure is non-fatal — fail safe to idle.
      _reset();
      return;
    }
    if (_cancelled || !mounted) {
      _reset();
      return;
    }
    final String text = transcript?.trim() ?? '';
    if (text.isEmpty) {
      // Nothing usable was said — silent no-op, no thread.
      _reset();
      return;
    }

    // Hand the transcript to the coach to decide: act, or converse.
    _data.value = _MicOverlayData(_MicPhase.thinking, text);
    final VoiceIntentOutcome outcome =
        await ref.read(chatServiceProvider).routeVoiceIntent(text);
    if (!mounted) {
      _removeOverlay();
      return;
    }
    ref.invalidate(chatConversationListProvider);

    switch (outcome) {
      case VoiceIntentAction(:final String summary):
        // The coach did it — flash the confirmation, then dismiss. Stay put.
        _data.value = _MicOverlayData(_MicPhase.done, summary);
        await Future<void>.delayed(const Duration(milliseconds: 2600));
        _reset();
      case VoiceIntentChat(:final String conversationId):
        // It's a conversation — open the thread (answer already in it).
        _reset();
        if (mounted) context.go('/chat/$conversationId');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: _busy
          ? 'Listening. Tap again to cancel.'
          : 'Speak to the coach. Tap and say what you need.',
      child: Material(
        key: TabScaffold.centerVoiceButtonKey,
        color: context.cb.cta,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _capture,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Center(
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.mic_none, size: 26, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// The live-dictation bubble that floats just above the center mic while a
/// voice capture is in flight. Listens to a [ValueNotifier] so the partial
/// transcript updates without rebuilding the [OverlayEntry].
class _MicOverlayCard extends StatelessWidget {
  const _MicOverlayCard({required this.data, required this.onCancel});

  final ValueListenable<_MicOverlayData> data;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final double barInset = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: 16,
      right: 16,
      bottom: barInset + 64 + 12,
      child: Material(
        color: Colors.transparent,
        child: ValueListenableBuilder<_MicOverlayData>(
          valueListenable: data,
          builder: (BuildContext context, _MicOverlayData d, _) {
            return Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                color: context.cb.background,
                borderRadius: BorderRadius.circular(18),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: _buildContent(context, d),
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, _MicOverlayData d) {
    switch (d.phase) {
      case _MicPhase.listening:
        return Row(
          children: <Widget>[
            Icon(Icons.mic, size: 22, color: context.cb.cta),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                d.text.isEmpty ? 'Listening…' : d.text,
                style: TextStyle(
                  color: context.cb.primary,
                  fontSize: 16,
                  fontStyle:
                      d.text.isEmpty ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: onCancel,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: context.cb.primarySoft,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        );
      case _MicPhase.thinking:
        return Row(
          children: <Widget>[
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(context.cb.cta),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                d.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.cb.primary, fontSize: 16),
              ),
            ),
          ],
        );
      case _MicPhase.done:
        return Row(
          children: <Widget>[
            Icon(Icons.check_circle, size: 22, color: context.cb.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                d.text,
                style: TextStyle(color: context.cb.primary, fontSize: 16),
              ),
            ),
          ],
        );
    }
  }
}

/// Static description of one [TabScaffoldBar] tab.
@immutable
class TabScaffoldDestination {
  const TabScaffoldDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
