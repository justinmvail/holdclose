import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/settings.dart';
import '../../providers/settings_provider.dart';
import '../../theme.dart';
import '../../widgets/hub_tile.dart';
import '../../widgets/path_header.dart';

/// The Care Team tile-hub at `/team` (BUILD_SPEC.md §5.13, TASKS.md
/// Phase 14.26) — the single entry point to everything the caregiving
/// circle shares: the calendar, tasks, shifts, the circle roster, the
/// activity feed, and shared expenses.
///
/// This is a **landing screen**: the [PathHeader] carries a single crumb
/// ("Care Team") so it renders the title row only — no breadcrumb trail
/// and no Back control (you reach the hub by tapping the Care Team tab,
/// and re-tapping it pops the branch back here).
///
/// Two visual states, gated by [AppSettings.teamCoordinationEnabled]:
///   - **Enabled** — the documented six-tile [HubGrid].
///   - **Disabled (default)** — a single "Coordinate care" CTA that
///     flips the setting on with one tap. The tab stays mounted either
///     way so the 5-tab IA invariant holds.
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
  static List<_TeamTileSpec> get _tiles => <_TeamTileSpec>[
        _TeamTileSpec(
          icon: Icons.calendar_view_week_outlined,
          label: 'Calendar',
          subLabel: 'week at a glance',
          route: '/team/calendar',
          chipColor: careblazersColors.cta,
        ),
        _TeamTileSpec(
          icon: Icons.task_alt_outlined,
          label: 'Tasks',
          subLabel: 'to-dos & assignments',
          route: '/team/tasks',
          chipColor: careblazersColors.accentDeep,
        ),
        _TeamTileSpec(
          icon: Icons.access_time_outlined,
          label: 'Shifts',
          subLabel: "who's on when",
          route: '/team/shifts',
          chipColor: careblazersColors.link,
        ),
        _TeamTileSpec(
          icon: Icons.diversity_3_outlined,
          label: 'Care Circle',
          subLabel: 'people helping',
          route: '/team/circle',
          chipColor: careblazersColors.success,
        ),
        _TeamTileSpec(
          icon: Icons.timeline_outlined,
          label: 'Activity',
          subLabel: 'recent updates',
          route: '/team/activity',
          chipColor: careblazersColors.primarySoft,
        ),
        _TeamTileSpec(
          icon: Icons.account_balance_wallet_outlined,
          label: 'Expenses',
          subLabel: 'costs & receipts',
          route: '/team/expenses',
          chipColor: careblazersColors.primary,
        ),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool enabled =
        ref.watch(settingsProvider).teamCoordinationEnabled;
    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              // Single crumb → PathHeader suppresses the breadcrumb row
              // and the Back control, rendering the title row only. The
              // backLabel is required by the widget but unused here.
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Care Team'),
                ],
                title: 'Care Team',
                backLabel: 'Back to Home',
                leadingIcon: Icons.groups_outlined,
              ),
            ),
            Expanded(
              child: enabled
                  ? HubGrid(
                      tiles: <HubTile>[
                        for (final _TeamTileSpec spec in _tiles)
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
              color: careblazersColors.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Share the calendar, hand off tasks, line up who's on "
            "tonight, and split the receipts — without bouncing between "
            "five apps. You can turn this back off in Settings any time.",
            style: tt.bodyLarge?.copyWith(
              color: careblazersColors.text,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            key: CareTeamHubScreen.enableCtaKey,
            onPressed: onEnable,
            icon: const Icon(Icons.groups_outlined),
            label: const Text('Coordinate care'),
            style: ElevatedButton.styleFrom(
              backgroundColor: careblazersColors.cta,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(56),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Or keep it just you — the rest of the app works the same.",
            style: tt.bodyMedium?.copyWith(
              color: careblazersColors.text.withValues(alpha: 0.7),
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
