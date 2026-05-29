import 'package:careblazers/models/decoder_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DecoderResult JSON round-trip', () {
    test('round-trips a typical 3-say / 1-tweak / 1-dontSay result', () {
      final DecoderResult original = DecoderResult(
        say: const <String>[
          "That sounds really hard. I'm right here with you.",
          "Let's sit together for a moment.",
          "I'm going to dim the lights.",
        ],
        tweak: const <String>[
          'Dim overhead lights and switch on a single warm lamp.',
        ],
        dontSay: const <String>[
          "Don't say 'you already asked me that'.",
        ],
        generatedAt: DateTime.utc(2026, 5, 29, 19, 42),
      );
      expect(
        DecoderResult.fromJson(original.toJson()),
        equals(original),
      );
    });

    test('serializes dontSay under the snake_case key dont_say', () {
      final DecoderResult result = DecoderResult(
        say: const <String>['x'],
        tweak: const <String>['y'],
        dontSay: const <String>['z'],
        generatedAt: DateTime.utc(2026, 1, 1),
      );
      final Map<String, dynamic> json = result.toJson();
      expect(json.containsKey('dont_say'), isTrue);
      expect(json.containsKey('dontSay'), isFalse);
      expect(json['dont_say'], <String>['z']);
    });

    test('handles empty lists', () {
      final DecoderResult empty = DecoderResult(
        say: const <String>[],
        tweak: const <String>[],
        dontSay: const <String>[],
        generatedAt: DateTime.utc(2026, 5, 29),
      );
      expect(DecoderResult.fromJson(empty.toJson()), equals(empty));
    });
  });
}
