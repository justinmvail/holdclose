import 'package:alchemist/alchemist.dart';
import 'package:careblazers/screens/community/support_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(double height) {
  return ProviderScope(
    child: SizedBox(
      width: 460,
      height: height,
      child: MaterialApp(
        home: const Scaffold(body: SafeArea(child: SupportScreen())),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

/// Expand the given cards (by header key) before the golden is captured.
PumpAction _expand(List<String> ids) {
  return (WidgetTester tester) async {
    await tester.pumpAndSettle();
    for (final String id in ids) {
      await tester.tap(find.byKey(SupportScreen.cardHeaderKey(id)));
      await tester.pumpAndSettle();
    }
  };
}

void main() {
  group('SupportScreen golden', () {
    goldenTest(
      'all three cards collapsed',
      fileName: 'support_screen_collapsed',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'collapsed (Phase 14.38)',
            child: _host(420),
          ),
        ],
      ),
    );

    goldenTest(
      'burnout self-check expanded',
      fileName: 'support_screen_self_check',
      pumpBeforeTest: _expand(<String>[SupportScreen.selfCheckId]),
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'self-check form (Phase 14.38)',
            child: _host(1700),
          ),
        ],
      ),
    );

    goldenTest(
      'respite resources expanded',
      fileName: 'support_screen_respite',
      pumpBeforeTest: _expand(<String>[SupportScreen.respiteId]),
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'respite (Phase 14.38)',
            child: _host(1100),
          ),
        ],
      ),
    );

    goldenTest(
      'expert Q&A expanded',
      fileName: 'support_screen_qanda',
      pumpBeforeTest: _expand(<String>[SupportScreen.qandaId]),
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'Q&A (Phase 14.38)',
            child: _host(1100),
          ),
        ],
      ),
    );
  });
}
