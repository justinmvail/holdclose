import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/seed/library_cards.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 12 canonical card ids locked by BUILD_SPEC.md §9.4 — listed in
/// the order the spec lists them. The Library screen (Task 22) computes
/// "Today's card" by `date.dayOfYear % libraryCards.length`, so the
/// order doubles as the rotation order and must not drift.
const List<String> _expectedIds = <String>[
  'anosognosia',
  'sundowning_basics',
  'respond_to_emotion',
  'five_causes',
  'step_into_reality',
  'accusations_basics',
  'wanting_to_go_home',
  'family_doesnt_believe',
  'caregiver_guilt',
  'boundaries_compassion',
  'when_to_ask_respite',
  'showtime',
];

int _wordCount(String text) {
  return text
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .length;
}

void main() {
  group('libraryCards seed', () {
    test('exposes exactly 12 cards (BUILD_SPEC.md §9.4)', () {
      expect(libraryCards, hasLength(12));
    });

    test('ids match BUILD_SPEC.md §9.4 verbatim, in spec order', () {
      expect(
        libraryCards.map((LibraryCard c) => c.id).toList(),
        _expectedIds,
      );
    });

    test('ids are unique', () {
      final Set<String> ids =
          libraryCards.map((LibraryCard c) => c.id).toSet();
      expect(ids, hasLength(libraryCards.length));
    });

    test('every card has a non-empty title, hook, and body', () {
      for (final LibraryCard card in libraryCards) {
        expect(card.title.trim(), isNotEmpty, reason: 'title for ${card.id}');
        expect(card.hook.trim(), isNotEmpty, reason: 'hook for ${card.id}');
        expect(card.body.trim(), isNotEmpty, reason: 'body for ${card.id}');
      }
    });

    test('every hook is short enough for a one-line summary (§9.4)', () {
      // §9.4 calls for a one-sentence hook. We enforce the structural
      // shape (short, single-beat copy) via a word-count cap rather
      // than punctuation analysis — quoted scripts inside a hook
      // contain periods but still read as one beat of caregiver copy.
      for (final LibraryCard card in libraryCards) {
        expect(
          _wordCount(card.hook),
          lessThanOrEqualTo(25),
          reason: 'hook for ${card.id} is too long for a one-line summary',
        );
      }
    });

    test('every body is a 50–80 word placeholder (§9.4 + Task 21)', () {
      for (final LibraryCard card in libraryCards) {
        final int words = _wordCount(card.body);
        expect(
          words,
          inInclusiveRange(50, 80),
          reason: 'body for ${card.id} has $words words; spec is 50–80',
        );
      }
    });

    test('every card declares at least one related behavior', () {
      for (final LibraryCard card in libraryCards) {
        expect(
          card.relatedBehaviorIds,
          isNotEmpty,
          reason: 'relatedBehaviorIds for ${card.id}',
        );
      }
    });

    test(
        'every related behavior id is a real canonical behavior '
        '(BUILD_SPEC.md §5.2)', () {
      final Set<String> canonicalIds =
          Behavior.canonical.map((Behavior b) => b.id).toSet();
      for (final LibraryCard card in libraryCards) {
        for (final String behaviorId in card.relatedBehaviorIds) {
          expect(
            canonicalIds,
            contains(behaviorId),
            reason: '${card.id} references unknown behavior "$behaviorId"',
          );
        }
      }
    });

    test(
        'related behavior ids on a single card are unique '
        '(no duplicate chips in the detail screen)', () {
      for (final LibraryCard card in libraryCards) {
        expect(
          card.relatedBehaviorIds.toSet(),
          hasLength(card.relatedBehaviorIds.length),
          reason: '${card.id} has duplicate relatedBehaviorIds',
        );
      }
    });
  });

  group('libraryCardById', () {
    test('returns the matching card for a known id', () {
      final LibraryCard? card = libraryCardById('sundowning_basics');
      expect(card, isNotNull);
      expect(card!.title, "What's happening between 4pm and bedtime");
    });

    test('returns null for an unknown id', () {
      expect(libraryCardById('not-a-real-card'), isNull);
      expect(libraryCardById(''), isNull);
    });

    test('round-trips every canonical id', () {
      for (final LibraryCard card in libraryCards) {
        expect(libraryCardById(card.id), same(card));
      }
    });
  });
}
