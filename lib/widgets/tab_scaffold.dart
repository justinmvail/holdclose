import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme.dart';

/// Bottom-tab shell for the four root branches:
/// `Home · Journal · Library · Crisis` (BUILD_SPEC.md §4.1 order).
///
/// Wraps a [StatefulNavigationShell] so each tab keeps its own back
/// stack across switches. Tab branch indices map 1-to-1 to
/// [tabBranchPaths]; the router and tests share this list so a
/// reorder lands in one place.
class TabScaffold extends StatelessWidget {
  const TabScaffold({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// Branch paths in tab-bar order. Index `i` is the path that the
  /// tab at position `i` switches to.
  static const List<String> tabBranchPaths = <String>[
    '/',
    '/journal',
    '/library',
    '/crisis',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: TabScaffoldBar(
        currentIndex: navigationShell.currentIndex,
        onDestinationSelected: (int index) {
          context.go(tabBranchPaths[index]);
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

  /// Tab destinations in BUILD_SPEC.md §4.1 order. Cupertino-style
  /// Material icon set: outlined glyphs for inactive, filled for
  /// active. Crisis uses `warning_amber` (not the red exclamation)
  /// to stay calm in tone — the audience is already stressed.
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
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          );
        }),
      ),
      child: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: onDestinationSelected,
        destinations: <NavigationDestination>[
          for (final TabScaffoldDestination dest in destinations)
            NavigationDestination(
              icon: Icon(dest.icon),
              selectedIcon: Icon(dest.selectedIcon),
              label: dest.label,
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
