import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/services/feedback_service.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/feedback/feedback_sheet.dart';
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
  Widget host({
    required FeedbackController controller,
    required TesterNameStore nameStore,
    Uint8List? screenshot,
    String route = '/medical/medications',
    AuthState authState = const AuthState.signedOut(),
  }) {
    return ProviderScope(
      overrides: <Override>[
        feedbackControllerProvider.overrideWithValue(controller),
        testerNameStoreProvider.overrideWithValue(nameStore),
        authBackendProvider.overrideWithValue(_StubAuth(authState)),
      ],
      child: MaterialApp(
        theme: careblazersLightTheme,
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

  testWidgets('screenshot toggle off drops the image from the submission',
      (WidgetTester tester) async {
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
    // Toggle the screenshot off.
    await tester.tap(find.byKey(FeedbackSheet.screenshotToggleKey));
    await tester.pump();
    await tester.tap(find.byKey(FeedbackSheet.sendButtonKey));
    await tester.pumpAndSettle();

    expect(controller.submitted!.hasScreenshot, isFalse);
    expect(controller.lastScreenshot, isNull);
  });
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
