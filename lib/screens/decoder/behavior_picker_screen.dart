import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/behavior.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Arguments passed via `GoRouterState.extra` from the behavior picker
/// (BUILD_SPEC.md §5.2) into the triage screen (§5.3).
///
/// Two paths:
///   - [TriageArgs.forBehavior] — caregiver picked one of the 8 canonical
///     cards; [behavior] is the chosen [Behavior].
///   - [TriageArgs.freeText] — caregiver tapped "Something else —
///     describe it"; [freeText] is true and [behavior] is null. The
///     triage screen surfaces a free-text input instead of the
///     pre-canned behavior chip.
@immutable
class TriageArgs {
  const TriageArgs.forBehavior(Behavior selected)
      : behavior = selected,
        freeText = false;
  const TriageArgs.freeText()
      : behavior = null,
        freeText = true;

  final Behavior? behavior;
  final bool freeText;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TriageArgs &&
          other.behavior == behavior &&
          other.freeText == freeText);

  @override
  int get hashCode => Object.hash(behavior, freeText);
}

/// Behavior picker (BUILD_SPEC.md §5.2).
///
/// 4×2 grid of the 8 canonical behaviors plus a full-width
/// "Something else — describe it" pill underneath. Each card pushes
/// `/decoder/triage` with a [TriageArgs] payload so the triage screen
/// knows which path it's on. Stateless — selection routes directly,
/// no provider involvement.
class BehaviorPickerScreen extends StatelessWidget {
  const BehaviorPickerScreen({super.key});

  /// Widget key for the 4×2 grid; tests use this to scope a search.
  static const Key gridKey = Key('behavior-picker-grid');

  /// Widget key for the "Something else — describe it" pill.
  static const Key freeTextKey = Key('behavior-picker-free-text');

  /// Stable per-card key derived from the behavior id. Tests tap by
  /// id rather than by visible label so a copy edit doesn't break the
  /// test.
  static Key cardKey(String behaviorId) => Key('behavior-card-$behaviorId');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.cb.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Journal', route: '/journal'),
                  PathHeaderCrumb(label: "What's happening?"),
                ],
                title: "What's happening?",
                backLabel: 'Back to Journal',
                leadingIcon: Icons.psychology_outlined,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.count(
                  key: gridKey,
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  // Aspect ratio chosen so all 4 rows fit within a
                  // typical iPhone viewport (≈ 780 logical pt). Default
                  // scroll physics — degrades gracefully on shorter
                  // devices / larger font sizes rather than overflowing.
                  childAspectRatio: 1.35,
                  children: <Widget>[
                    for (final Behavior b in Behavior.canonical)
                      _BehaviorCard(
                        behavior: b,
                        onTap: () => context.push(
                          '/decoder/triage',
                          extra: TriageArgs.forBehavior(b),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SomethingElsePill(
                onTap: () => context.push(
                  '/decoder/triage',
                  extra: const TriageArgs.freeText(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One card in the 4×2 behavior grid. Glyph on top, 2-line label
/// under, surfaceWarm background with rounded corners and a soft
/// shadow per BUILD_SPEC.md §5.2.
class _BehaviorCard extends StatelessWidget {
  const _BehaviorCard({required this.behavior, required this.onTap});

  final Behavior behavior;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Behavior: ${behavior.label}. Double-tap to select.',
      child: Material(
        color: context.cb.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        // Material 3 tints elevated surfaces by default; the brand
        // surfaceWarm is the source of truth — keep it untinted.
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          key: BehaviorPickerScreen.cardKey(behavior.id),
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  behavior.glyph,
                  style: const TextStyle(fontSize: 32),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: Text(
                    behavior.label,
                    style: textTheme.titleLarge?.copyWith(
                      color: context.cb.primary,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-width pill below the grid for the free-text path
/// (BUILD_SPEC.md §5.2). Surfaces the same triage screen but with the
/// [TriageArgs.freeText] flag set.
class _SomethingElsePill extends StatelessWidget {
  const _SomethingElsePill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Something else. Double-tap to describe the behavior yourself.',
      child: Material(
        color: context.cb.surfaceWarm,
        borderRadius: BorderRadius.circular(32),
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.15),
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          key: BehaviorPickerScreen.freeTextKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(32),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Text('✍', style: TextStyle(fontSize: 20)),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Something else — describe it',
                    style: textTheme.labelLarge?.copyWith(
                      color: context.cb.primary,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
