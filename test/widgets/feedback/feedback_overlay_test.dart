import 'dart:io';
import 'dart:typed_data';

import 'package:careblazers/services/feedback_service.dart';
import 'package:careblazers/widgets/feedback/feedback_overlay.dart';
import 'package:careblazers/widgets/feedback/feedback_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

void main() {
  testWidgets('disabled overlay renders the child verbatim (goldens safe)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: FeedbackOverlay(
            enabled: false,
            currentRoute: () => '/home',
            child: const Scaffold(
              body: Text('CONTENT', key: Key('content')),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('content')), findsOneWidget);
    expect(find.byKey(FeedbackOverlay.reportButtonKey), findsNothing);
  });

  testWidgets('enabled overlay shows Report and opens the sheet on tap',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          feedbackControllerProvider.overrideWithValue(_NoopController()),
          testerNameStoreProvider.overrideWithValue(_FixedNameStore('Sam')),
          feedbackButtonStoreProvider.overrideWithValue(_FakeButtonStore()),
        ],
        child: MaterialApp(
          home: FeedbackOverlay(
            enabled: true,
            currentRoute: () => '/home',
            captureOverride: () async => null,
            child: const Scaffold(body: Text('CONTENT')),
          ),
        ),
      ),
    );
    await tester.pump(); // let the post-frame flush() run

    expect(find.byKey(FeedbackOverlay.reportButtonKey), findsOneWidget);

    await tester.tap(find.byKey(FeedbackOverlay.reportButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(FeedbackSheet.sheetKey), findsOneWidget);
  });

  testWidgets('button drags to the other side, persists, and still taps',
      (WidgetTester tester) async {
    final _FakeButtonStore buttonStore = _FakeButtonStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          feedbackControllerProvider.overrideWithValue(_NoopController()),
          testerNameStoreProvider.overrideWithValue(_FixedNameStore('Sam')),
          feedbackButtonStoreProvider.overrideWithValue(buttonStore),
        ],
        child: MaterialApp(
          home: FeedbackOverlay(
            enabled: true,
            currentRoute: () => '/home',
            captureOverride: () async => null,
            child: const Scaffold(body: Text('CONTENT')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder button = find.byKey(FeedbackOverlay.reportButtonKey);
    final Offset before = tester.getTopLeft(button);

    // Drag well past center toward the upper-left.
    await tester.drag(button, const Offset(-500, -150));
    await tester.pumpAndSettle();

    final Offset after = tester.getTopLeft(button);
    expect(after.dx, lessThan(before.dx)); // snapped to the left edge
    expect(after.dy, lessThan(before.dy)); // moved up
    expect(buttonStore.lastRightEdge, isFalse); // persisted the new side

    // A tap still opens the sheet — drag didn't swallow the tap.
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(FeedbackSheet.sheetKey), findsOneWidget);
  });

  testWidgets('opens the sheet via the router navigator (real app wiring)',
      (WidgetTester tester) async {
    // Reproduces the production wiring: the overlay lives in
    // MaterialApp.router's builder, ABOVE GoRouter's Navigator, so the
    // sheet must be hosted on the router's root navigator (not the
    // overlay's own context). A plain MaterialApp(home:) test would mask
    // this — that's how the bug shipped.
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (BuildContext c, GoRouterState s) =>
              const Scaffold(body: Text('HOME')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          feedbackControllerProvider.overrideWithValue(_NoopController()),
          testerNameStoreProvider.overrideWithValue(_FixedNameStore('Sam')),
          feedbackButtonStoreProvider.overrideWithValue(_FakeButtonStore()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (BuildContext context, Widget? child) => FeedbackOverlay(
            enabled: true,
            currentRoute: () => '/',
            navigatorContext: () =>
                router.routerDelegate.navigatorKey.currentContext,
            captureOverride: () async => null,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(FeedbackOverlay.reportButtonKey), findsOneWidget);
    await tester.tap(find.byKey(FeedbackOverlay.reportButtonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(FeedbackSheet.sheetKey), findsOneWidget);
  });

  testWidgets('a repeat tap toggles the sheet closed instead of stacking',
      (WidgetTester tester) async {
    // Router wiring so the button floats above the sheet's modal barrier,
    // exactly like production — that's why a repeat tap could reach it and
    // stack a second/third sheet.
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (BuildContext c, GoRouterState s) =>
              const Scaffold(body: Text('HOME')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          feedbackControllerProvider.overrideWithValue(_NoopController()),
          testerNameStoreProvider.overrideWithValue(_FixedNameStore('Sam')),
          feedbackButtonStoreProvider.overrideWithValue(_FakeButtonStore()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (BuildContext context, Widget? child) => FeedbackOverlay(
            enabled: true,
            currentRoute: () => '/',
            navigatorContext: () =>
                router.routerDelegate.navigatorKey.currentContext,
            captureOverride: () async => null,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder button = find.byKey(FeedbackOverlay.reportButtonKey);

    // 1st tap → opens.
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(FeedbackSheet.sheetKey), findsOneWidget);

    // 2nd tap → toggles closed (not a second sheet stacked on top).
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(FeedbackSheet.sheetKey), findsNothing);

    // 3rd tap → re-opens, and there is exactly one.
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(FeedbackSheet.sheetKey), findsOneWidget);
  });
}

class _FakeButtonStore extends FeedbackButtonStore {
  _FakeButtonStore();

  bool? lastRightEdge;
  double? lastVFrac;

  @override
  Future<({bool rightEdge, double vFrac})?> get() async => null;

  @override
  Future<void> set({required bool rightEdge, required double vFrac}) async {
    lastRightEdge = rightEdge;
    lastVFrac = vFrac;
  }
}

class _NoopController extends FeedbackController {
  _NoopController()
      : super(
          outbox: FeedbackOutbox(
              overrideRoot: Directory.systemTemp.createTempSync('fb_ov')),
          sender: FeedbackSender(),
        );

  @override
  Future<bool> submit(FeedbackReport report, Uint8List? screenshot) async =>
      true;

  @override
  Future<int> flush() async => 0;
}

class _FixedNameStore extends TesterNameStore {
  _FixedNameStore(this._name);
  final String? _name;

  @override
  Future<String?> get() async => _name;

  @override
  Future<void> set(String value) async {}
}
