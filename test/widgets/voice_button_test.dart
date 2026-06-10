import 'dart:async';

import 'package:careblazers/providers/voice_capture_provider.dart';
import 'package:careblazers/services/voice_intake.dart';
import 'package:careblazers/widgets/voice_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// A [VoiceCapture] whose result is supplied per test. When [completer]
/// is set, [capture] awaits it so a test can hold the future open and
/// inspect the in-flight (disabled + spinner) state.
class _ProgrammableVoiceCapture implements VoiceCapture {
  _ProgrammableVoiceCapture({this.result, this.completer});

  final String? result;
  final Completer<String?>? completer;

  @override
  Future<String?> capture({void Function(String partial)? onPartial}) {
    if (completer != null) return completer!.future;
    return Future<String?>.value(result);
  }
}

/// A [VoiceCapture] that always reports the mic permission as denied.
class _DeniedVoiceCapture implements VoiceCapture {
  const _DeniedVoiceCapture();

  @override
  Future<String?> capture({void Function(String partial)? onPartial}) async =>
      throw const VoiceCapturePermissionDeniedException();
}

Future<void> _pump(
  WidgetTester tester, {
  required VoiceCapture capture,
  required ValueChanged<String> onTranscript,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        voiceCaptureProvider.overrideWithValue(capture),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: VoiceButton(onTranscript: onTranscript)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('forwards a captured transcript to onTranscript',
      (WidgetTester tester) async {
    final List<String> captured = <String>[];
    await _pump(
      tester,
      capture: _ProgrammableVoiceCapture(result: '  morning was rough  '),
      onTranscript: captured.add,
    );

    await tester.tap(find.byType(VoiceButton));
    await tester.pumpAndSettle();

    // Trimmed before forwarding.
    expect(captured, <String>['morning was rough']);
  });

  testWidgets('a null capture does not call onTranscript',
      (WidgetTester tester) async {
    final List<String> captured = <String>[];
    await _pump(
      tester,
      capture: _ProgrammableVoiceCapture(),
      onTranscript: captured.add,
    );

    await tester.tap(find.byType(VoiceButton));
    await tester.pumpAndSettle();

    expect(captured, isEmpty);
  });

  testWidgets(
      'a permission-denied capture surfaces the snackbar and does not '
      'forward', (WidgetTester tester) async {
    final List<String> captured = <String>[];
    await _pump(
      tester,
      capture: const _DeniedVoiceCapture(),
      onTranscript: captured.add,
    );

    await tester.tap(find.byType(VoiceButton));
    await tester.pump(); // run the capture future + rebuild
    await tester.pump(); // animate the snackbar in

    expect(find.text(voiceCapturePermissionDeniedMessage), findsOneWidget);
    expect(captured, isEmpty);
    // Settles back to the idle mic — the button is usable again.
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });

  testWidgets('shows a progress ring and disables while capturing',
      (WidgetTester tester) async {
    final Completer<String?> completer = Completer<String?>();
    final List<String> captured = <String>[];
    await _pump(
      tester,
      capture: _ProgrammableVoiceCapture(completer: completer),
      onTranscript: captured.add,
    );

    expect(find.byIcon(Icons.mic_none), findsOneWidget);

    await tester.tap(find.byType(VoiceButton));
    await tester.pump(); // start capture, rebuild into the in-flight state

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final IconButton button =
        tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull); // disabled mid-capture

    completer.complete('done');
    await tester.pumpAndSettle();

    // Settles back to the idle mic, transcript forwarded.
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(captured, <String>['done']);
  });
}
