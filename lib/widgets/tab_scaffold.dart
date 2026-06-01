import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/community_subnav_provider.dart';
import '../theme.dart';

/// Bottom-tab shell for the fixed five-tab bar introduced in the Phase
/// 14 IA refactor (BUILD_SPEC.md §4.1): `Home · Medical · Team · Chat ·
/// Community`. All five tabs are ALWAYS visible — the old
/// `useTrackers` / per-feature visibility toggles (and the
/// `visibleBranchIndicesFor` mapping they drove) are gone, so the bar
/// slot index is the shell-branch index directly.
///
/// Medical + Team are tile-hub landings; Chat + Community are direct
/// landings. Branch indices line up 1:1 with [tabBranchPaths].
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
    '/team',
    '/chat',
    '/community',
  ];

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

  /// Tab destinations in shell-branch order (Phase 14, BUILD_SPEC.md
  /// §4.1). The Cupertino-style outlined glyphs read as calm on the day
  /// the audience is running on three hours of sleep. The bar label for
  /// Care Team is just "Team" — "Care Team" is too wide for a five-slot
  /// bar (per `docs/MENU_LAYOUT_SPEC.md`).
  static const List<TabScaffoldDestination> destinations =
      <TabScaffoldDestination>[
    TabScaffoldDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    TabScaffoldDestination(
      label: 'Medical',
      icon: Icons.local_hospital_outlined,
      selectedIcon: Icons.local_hospital,
    ),
    TabScaffoldDestination(
      label: 'Team',
      icon: Icons.diversity_3_outlined,
      selectedIcon: Icons.diversity_3,
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
        backgroundColor: careblazersColors.background,
        indicatorColor: careblazersColors.surfaceWarm,
        iconTheme: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          final bool selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected
                ? careblazersColors.primary
                : careblazersColors.primarySoft,
            size: 28,
          );
        }),
        labelTextStyle:
            WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          final bool selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected
                ? careblazersColors.primary
                : careblazersColors.primarySoft,
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
