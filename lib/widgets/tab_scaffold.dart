import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/community_feed_provider.dart';
import '../providers/community_subnav_provider.dart';
import '../providers/pending_chat_message_provider.dart';
import '../providers/voice_capture_provider.dart';
import '../screens/chat/conversation_list_screen.dart';
import '../services/chat_repository.dart';
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

  /// The raised center voice button docked into the bottom bar
  /// (#fb_1780962131440334). ADDITIVE — it sits on top of the four-tab
  /// bar via [FloatingActionButtonLocation.centerDocked] and never
  /// replaces or hides a tab.
  static const Key centerVoiceButtonKey = Key('tab-scaffold-center-voice');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: navigationShell,
      // The four-tab invariant is untouched: the mic is a docked center
      // element layered over the bar, NOT a fifth NavigationDestination.
      floatingActionButton: const _CenterVoiceButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
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

/// The bottom `NavigationBar` rendered by [TabScaffold].
///
/// Extracted from the shell so widget + golden tests can render the
/// bar without spinning up a full router — the shell-bound variant
/// would otherwise require a live `StatefulNavigationShell`.
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
    return NavigationBarTheme(
      data: NavigationBarThemeData(
        backgroundColor: context.cb.background,
        indicatorColor: context.cb.surfaceWarm,
        iconTheme: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          final bool selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected
                ? context.cb.primary
                : context.cb.primarySoft,
            size: 28,
          );
        }),
        labelTextStyle:
            WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          final bool selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected
                ? context.cb.primary
                : context.cb.primarySoft,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          );
        }),
      ),
      child: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: onDestinationSelected,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: <NavigationDestination>[
          for (final TabScaffoldDestination d in destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

/// Raised, salmon center voice button docked into the bottom bar
/// (#fb_1780962131440334).
///
/// On tap it captures one spoken phrase through the shared
/// [voiceCaptureProvider] seam (the SAME capture impl + permission
/// handling the Home Add-sheet and chat composer mics use — no new speech
/// pipeline), mints a fresh conversation via [ChatRepository], parks the
/// transcript in [pendingChatMessageProvider] keyed by the new id, and
/// navigates to `/chat/<id>`. The chat screen auto-sends the parked
/// message on its first build, so a spoken request lands as the first
/// user turn — the coach then performs the action or answers the question
/// inside the thread (no separate intent classification needed).
///
/// Fail-safe: a blank/aborted capture is a silent no-op (no empty thread
/// is created); a denied mic surfaces the standard permission snackbar.
class _CenterVoiceButton extends ConsumerStatefulWidget {
  const _CenterVoiceButton();

  @override
  ConsumerState<_CenterVoiceButton> createState() => _CenterVoiceButtonState();
}

class _CenterVoiceButtonState extends ConsumerState<_CenterVoiceButton> {
  bool _listening = false;

  Future<void> _capture() async {
    if (_listening) return;
    setState(() => _listening = true);
    String? transcript;
    try {
      transcript = await ref.read(voiceCaptureProvider).capture();
    } on VoiceCapturePermissionDeniedException {
      if (mounted) showVoiceCapturePermissionDeniedSnackBar(context);
      if (mounted) setState(() => _listening = false);
      return;
    } catch (_) {
      // Any other capture failure is non-fatal — drop back to idle so the
      // bar stays usable (fail-safe per the feedback note).
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!mounted) {
      return;
    }
    final String text = transcript?.trim() ?? '';
    if (text.isEmpty) {
      // Nothing usable was said — no-op, don't mint an empty thread.
      setState(() => _listening = false);
      return;
    }

    // Mint a fresh conversation the same way the conversation list does,
    // park the spoken message for it, then navigate — the chat screen
    // sends it on arrival.
    final ChatRepository repo = ref.read(chatRepositoryProvider);
    final String id = ref.read(conversationListIdFactoryProvider)();
    final DateTime now = ref.read(conversationListClockProvider)();
    await repo.createConversation(id: id, title: 'New chat', createdAt: now);
    ref.read(pendingChatMessageProvider.notifier).set(id, text);
    ref.invalidate(chatConversationListProvider);
    if (!mounted) return;
    setState(() => _listening = false);
    // `go` (not `push`) so the bar switches to the Chat branch and lands
    // on the new thread regardless of which tab the caregiver was on when
    // they tapped the center mic. Back from the thread pops to the Chat
    // list, consistent with how a `/chat/:id` thread behaves.
    context.go('/chat/$id');
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: !_listening,
      label: _listening
          ? 'Listening. Speak your request.'
          : 'Speak to start a chat with the coach.',
      child: FloatingActionButton(
        key: TabScaffold.centerVoiceButtonKey,
        onPressed: _listening ? null : _capture,
        backgroundColor: context.cb.cta,
        foregroundColor: Colors.white,
        elevation: 2,
        tooltip: _listening ? 'Listening…' : 'Speak to start a chat',
        child: _listening
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Icon(Icons.mic_none, size: 28),
      ),
    );
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
