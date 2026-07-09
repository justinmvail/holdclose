import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:holdclose/main.dart' show CrashLog;
import 'package:holdclose/providers/auth_provider.dart';
import 'package:holdclose/providers/voice_capture_provider.dart';
import 'package:holdclose/services/feedback_service.dart';
import 'package:holdclose/services/log_buffer.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/feedback/feedback_sheet.dart';
import 'package:holdclose/widgets/holdclose_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// A real (decodable) 1×1 transparent PNG, so the sheet's screenshot
/// thumbnail (`Image.memory`) doesn't throw a decode error in the test.
final Uint8List _onePxPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  // The sheet's initState reads the on-device [CrashLog]. Default the test
  // seams to synchronous no-crash fakes so no widget test fires real dart:io
  // (which would cross the fake-async boundary and flake). Individual crash
  // tests override [crashLogReader] to return a canned trace.
  setUp(() {
    FeedbackSheet.crashLogReader = () async => '';
    FeedbackSheet.crashLogClearer = () async {};
  });
  tearDown(() {
    FeedbackSheet.crashLogReader = CrashLog.instance.read;
    FeedbackSheet.crashLogClearer = CrashLog.instance.clear;
  });

  /// Give the modal sheet enough vertical room to lay out its full content
  /// (name/message + the screenshot / logs / crash consent rows + Send)
  /// without any control sitting below the 800×600 default test viewport —
  /// otherwise a tap on a lower toggle/button misses. Call at the start of a
  /// test BEFORE pumping (setSurfaceSize must run inside the test body, not
  /// setUp).
  Future<void> tall(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget host({
    required FeedbackController controller,
    required TesterNameStore nameStore,
    Uint8List? screenshot,
    String route = '/medical/medications',
    AuthState authState = const AuthState.signedOut(),
    VoiceCapture? voiceCapture,
  }) {
    return ProviderScope(
      overrides: <Override>[
        feedbackControllerProvider.overrideWithValue(controller),
        testerNameStoreProvider.overrideWithValue(nameStore),
        authBackendProvider.overrideWithValue(_StubAuth(authState)),
        if (voiceCapture != null)
          voiceCaptureProvider.overrideWithValue(voiceCapture),
      ],
      child: MaterialApp(
        theme: holdcloseLightTheme,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => ElevatedButton(
              onPressed: () =>
                  showFeedbackSheet(ctx, route: route, screenshot: screenshot),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('known tester: pick category, type, send → submits + pops',
      (WidgetTester tester) async {
    await tall(tester);
    final _RecordingController controller = _RecordingController();
    await tester.pumpWidget(host(
      controller: controller,
      nameStore: _FakeNameStore('Sam'),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(FeedbackSheet.sheetKey), findsOneWidget);
    // Name already known → no name prompt.
    expect(find.byKey(FeedbackSheet.nameFieldKey), findsNothing);

    await tester.tap(
        find.byKey(FeedbackSheet.categoryKey(FeedbackCategory.idea)));
    await tester.pump();
    await tester.enterText(
        find.byKey(FeedbackSheet.messageFieldKey), 'The button is hard to find');
    await tester.pump();
    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.submitted, isNotNull);
    expect(controller.submitted!.category, FeedbackCategory.idea);
    expect(controller.submitted!.message, 'The button is hard to find');
    expect(controller.submitted!.route, '/medical/medications');
    expect(controller.submitted!.testerName, 'Sam');
    expect(find.byKey(FeedbackSheet.sheetKey), findsNothing); // popped
  });

  testWidgets('first report asks for a name and requires it',
      (WidgetTester tester) async {
    await tall(tester);
    final _RecordingController controller = _RecordingController();
    final _FakeNameStore names = _FakeNameStore(null);
    await tester.pumpWidget(host(controller: controller, nameStore: names));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(FeedbackSheet.nameFieldKey), findsOneWidget);

    await tester.enterText(
        find.byKey(FeedbackSheet.messageFieldKey), 'Found a typo');
    await tester.pump();
    // No name yet → Send is disabled.
    FilledButton send = tester.widget<FilledButton>(
        find.byKey(FeedbackSheet.sendButtonKey));
    expect(send.onPressed, isNull);

    await tester.enterText(find.byKey(FeedbackSheet.nameFieldKey), 'Sam');
    await tester.pump();
    send = tester.widget<FilledButton>(find.byKey(FeedbackSheet.sendButtonKey));
    expect(send.onPressed, isNotNull);

    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.submitted!.testerName, 'Sam');
    expect(names.name, 'Sam'); // persisted for next time
  });

  testWidgets(
      'signed-in tester: name comes from the Google account, no prompt, Send enabled',
      (WidgetTester tester) async {
    await tall(tester);
    // A fresh install has no stored feedback name, but the tester IS
    // signed in with Google — so we use that name instead of blocking
    // Send behind the "what should I call you?" prompt.
    final _RecordingController controller = _RecordingController();
    final _FakeNameStore names = _FakeNameStore(null);
    await tester.pumpWidget(host(
      controller: controller,
      nameStore: names,
      authState: const AuthState.signedIn(
        user: User(id: 'g-1', email: 'jo@x.com', name: 'Jo Carer'),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // No name prompt — we already know who they are.
    expect(find.byKey(FeedbackSheet.nameFieldKey), findsNothing);

    // A message alone is enough to send.
    await tester.enterText(
        find.byKey(FeedbackSheet.messageFieldKey), 'Word wrap looks off');
    await tester.pump();
    final FilledButton send = tester.widget<FilledButton>(
        find.byKey(FeedbackSheet.sendButtonKey));
    expect(send.onPressed, isNotNull);

    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.submitted!.testerName, 'Jo Carer'); // from the account
    expect(names.name, 'Jo Carer'); // remembered for next time
  });

  testWidgets(
      'the screenshot toggle defaults OFF — no image rides along unless '
      'the tester opts in (PHI consent)', (WidgetTester tester) async {
    await tall(tester);
    final _RecordingController controller = _RecordingController();
    await tester.pumpWidget(host(
      controller: controller,
      nameStore: _FakeNameStore('Sam'),
      screenshot: _onePxPng,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The toggle is present but starts OFF.
    final HoldcloseSwitch toggle = tester.widget<HoldcloseSwitch>(
        find.byKey(FeedbackSheet.screenshotToggleKey));
    expect(toggle.value, isFalse);

    await tester.enterText(
        find.byKey(FeedbackSheet.messageFieldKey), 'looks off');
    await tester.pump();
    // Send WITHOUT flipping it — the screenshot must NOT be attached.
    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.submitted!.hasScreenshot, isFalse);
    expect(controller.lastScreenshot, isNull);
  });

  testWidgets('opting the screenshot toggle ON attaches the image',
      (WidgetTester tester) async {
    await tall(tester);
    final _RecordingController controller = _RecordingController();
    await tester.pumpWidget(host(
      controller: controller,
      nameStore: _FakeNameStore('Sam'),
      screenshot: _onePxPng,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(FeedbackSheet.messageFieldKey), 'looks off');
    await tester.pump();
    // Deliberately turn the screenshot ON.
    await tester.tap(find.byKey(FeedbackSheet.screenshotToggleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.submitted!.hasScreenshot, isTrue);
    expect(controller.lastScreenshot, isNotNull);
  });

  testWidgets('the log-snapshot consent toggle is visible and ON by default',
      (WidgetTester tester) async {
    await tall(tester);
    final _RecordingController controller = _RecordingController();
    LogBuffer.instance.add('a line the default consent includes');
    await tester.pumpWidget(host(
      controller: controller,
      nameStore: _FakeNameStore('Sam'),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(FeedbackSheet.logsToggleKey), findsOneWidget);
    await tester.enterText(
        find.byKey(FeedbackSheet.messageFieldKey), 'context attached');
    await tester.pump();
    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.submitted!.logs, isNotEmpty);
  });

  testWidgets('logs toggle off drops the log snapshot from the submission '
      '(2026-06-11 consent)', (WidgetTester tester) async {
    await tall(tester);
    final _RecordingController controller = _RecordingController();
    // Make sure there IS something in the buffer to decline.
    LogBuffer.instance.add('a line that must NOT ride along when declined');
    await tester.pumpWidget(host(
      controller: controller,
      nameStore: _FakeNameStore('Sam'),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(FeedbackSheet.messageFieldKey), 'no logs please');
    await tester.pump();
    await tester.tap(find.byKey(FeedbackSheet.logsToggleKey));
    await tester.pump();
    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.submitted!.logs, isEmpty);
  });

  testWidgets(
      'a prior crash is offered as attachable context and rides along when '
      'sent (on-device, user-initiated)', (WidgetTester tester) async {
    await tall(tester);
    // A canned prior-crash trace via the sheet's crash-log seam (no dart:io).
    FeedbackSheet.crashLogReader = () async => 'Uncaught: kaboom\n#0 boom';
    bool wasCleared = false;
    FeedbackSheet.crashLogClearer = () async => wasCleared = true;

    final _RecordingController controller = _RecordingController();
    await tester.pumpWidget(host(
      controller: controller,
      nameStore: _FakeNameStore('Sam'),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The crash-consent toggle appears because a trace exists on device.
    expect(find.byKey(FeedbackSheet.crashLogToggleKey), findsOneWidget);

    await tester.enterText(
        find.byKey(FeedbackSheet.messageFieldKey), 'it crashed on launch');
    await tester.pump();
    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    // The crash trace was folded into the report's logs, and the on-device
    // copy was cleared so it isn't re-offered next time.
    expect(controller.submitted!.logs, contains('Uncaught: kaboom'));
    expect(wasCleared, isTrue);
  });

  testWidgets('no crash toggle shows when there is no prior crash',
      (WidgetTester tester) async {
    await tall(tester);
    // Default seam (setUp) returns '' — no prior crash.
    await tester.pumpWidget(host(
      controller: _RecordingController(),
      nameStore: _FakeNameStore('Sam'),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(FeedbackSheet.crashLogToggleKey), findsNothing);
  });

  testWidgets('mic dictates the report into the message field '
      '(fb_1781129218678980)', (WidgetTester tester) async {
    await tall(tester);
    await tester.pumpWidget(host(
      controller: _RecordingController(),
      nameStore: _FakeNameStore('Sam'),
      voiceCapture: const _FakeVoiceCapture('The schedule indentation is off'),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(FeedbackSheet.micKey));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextField, 'The schedule indentation is off'),
      findsOneWidget,
    );
  });
}

/// Returns a canned transcript — no real mic/STT in tests.
class _FakeVoiceCapture implements VoiceCapture {
  const _FakeVoiceCapture(this.transcript);
  final String? transcript;
  @override
  Future<String?> capture({void Function(String partial)? onPartial}) async =>
      transcript;
}

/// Records what the sheet submits without touching disk or the network.
class _RecordingController extends FeedbackController {
  _RecordingController()
      : super(
          outbox: FeedbackOutbox(
              overrideRoot: Directory.systemTemp.createTempSync('fb_w')),
          sender: FeedbackSender(),
        );

  FeedbackReport? submitted;
  Uint8List? lastScreenshot;

  @override
  Future<bool> submit(FeedbackReport report, Uint8List? screenshot) async {
    submitted = report;
    lastScreenshot = screenshot;
    return true;
  }

  @override
  Future<int> flush() async => 0;
}

class _FakeNameStore extends TesterNameStore {
  _FakeNameStore(this.name);

  String? name;

  @override
  Future<String?> get() async => name;

  @override
  Future<void> set(String value) async {
    name = value.trim();
  }
}

/// Minimal [AuthProvider] that just replays a fixed [AuthState] — enough
/// for the feedback sheet to read the signed-in user's name (or not).
class _StubAuth implements AuthProvider {
  _StubAuth(this._state);

  final AuthState _state;

  @override
  Stream<AuthState> watchAuthState() => Stream<AuthState>.value(_state);

  @override
  Future<void> signInWithApple() async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}
}
