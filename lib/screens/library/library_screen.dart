import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../routing/router.dart';
import '../../seed/library_cards.dart';
import '../../theme.dart';

part 'library_screen.g.dart';

/// Wall clock the Library screen samples to pick "Today's card"
/// (BUILD_SPEC.md §5.7). Exposed as an overridable provider so widget +
/// golden tests pin a fixed date and the rotation stays deterministic
/// regardless of the host calendar. Production reads [DateTime.now].
@Riverpod(keepAlive: true)
DateTime Function() libraryScreenClock(Ref ref) => DateTime.now;

/// Ordered ids in the "Most-asked behaviors" section (BUILD_SPEC.md
/// §5.7). Locked so a stale deep-link from outside the screen can't
/// drift the section ordering.
const List<String> mostAskedBehaviorCardIds = <String>[
  'sundowning_basics',
  'anosognosia',
  'family_doesnt_believe',
  'accusations_basics',
  'five_causes',
  'step_into_reality',
];

/// Ordered ids in the "For YOU, the caregiver" section (BUILD_SPEC.md
/// §5.7).
const List<String> caregiverCardIds = <String>[
  'caregiver_guilt',
  'boundaries_compassion',
  'when_to_ask_respite',
];

/// Library tab root (BUILD_SPEC.md §5.7).
///
/// Topical primers in Dr. Natali's framework — not coaching. The screen
/// is static seed data over a [ConsumerWidget] for one reason: the
/// "Today's card" hero is sampled from [libraryScreenClockProvider] so
/// tests can pin the date and the rotation stays deterministic.
///
/// Layout (top to bottom):
///   1. "Today's card" hero — large surfaceWarm card titled + subtitled
///      with the card's hook. Tap → `/library/:id`.
///   2. "Most-asked behaviors" section — the six behavior-focused cards
///      from [mostAskedBehaviorCardIds].
///   3. "For YOU, the caregiver" section — the three caregiver-self
///      cards from [caregiverCardIds].
///
/// Tab root, so `automaticallyImplyLeading: false` keeps a stray back
/// arrow from appearing if the tab shell ever ends up nested under
/// another navigator.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  /// Widget key for the "Today's card" hero. Tests tap by key rather
  /// than by visible title so the rotation rule can change without
  /// breaking the test.
  static const Key todaysCardKey = Key('library-todays-card');

  /// Widget key for the "Most-asked behaviors" section header.
  static const Key mostAskedSectionKey = Key('library-section-most-asked');

  /// Widget key for the "For YOU, the caregiver" section header.
  static const Key caregiverSectionKey = Key('library-section-caregiver');

  /// Stable per-card tile key keyed by the card id. Tests tap by id —
  /// section assignment and visible title are independent of routing.
  static Key cardTileKey(String id) => Key('library-card-tile-$id');

  /// Computes the index of "Today's card" given a wall clock [now].
  ///
  /// `date.dayOfYear % libraryCards.length` per BUILD_SPEC.md §5.7. The
  /// year anchor and today are both expressed in UTC so spring-forward
  /// DST transitions don't make a 23-hour day round `.inDays` down by
  /// one in the months after the switch.
  @visibleForTesting
  static int todaysCardIndex(DateTime now) {
    final DateTime startOfYear = DateTime.utc(now.year);
    final DateTime today = DateTime.utc(now.year, now.month, now.day);
    final int dayOfYear = today.difference(startOfYear).inDays + 1;
    return dayOfYear % libraryCards.length;
  }

  /// Resolves "Today's card" given a wall clock [now].
  @visibleForTesting
  static LibraryCard todaysCard(DateTime now) {
    return libraryCards[todaysCardIndex(now)];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime now = ref.watch(libraryScreenClockProvider)();
    final LibraryCard today = todaysCard(now);

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Library'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: <Widget>[
            _TodaysCardHero(card: today),
            const SizedBox(height: 24),
            const _SectionHeader(
              headerKey: LibraryScreen.mostAskedSectionKey,
              label: 'Most-asked behaviors',
            ),
            const SizedBox(height: 8),
            for (final String id in mostAskedBehaviorCardIds)
              _CardTile(card: libraryCardById(id)!),
            const SizedBox(height: 24),
            const _SectionHeader(
              headerKey: LibraryScreen.caregiverSectionKey,
              label: 'For YOU, the caregiver',
            ),
            const SizedBox(height: 8),
            for (final String id in caregiverCardIds)
              _CardTile(card: libraryCardById(id)!),
          ],
        ),
      ),
    );
  }
}

/// Hero "Today's card" at the top of the screen (BUILD_SPEC.md §5.7).
/// Large surfaceWarm panel with the card title + 1-sentence hook;
/// taps push the detail route.
class _TodaysCardHero extends StatelessWidget {
  const _TodaysCardHero({required this.card});

  final LibraryCard card;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: "Today's card: ${card.title}. Double-tap to read.",
      child: Material(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(20),
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.15),
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          key: LibraryScreen.todaysCardKey,
          borderRadius: BorderRadius.circular(20),
          onTap: () => context.pushNamed(
            CareblazersRoutes.libraryCard,
            pathParameters: <String, String>{'id': card.id},
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  "Today's card",
                  style: textTheme.bodyMedium?.copyWith(
                    color: careblazersColors.primarySoft,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  card.title,
                  style: textTheme.headlineMedium?.copyWith(
                    color: careblazersColors.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  card.hook,
                  style: textTheme.bodyLarge?.copyWith(
                    color: careblazersColors.text,
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

/// Section header — small uppercase-ish label sitting between the hero
/// and a group of card tiles.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.headerKey, required this.label});

  final Key headerKey;
  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: headerKey,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        label,
        style: textTheme.titleLarge?.copyWith(
          color: careblazersColors.primarySoft,
        ),
      ),
    );
  }
}

/// One tile in a section list — title + hook, tap pushes detail.
class _CardTile extends StatelessWidget {
  const _CardTile({required this.card});

  final LibraryCard card;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '${card.title}. Double-tap to read.',
      child: Material(
        color: careblazersColors.background,
        child: InkWell(
          key: LibraryScreen.cardTileKey(card.id),
          onTap: () => context.pushNamed(
            CareblazersRoutes.libraryCard,
            pathParameters: <String, String>{'id': card.id},
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        card.title,
                        style: textTheme.bodyLarge?.copyWith(
                          color: careblazersColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        card.hook,
                        style: textTheme.bodyMedium?.copyWith(
                          color: careblazersColors.primarySoft,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: careblazersColors.primarySoft,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
