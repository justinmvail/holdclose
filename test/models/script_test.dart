import 'package:careblazers/models/script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Script JSON round-trip', () {
    test('round-trips a text-only script (no audio attachment)', () {
      const Script original = Script(
        text: "I'm right here with you.",
      );
      final Script parsed = Script.fromJson(original.toJson());
      expect(parsed, equals(original));
      expect(parsed.audioPath, isNull);
    });

    test('round-trips a script with attached audio path', () {
      const Script original = Script(
        text: 'Mom, it\'s okay.',
        audioPath: 'assets/audio/natali/calming-01.m4a',
      );
      expect(Script.fromJson(original.toJson()), equals(original));
    });
  });
}
