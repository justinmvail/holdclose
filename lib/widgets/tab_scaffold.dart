import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/settings.dart';
import '../providers/settings_provider.dart';
import '../theme.dart';

/// Bottom-tab shell for the six root branches:
/// `Home · Journal · Medications · Appointments · Library · Crisis`
/// (BUILD_SPEC.md §4.1 + Phase 12.8 additions).
///
/// Medications + Appointments only render in the tab bar when the
/// matching [AppSettings] toggles are on — `useTrackers` master AND
/// the per-feature toggle. When hidden, the underlying go_router
/// branches still exist (a deep-link from a notification tap still
/// works), but they don't surface as tap targets in the bar.
///
/// Branch indices are STABLE across visibility changes — branch 2 is
/// always Medications regardless of whether it's surfaced in the bar.
/// The shell-to-bar mapping is computed at render time so a
/// `useTrackers` flip toggles the bar without re-keying any branch's
/// navigator stack.
class TabScaffold extends ConsumerWidget {
  const TabScaffold({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// Branch paths in shell-branch order. Index `i` is the path the
  /// router restores when the bar switches to that branch. The
  /// medication + appointment branches sit between the journal and
  /// library so the lean-app (trackers-off) layout collapses to the
  /// same Home/Journal/Library/Crisis shape as the pre-Phase-12.8
  /// build without re-indexing the journal-tap tests.
  static const List<String> tabBranchPaths = <String>[
    '/',
    '/journal',
    '/medications',
    '/appointments',
    '/library',
    '/crisis',
  ];

  /// Compute the visible branch indices for the current
  /// [AppSettings]. Medications + Appointments collapse off the bar
  /// when [AppSettings.useTrackers] is OFF or the per-feature toggle
  /// is OFF — same precedence the Settings UI advertises.
  static List<int> visibleBranchIndicesFor(AppSettings settings) {
    return <int>[
      0, // Home
      1, // Journal
      if (settings.useTrackers && settings.medicationsEnabled) 2,
      if (settings.useTrackers && settings.appointmentsEnabled) 3,
      4, // Library
      5, // Crisis
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);
    final List<int> visibleBranches = visibleBranchIndicesFor(settings);
    final int activeBarSlot =
        visibleBranches.indexOf(navigationShell.currentIndex);
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: TabScaffoldBar(
        currentIndex: activeBarSlot < 0 ? 0 : activeBarSlot,
        visibleBranches: visibleBranches,
        onDestinationSelected: (int barIndex) {
          final int branchIndex = visibleBranches[barIndex];
          context.go(tabBranchPaths[branchIndex]);
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
///
/// [visibleBranches] is the subset of [TabScaffoldBar.destinations]
/// (by branch index) the bar should paint, in left-to-right order.
/// Defaults to "all of them" so legacy tests + the default golden
/// keep passing without per-call wiring.
class TabScaffoldBar extends StatelessWidget {
  const TabScaffoldBar({
    super.key,
    required this.currentIndex,
    required this.onDestinationSelected,
    this.visibleBranches = const <int>[0, 1, 2, 3, 4, 5],
  });

  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<int> visibleBranches;

  /// Tab destinations indexed by shell-branch index. The Cupertino-
  /// style outlined glyphs read as calm on the day the audience is
  /// running on three hours of sleep; warning_amber on Crisis
  /// (BUILD_SPEC.md §4.1 — not the alarmist red bell) for the same
  /// reason.
  static const List<TabScaffoldDestination> destinations =
      <TabScaffoldDestination>[
    TabScaffoldDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    TabScaffoldDestination(
      label: 'Journal',
      icon: Icons.book_outlined,
      selectedIcon: Icons.book,
    ),
    TabScaffoldDestination(
      label: 'Meds',
      icon: Icons.medication_outlined,
      selectedIcon: Icons.medication,
    ),
    TabScaffoldDestination(
      label: 'Visits',
      icon: Icons.event_outlined,
      selectedIcon: Icons.event,
    ),
    TabScaffoldDestination(
      label: 'Library',
      icon: Icons.library_books_outlined,
      selectedIcon: Icons.library_books,
    ),
    TabScaffoldDestination(
      label: 'Crisis',
      icon: Icons.warning_amber_outlined,
      selectedIcon: Icons.warning_amber,
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
          for (final int branchIndex in visibleBranches)
            NavigationDestination(
              icon: Icon(destinations[branchIndex].icon),
              selectedIcon: Icon(destinations[branchIndex].selectedIcon),
              label: destinations[branchIndex].label,
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
