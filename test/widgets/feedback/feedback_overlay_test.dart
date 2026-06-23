import 'dart:io';
import 'dart:typed_data';

import 'package:holdclose/services/feedback_service.dart';
import 'package:holdclose/widgets/feedback/feedback_overlay.dart';
import 'package:holdclose/widgets/feedback/feedback_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The report button now lives in the screen header and fires a provider
/// the overlay listens for — so tests simulate the press by firing that
/// trigger directly (the header button itself is alpha-gated off in tests).
void _fireReport(WidgetTester tester) {
  ProviderScope.containerOf(
    tester.element(find.byType(FeedbackOverlay)),
    listen: false,
  ).read(feedbackTriggerProvider.notifier).fire();
}

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

    // Disabled → the child renders verbatim and nothing feedback-related
    // is mounted (no sheet possible).
    expect(find.byKey(const Key('content')), findsOneWidget);
    expect(find.byKey(FeedbackSheet.sheetKey), findsNothing);
  });

  testWidgets('firing the report trigger captures + opens the sheet',
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

    expect(find.byKey(FeedbackSheet.sheetKey), findsNothing);
    _fireReport(tester); // the header button would fire this
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

    _fireReport(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(FeedbackSheet.sheetKey), findsOneWidget);
  });

  testWidgets('a repeat trigger toggles the sheet closed instead of stacking',
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

    // 1st fire → opens.
    _fireReport(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(FeedbackSheet.sheetKey), findsOneWidget);

    // 2nd fire → toggles closed (not a second sheet stacked on top).
    _fireReport(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(FeedbackSheet.sheetKey), findsNothing);

    // 3rd fire → re-opens, and there is exactly one.
    _fireReport(tester);
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
