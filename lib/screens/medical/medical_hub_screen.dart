import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme.dart';
import '../../widgets/hub_tile.dart';
import '../../widgets/path_header.dart';

/// The Medical tile-hub at `/medical` (BUILD_SPEC.md §5.13, TASKS.md
/// Phase 14.15) — the single entry point to everything clinical: meds,
/// schedule, appointments, health log, care plan, documents, and the
/// re-homed journal.
///
/// This is a **landing screen**: the [PathHeader] carries a single crumb
/// ("Medical") so it renders the title row only — no breadcrumb trail and
/// no Back control (you reach the hub by tapping the Medical tab, and
/// re-tapping it pops the branch back here). The body is a [HubGrid] of
/// seven [HubTile]s in the documented order; each tile pushes its feature
/// page (the routes that don't exist yet land in Phases 14.16+).
class MedicalHubScreen extends StatelessWidget {
  const MedicalHubScreen({super.key});

  /// Stable per-tile key derived from the tile's destination route. Tests
  /// tap by route rather than by visible label so a copy edit doesn't
  /// break them.
  static Key tileKey(String route) => Key('medical-hub-tile-$route');

  /// The seven hub tiles, left-to-right / top-to-bottom (BUILD_SPEC.md
  /// §5.13). Chip colors are [CareblazersColors] tokens — the HTML
  /// reference's coral/teal/amber/plum placeholders are discarded per
  /// docs/MENU_LAYOUT_SPEC.md.
  static List<_MedicalTileSpec> get _tiles => <_MedicalTileSpec>[
        _MedicalTileSpec(
          icon: Icons.medication_outlined,
          label: 'Medications',
          subLabel: 'doses & reminders',
          route: '/medications',
          chipColor: careblazersColors.primary,
        ),
        _MedicalTileSpec(
          icon: Icons.schedule_outlined,
          label: 'Schedule',
          subLabel: 'today, tomorrow, this week',
          route: '/team/calendar',
          chipColor: careblazersColors.cta,
        ),
        _MedicalTileSpec(
          icon: Icons.event_outlined,
          label: 'Appointments',
          subLabel: 'calendar & visits',
          route: '/appointments',
          chipColor: careblazersColors.accentDeep,
        ),
        _MedicalTileSpec(
          icon: Icons.monitor_heart_outlined,
          label: 'Health Log',
          subLabel: 'symptoms & vitals',
          route: '/medical/health-log',
          chipColor: careblazersColors.link,
        ),
        _MedicalTileSpec(
          icon: Icons.assignment_outlined,
          label: 'Routines',
          subLabel: 'scheduled care tasks',
          route: '/medical/routines',
          chipColor: careblazersColors.success,
        ),
        _MedicalTileSpec(
          icon: Icons.shield_outlined,
          label: 'Emergency Card',
          subLabel: 'info for first responders',
          route: '/medical/cards/emergency',
          chipColor: careblazersColors.cta,
        ),
        _MedicalTileSpec(
          icon: Icons.book_outlined,
          label: 'Journal',
          subLabel: 'care notes',
          route: '/journal',
          chipColor: careblazersColors.text,
        ),
      ];

  @override
  Widget build(BuildContext context) {
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
                  PathHeaderCrumb(label: 'Medical'),
                ],
                title: 'Medical',
                backLabel: 'Back to Home',
                leadingIcon: Icons.medical_services_outlined,
              ),
            ),
            Expanded(
              child: HubGrid(
                tiles: <HubTile>[
                  for (final _MedicalTileSpec spec in _tiles)
                    HubTile(
                      key: tileKey(spec.route),
                      icon: spec.icon,
                      label: spec.label,
                      subLabel: spec.subLabel,
                      chipColor: spec.chipColor,
                      onTap: () => context.push(spec.route),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Static description of one [MedicalHubScreen] tile — the glyph, the two
/// label lines, the chip color, and the route the tile pushes.
@immutable
class _MedicalTileSpec {
  const _MedicalTileSpec({
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
