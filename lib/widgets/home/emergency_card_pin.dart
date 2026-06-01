import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../routing/router.dart';
import '../../theme.dart';

/// The pinned Emergency Card — the first row of the Home dashboard
/// ListView (BUILD_SPEC.md Phase 14.8).
///
/// A full-width, orange→deeper-orange gradient card (the
/// [CareblazersColors.cta] → [CareblazersColors.accentDeep] brand pair)
/// carrying a white shield in a 34px chip, a bold **Emergency Card**
/// label, and a "One tap — info for first responders" sub-label. The
/// whole card is one tap target: it pushes the Emergency Card route
/// (`/medical/cards/emergency`, registered as
/// [CareblazersRoutes.medicalCardsEmergency] back in Phase 14.5) onto the
/// root navigator.
///
/// The card owns no state and reads no providers — it renders the same
/// whether or not the destination screen exists yet (today the route
/// resolves to the interim Crisis Card; Phase 14.23 swaps in the real
/// Emergency Card screen). Because the orange CTA is constant across light
/// and dark (per `theme.dart`), the card is brand-accurate in both modes
/// without reading [Theme].
///
/// Accessibility: the visual text is hidden from the semantics tree and
/// replaced with a single button node reading
/// "Emergency Card. Show to first responders." — a screen-reader caller
/// in a real emergency hears the purpose, not the decorative sub-label.
class EmergencyCardPin extends StatelessWidget {
  const EmergencyCardPin({super.key});

  /// Tap target + golden/test handle for the whole card.
  static const Key cardKey = Key('home-emergency-card-pin');

  /// What a screen reader announces for the card. Kept terse and
  /// action-first so it's useful when read aloud under stress.
  static const String semanticLabel =
      'Emergency Card. Show to first responders.';

  static const double _cardRadius = 18;
  static const double _chipSize = 34;
  static const double _chipRadius = 11;
  static const double _iconSize = 20;

  void _open(BuildContext context) {
    GoRouter.of(context).pushNamed(CareblazersRoutes.medicalCardsEmergency);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color onCard = careblazersColors.background; // warm white on orange
    final TextStyle labelStyle =
        (textTheme.titleLarge ?? const TextStyle()).copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      color: onCard,
    );
    final TextStyle subLabelStyle =
        (textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: 13,
      // Slightly recede the descriptor so the bold label leads.
      color: onCard.withValues(alpha: 0.92),
    );

    return Semantics(
      key: cardKey,
      container: true,
      button: true,
      label: semanticLabel,
      // The visual subtree is hidden from semantics, so the activate
      // action lives on this node directly (it mirrors the InkWell tap).
      onTap: () => _open(context),
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(_cardRadius),
          child: InkWell(
            onTap: () => _open(context),
            borderRadius: BorderRadius.circular(_cardRadius),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_cardRadius),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    Color(0xFFC97458), // cta — orange
                    Color(0xFFB05C40), // accentDeep — deeper orange
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: _chipSize,
                      height: _chipSize,
                      decoration: BoxDecoration(
                        // A translucent white chip lifts the shield off
                        // the orange field without a second brand color.
                        color: onCard.withValues(alpha: 0.20),
                        borderRadius: BorderRadius.circular(_chipRadius),
                      ),
                      child: Icon(
                        Icons.shield_outlined,
                        size: _iconSize,
                        color: onCard,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text('Emergency Card', style: labelStyle),
                          const SizedBox(height: 2),
                          Text(
                            'One tap — info for first responders',
                            style: subLabelStyle,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right,
                      color: onCard.withValues(alpha: 0.85),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
