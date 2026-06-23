import 'package:holdclose/services/log_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The buffer is a process-wide singleton; reset between cases.
  setUp(() => LogBuffer.instance.clear());

  group('LogBuffer', () {
    test('starts empty', () {
      expect(LogBuffer.instance.snapshot(), '');
      expect(LogBuffer.instance.length, 0);
    });

    test('appends lines, oldest first, and ignores blanks', () {
      LogBuffer.instance.add('first');
      LogBuffer.instance.add('');
      LogBuffer.instance.add('second');
      expect(LogBuffer.instance.snapshot(), 'first\nsecond');
    });

    test('splits a multi-line entry into separate lines', () {
      LogBuffer.instance.add('a\nb\nc');
      expect(LogBuffer.instance.length, 3);
      expect(LogBuffer.instance.snapshot(), 'a\nb\nc');
    });

    test('evicts oldest lines past the cap (stays bounded)', () {
      for (int i = 0; i < LogBuffer.maxLines + 50; i++) {
        LogBuffer.instance.add('line $i');
      }
      expect(LogBuffer.instance.length, LogBuffer.maxLines);
      // The earliest lines were dropped; the newest survive.
      expect(LogBuffer.instance.snapshot(), isNot(contains('line 0')));
      expect(
        LogBuffer.instance.snapshot(),
        contains('line ${LogBuffer.maxLines + 49}'),
      );
    });
  });
}
