import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/settings.dart';
import '../../providers/settings_provider.dart';
import '../../theme.dart';
import '../../widgets/hub_tile.dart';
import '../../widgets/path_header.dart';

/// The Care tile-hub at `/medical` (route path kept internal) — the single
/// entry point to everything about caring for your person: meds, schedule,
/// appointments, health log, routines, the emergency card, the journal,
/// and (when team coordination is on) the Care Circle of helpers.
///
/// Renamed from "Medical" (2026-06-06) — the clinical word was off-brand —
/// and the former separate "Team" tab folded in here as the gated **Care
/// Circle** tile.
///
/// This is a **landing screen**: the [PathHeader] carries a single crumb
/// ("Care") so it renders the title row only — no breadcrumb trail and no
/// Back control (you reach the hub by tapping the Care tab, and re-tapping
/// it pops the branch back here). Each tile pushes its feature page.
class MedicalHubScreen extends ConsumerWidget {
  const MedicalHubScreen({super.key});

  /// Stable per-tile key derived from the tile's destination route. Tests
  /// tap by route rather than by visible label so a copy edit doesn't
  /// break them.
  static Key tileKey(String route) => Key('medical-hub-tile-$route');

  /// The Care hub tiles. The trailing **Care Circle** tile only appears
  /// when [includeCareCircle] (the team-coordination toggle) is on — a
  /// solo caregiver never sees the coordination hub.
  static List<_MedicalTileSpec> _tilesFor(
    BuildContext context, {
    required bool includeCareCircle,
  }) =>
      <_MedicalTileSpec>[
        _MedicalTileSpec(
          icon: Icons.document_scanner_outlined,
          label: 'Scan a document',
          subLabel: 'Rx, appointment, insurance card',
          route: '/scan',
          chipColor: context.cb.primary,
        ),
        _MedicalTileSpec(
          icon: Icons.person_search_outlined,
          label: 'Find a provider',
          subLabel: 'search clinicians (NPI)',
          route: '/find-provider',
          chipColor: context.cb.link,
        ),
        _MedicalTileSpec(
          icon: Icons.summarize_outlined,
          label: 'Care summary',
          subLabel: 'share with a clinician',
          route: '/care-summary',
          chipColor: context.cb.accentDeep,
        ),
        _MedicalTileSpec(
          icon: Icons.medication_outlined,
          label: 'Medications',
          subLabel: 'doses & reminders',
          route: '/medications',
          chipColor: context.cb.primary,
        ),
        _MedicalTileSpec(
          icon: Icons.schedule_outlined,
          label: 'Schedule',
          subLabel: 'today, tomorrow, this week',
          route: '/team/calendar?from=medical',
          chipColor: context.cb.cta,
        ),
        _MedicalTileSpec(
          icon: Icons.event_outlined,
          label: 'Appointments',
          subLabel: 'calendar & visits',
          route: '/appointments',
          chipColor: context.cb.accentDeep,
        ),
        _MedicalTileSpec(
          icon: Icons.monitor_heart_outlined,
          label: 'Health Log',
          subLabel: 'symptoms & vitals',
          route: '/medical/health-log',
          chipColor: context.cb.link,
        ),
        _MedicalTileSpec(
          icon: Icons.assignment_outlined,
          label: 'Routines',
          subLabel: 'scheduled care tasks',
          route: '/medical/routines',
          chipColor: context.cb.success,
        ),
        _MedicalTileSpec(
          icon: Icons.shield_outlined,
          label: 'Emergency Card',
          subLabel: 'info for first responders',
          route: '/medical/cards/emergency',
          chipColor: context.cb.cta,
        ),
        _MedicalTileSpec(
          icon: Icons.book_outlined,
          label: 'Journal',
          subLabel: 'care notes',
          route: '/journal',
          chipColor: context.cb.text,
        ),
        if (includeCareCircle)
          _MedicalTileSpec(
            icon: Icons.diversity_3_outlined,
            label: 'Care Circle',
            subLabel: 'helpers, shifts & tasks',
            route: '/team',
            chipColor: context.cb.accentDeep,
          ),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool teamOn = ref.watch(
      settingsProvider.select((AppSettings s) => s.teamCoordinationEnabled),
    );
    final List<_MedicalTileSpec> tiles =
        _tilesFor(context, includeCareCircle: teamOn);
    return Scaffold(
      backgroundColor: context.cb.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              // Single crumb → PathHeader suppresses the breadcrumb row
              // and the Back control, rendering the title row only.
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Care'),
                ],
                title: 'Care',
                backLabel: 'Back to Home',
                leadingIcon: Icons.volunteer_activism_outlined,
              ),
            ),
            Expanded(
              child: HubGrid(
                tiles: <HubTile>[
                  for (final _MedicalTileSpec spec in tiles)
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
