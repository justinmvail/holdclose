import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/settings.dart';
import '../../providers/settings_provider.dart';
import '../../theme.dart';
import '../../widgets/hub_tile.dart';
import '../../widgets/path_header.dart';

/// The Care Circle hub at `/team` (route path kept internal) — the
/// coordination layer for everyone helping: tasks, shifts, the people
/// roster, the activity feed, and shared expenses.
///
/// Renamed from "Care Circle" and folded under the **Care** tab
/// (2026-06-06): it's now reached by the Care hub's gated "Care Circle"
/// tile (a pushed page with a Back-to-Care header), not a top-level tab.
/// The Calendar tile was removed — the one schedule lives under Care.
///
/// Still gated by [AppSettings.teamCoordinationEnabled]: when off (and a
/// deep link lands here), it shows the "Coordinate care" CTA instead of
/// the grid. Reached via the hub tile it's always on, since that tile
/// only appears when the toggle is on.
class CareTeamHubScreen extends ConsumerWidget {
  const CareTeamHubScreen({super.key});

  /// Stable per-tile key derived from the tile's destination route. Tests
  /// tap by route rather than by visible label so a copy edit doesn't
  /// break them.
  static Key tileKey(String route) => Key('team-hub-tile-$route');

  /// The CTA shown when team coordination is off. Tapping flips the
  /// setting on without leaving the tab.
  static const Key enableCtaKey = Key('team-hub-enable-cta');

  /// Wraps the empty-state body (everything below the PathHeader when
  /// coordination is off). Tests assert on this key instead of the
  /// HubGrid to confirm the gated state rendered.
  static const Key emptyStateKey = Key('team-hub-empty-state');

  /// The six hub tiles, left-to-right / top-to-bottom (BUILD_SPEC.md
  /// §5.13). Chip colors are [CareblazersColors] tokens — the HTML
  /// reference's coral/teal/amber/plum placeholders are discarded per
  /// docs/MENU_LAYOUT_SPEC.md.
  static List<_TeamTileSpec> _tilesFor(BuildContext context) =>
      <_TeamTileSpec>[
        _TeamTileSpec(
          icon: Icons.task_alt_outlined,
          label: 'Tasks',
          subLabel: 'to-dos & assignments',
          route: '/team/tasks',
          chipColor: context.cb.accentDeep,
        ),
        _TeamTileSpec(
          icon: Icons.access_time_outlined,
          label: 'Shifts',
          subLabel: "who's on when",
          route: '/team/shifts',
          chipColor: context.cb.link,
        ),
        _TeamTileSpec(
          icon: Icons.diversity_3_outlined,
          label: 'People',
          subLabel: 'who is helping',
          route: '/team/circle',
          chipColor: context.cb.success,
        ),
        _TeamTileSpec(
          icon: Icons.timeline_outlined,
          label: 'Activity',
          subLabel: 'recent updates',
          route: '/team/activity',
          chipColor: context.cb.primarySoft,
        ),
        _TeamTileSpec(
          icon: Icons.account_balance_wallet_outlined,
          label: 'Expenses',
          subLabel: 'costs & receipts',
          route: '/team/expenses',
          chipColor: context.cb.primary,
        ),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool enabled =
        ref.watch(settingsProvider).teamCoordinationEnabled;
    return Scaffold(
      backgroundColor: context.cb.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              // Pushed under the Care tab now — a full breadcrumb (Care ›
              // Care Circle) with a Back-to-Care affordance.
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Care Circle'),
                ],
                title: 'Care Circle',
                backLabel: 'Back to Care',
                leadingIcon: Icons.diversity_3_outlined,
              ),
            ),
            Expanded(
              child: enabled
                  ? HubGrid(
                      tiles: <HubTile>[
                        for (final _TeamTileSpec spec in _tilesFor(context))
                          HubTile(
                            key: tileKey(spec.route),
                            icon: spec.icon,
                            label: spec.label,
                            subLabel: spec.subLabel,
                            chipColor: spec.chipColor,
                            onTap: () => context.push(spec.route),
                          ),
                      ],
                    )
                  : _EmptyState(
                      onEnable: () => ref
                          .read(settingsProvider.notifier)
                          .setTeamCoordinationEnabled(true),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Coordinate care" CTA shown when [AppSettings.teamCoordinationEnabled]
/// is off. One tap flips the toggle, which causes [CareTeamHubScreen] to
/// rebuild with the populated HubGrid — no navigation, no app restart.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onEnable});

  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Padding(
      key: CareTeamHubScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Caring with others?',
            style: tt.headlineSmall?.copyWith(
              color: context.cb.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Share the calendar, hand off tasks, line up who's on "
            "tonight, and split the receipts — without bouncing between "
            "five apps. You can turn this back off in Settings any time.",
            style: tt.bodyLarge?.copyWith(
              color: context.cb.text,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            key: CareTeamHubScreen.enableCtaKey,
            onPressed: onEnable,
            icon: const Icon(Icons.groups_outlined),
            label: const Text('Coordinate care'),
            style: ElevatedButton.styleFrom(
              backgroundColor: context.cb.cta,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(56),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Or keep it just you — the rest of the app works the same.",
            style: tt.bodyMedium?.copyWith(
              color: context.cb.text.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// Static description of one [CareTeamHubScreen] tile — the glyph, the two
/// label lines, the chip color, and the route the tile pushes.
@immutable
class _TeamTileSpec {
  const _TeamTileSpec({
    required this.icon,
    required this.label,
    required this.subLabel,
    required this.route,
    required this.chipColor,
  });

  final IconData icon;
  final String label;
  final String subLabel;
  final String route;
  final Color chipColor;
}
