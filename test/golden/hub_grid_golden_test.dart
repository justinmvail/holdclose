import 'package:alchemist/alchemist.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/hub_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A populated Medical-style hub: six tiles across the brand chip-color
/// palette (BUILD_SPEC.md §5.13). Chip colors are [HoldcloseColors]
/// tokens — the HTML reference's coral/teal/amber/plum placeholders are
/// discarded per docs/MENU_LAYOUT_SPEC.md.
final List<HubTile> _tiles = <HubTile>[
  HubTile(
    icon: Icons.medication_outlined,
    label: 'Medications',
    subLabel: 'doses & reminders',
    chipColor: holdcloseColors.primary,
    onTap: () {},
  ),
  HubTile(
    icon: Icons.schedule_outlined,
    label: 'Medication Schedule',
    subLabel: 'daily timeline',
    chipColor: holdcloseColors.cta,
    onTap: () {},
  ),
  HubTile(
    icon: Icons.event_outlined,
    label: 'Appointments',
    subLabel: 'calendar & visits',
    chipColor: holdcloseColors.accentDeep,
    onTap: () {},
  ),
  HubTile(
    icon: Icons.favorite_outline,
    label: 'Health Log',
    subLabel: 'symptoms & vitals',
    chipColor: holdcloseColors.link,
    onTap: () {},
  ),
  HubTile(
    icon: Icons.list_alt_outlined,
    label: 'Care Plan',
    subLabel: 'routine & stages',
    chipColor: holdcloseColors.success,
    onTap: () {},
  ),
  HubTile(
    icon: Icons.badge_outlined,
    label: 'Cards & Documents',
    subLabel: 'emergency card, POA, IDs',
    chipColor: holdcloseColors.primarySoft,
    onTap: () {},
  ),
];

/// Bounds the scrolling [HubGrid] to a phone-sized box so the golden
/// renders at a stable width with no unbounded-height error. No theme is
/// passed — per `flutter_test_config.dart`, goldens avoid pulling
/// google_fonts through the framework; [HubTile] re-applies its brand
/// colors directly.
Widget _host(Widget grid) => Container(
      width: 412,
      height: 560,
      color: holdcloseColors.background,
      child: Material(
        color: holdcloseColors.background,
        child: grid,
      ),
    );

void main() {
  group('HubGrid golden', () {
    goldenTest(
      'renders a populated 6-tile 2-column hub',
      fileName: 'hub_grid',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'medical hub — 6 tiles',
            child: _host(HubGrid(tiles: _tiles)),
          ),
        ],
      ),
    );
  });
}
