import 'package:careblazers/models/behavior.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Behavior.canonical', () {
    test('exposes exactly 8 instances (BUILD_SPEC.md §5.2)', () {
      expect(Behavior.canonical, hasLength(8));
    });

    test('ids match BUILD_SPEC.md §5.2 verbatim', () {
      expect(
        Behavior.canonical.map((Behavior b) => b.id).toList(),
        <String>[
          'upset',
          'refusing_care',
          'wants_home',
          'asking_for_someone',
          'accusing',
          'sundowning',
          'wandering',
          'hallucinating',
        ],
      );
    });

    test('labels match BUILD_SPEC.md §5.2 verbatim', () {
      expect(
        Behavior.canonical.map((Behavior b) => b.label).toList(),
        <String>[
          'Upset / crying',
          'Refusing care',
          '"I want to go home"',
          'Asking for someone',
          'Accusing me',
          'Sundowning',
          'Wandering / pacing',
          'Seeing things',
        ],
      );
    });

    test('glyphs match BUILD_SPEC.md §5.2 verbatim', () {
      expect(
        Behavior.canonical.map((Behavior b) => b.glyph).toList(),
        <String>['💔', '🚪', '🏠', '👤', '💸', '🌅', '🚶', '👁'],
      );
    });

    test('ids are unique', () {
      final Set<String> ids =
          Behavior.canonical.map((Behavior b) => b.id).toSet();
      expect(ids, hasLength(Behavior.canonical.length));
    });
  });

  group('Behavior.byId', () {
    test('returns the canonical instance for a known id', () {
      expect(Behavior.byId('sundowning')?.glyph, '🌅');
      expect(Behavior.byId('accusing')?.label, 'Accusing me');
    });

    test('returns null for an unknown id (free-text path)', () {
      expect(Behavior.byId('something-else'), isNull);
      expect(Behavior.byId(''), isNull);
    });
  });

  group('Behavior JSON round-trip', () {
    test('round-trips every canonical instance unchanged', () {
      for (final Behavior original in Behavior.canonical) {
        final Behavior parsed = Behavior.fromJson(original.toJson());
        expect(parsed, equals(original));
      }
    });

    test('handles arbitrary id/label/glyph (free-text behavior)', () {
      const Behavior freeform = Behavior(
        id: 'freetext-pacing-bathroom',
        label: 'Pacing near the bathroom',
        glyph: '✍',
      );
      expect(Behavior.fromJson(freeform.toJson()), equals(freeform));
    });
  });
}
