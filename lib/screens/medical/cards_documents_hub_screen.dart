import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme.dart';
import '../../widgets/hub_tile.dart';
import '../../widgets/path_header.dart';

/// The Cards & Documents sub-hub at `/medical/cards` (BUILD_SPEC.md §5.13,
/// TASKS.md Phase 14.22) — the loved one's quick-reach legal + identity
/// papers, one rung below the Medical hub.
///
/// Unlike [MedicalHubScreen] (a top-level landing), this is a **nested
/// hub**: the [PathHeader] carries the `Home › Medical` trail plus a
/// word-labeled Back control to Medical, then the page title "Cards &
/// Documents". The body is a [HubGrid] of three [HubTile]s; each pushes
/// its detail page. Emergency Card resolves today (Phase 14.5 /
/// 14.23); Power of Attorney + Identification gain routes in their own
/// phases.
class CardsDocumentsHubScreen extends StatelessWidget {
  const CardsDocumentsHubScreen({super.key});

  /// Stable per-tile key derived from the tile's destination route. Tests
  /// tap by route rather than by visible label so a copy edit doesn't
  /// break them.
  static Key tileKey(String route) => Key('cards-hub-tile-$route');

  /// The three hub tiles, left-to-right / top-to-bottom (BUILD_SPEC.md
  /// §5.13). Chip colors are [CareblazersColors] tokens — the layout
  /// spec's coral/navy/teal placeholders map onto the brand palette:
  /// orange → [CareblazersColors.cta], navy → [CareblazersColors.primary],
  /// teal → [CareblazersColors.link] (the only cool interactive accent).
  static List<_CardsTileSpec> get _tiles => <_CardsTileSpec>[
        _CardsTileSpec(
          icon: Icons.emergency_outlined,
          label: 'Emergency Card',
          subLabel: 'who to call, fast',
          route: '/medical/cards/emergency',
          chipColor: careblazersColors.cta,
        ),
        _CardsTileSpec(
          icon: Icons.gavel_outlined,
          label: 'Power of Attorney',
          subLabel: 'legal authority',
          route: '/medical/cards/poa',
          chipColor: careblazersColors.primary,
        ),
        _CardsTileSpec(
          icon: Icons.badge_outlined,
          label: 'Identification',
          subLabel: 'IDs & insurance',
          route: '/medical/cards/ids',
          chipColor: careblazersColors.link,
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
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Medical', route: '/medical'),
                ],
                title: 'Cards & Documents',
                backLabel: 'Back to Medical',
                leadingIcon: Icons.badge_outlined,
              ),
            ),
            Expanded(
              child: HubGrid(
                tiles: <HubTile>[
                  for (final _CardsTileSpec spec in _tiles)
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

/// Static description of one [CardsDocumentsHubScreen] tile — the glyph,
/// the two label lines, the chip color, and the route the tile pushes.
@immutable
class _CardsTileSpec {
  const _CardsTileSpec({
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
