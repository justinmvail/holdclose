import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../routing/router.dart';
import '../theme.dart';

/// Home tab root (BUILD_SPEC.md §5.1).
///
/// One-tap solves the crisis: the screen is dominated by a single
/// `displayLarge` "What's happening / right now?" target that pushes
/// `/decoder/behavior`. The AppBar carries the gear that pushes
/// `/settings`. Two small secondary rows below the divider cover
/// "Quick reassurance" and "Doctor visit prep" — they're deliberately
/// understated so the primary tap target wins.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// Widget key for the giant tap target. Tests use this to locate the
  /// area without depending on its visible copy.
  static const Key primaryTargetKey = Key('home-primary-target');

  /// Widget key for the gear icon in the AppBar.
  static const Key settingsGearKey = Key('home-settings-gear');

  /// Widget key for the "Quick reassurance" row.
  static const Key quickReassuranceKey = Key('home-quick-reassurance');

  /// Widget key for the "Doctor visit prep" row.
  static const Key doctorVisitPrepKey = Key('home-doctor-visit-prep');

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: careblazersColors.surfaceWarm,
      appBar: AppBar(
        title: const Text('Careblazers'),
        // Home is a tab root — never show an auto back arrow even if
        // the route stack ever ends up with a parent.
        automaticallyImplyLeading: false,
        actions: <Widget>[
          IconButton(
            key: settingsGearKey,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Semantics(
                button: true,
                label: "What's happening right now? Tap to start.",
                child: InkWell(
                  key: primaryTargetKey,
                  onTap: () => context.push('/decoder/behavior'),
                  child: Container(
                    width: double.infinity,
                    color: careblazersColors.surfaceWarm,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 32,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          Text(
                            "What's happening",
                            style: textTheme.displayLarge,
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            'right now?',
                            style: textTheme.displayLarge,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '[tap to start]',
                            style: textTheme.bodyLarge?.copyWith(
                              color: careblazersColors.primarySoft,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1, thickness: 1),
            _SecondaryRow(
              rowKey: quickReassuranceKey,
              label: 'Quick reassurance',
              onTap: () => context.pushNamed(CareblazersRoutes.libraryCard,
                  pathParameters: <String, String>{'id': 'respond_to_emotion'}),
            ),
            _SecondaryRow(
              rowKey: doctorVisitPrepKey,
              label: 'Doctor visit prep',
              // Journal is a tab-bar branch (not a root-navigator
              // route), so we switch to its tab rather than push it
              // on top of the Home navigator. The "filtered to last
              // 30 days" affordance from BUILD_SPEC.md §5.1 lands when
              // task 17 builds the Journal screen.
              onTap: () => context.go('/journal'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the small "secondary actions" stack at the bottom of
/// Home. Looks like a `ListTile` but renders against `surfaceWarm` so
/// the divider above stays clean and the tap target stays visually
/// subordinate to the primary "What's happening right now?" area.
class _SecondaryRow extends StatelessWidget {
  const _SecondaryRow({
    required this.rowKey,
    required this.label,
    required this.onTap,
  });

  final Key rowKey;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Material(
      color: careblazersColors.surfaceWarm,
      child: InkWell(
        key: rowKey,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: textTheme.titleLarge?.copyWith(
                    color: careblazersColors.primary,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward,
                color: careblazersColors.primarySoft,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
