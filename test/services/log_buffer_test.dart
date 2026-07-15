import 'package:flutter/foundation.dart';
import 'package:holdclose/services/log_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The buffer is a process-wide singleton; reset between cases.
  setUp(() => LogBuffer.instance.clear());

  group('logNonFatal — the anti-swallow breadcrumb', () {
    // The value of this helper is that its output rides debugPrint into
    // LogBuffer, which rides into "report a problem". So the contract that
    // matters is: it debugPrints a line carrying BOTH the site tag and the
    // error, so a swallowed failure is diagnosable from a tester's report.
    List<String> captureDebugPrint(void Function() body) {
      final List<String> out = <String>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => out.add(message ?? '');
      try {
        body();
      } finally {
        debugPrint = original;
      }
      return out;
    }

    test('emits one line carrying the site tag AND the error', () {
      final List<String> lines = captureDebugPrint(
        () => logNonFatal('scan.prescription', Exception('licence 5016')),
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('scan.prescription'));
      expect(lines.single, contains('licence 5016'));
      expect(lines.single, contains('non-fatal'));
    });

    test('includes the top stack frames only when a stack is passed', () {
      final List<String> lines = captureDebugPrint(
        () => logNonFatal('x', 'boom', StackTrace.current),
      );
      // The tag line, then a (truncated) stack line.
      expect(lines.length, greaterThanOrEqualTo(2));
    });
  });

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
