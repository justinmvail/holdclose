import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/providers/visit_prep_provider.dart'
    show careContextTextProvider;
import 'package:holdclose/screens/medical/insurance_appeal_screen.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The AI insurance-appeal helper: enter what/why, draft, edit, copy. Uses
/// the fake service (default under `flutter test`) and a stubbed care
/// context so it never touches the real snapshot or a model.
Future<void> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/insurance-appeal',
    routes: <RouteBase>[
      GoRoute(
        path: '/insurance-appeal',
        builder: (BuildContext context, GoRouterState state) =>
            const InsuranceAppealScreen(carrier: 'BlueCross'),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        careContextTextProvider.overrideWith((Ref ref) async => 'ctx'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('drafts a letter and shows it editable + copyable',
      (WidgetTester tester) async {
    await _pump(tester);

    await tester.enterText(
        find.byKey(InsuranceAppealScreen.claimFieldKey), 'physical therapy');
    await tester.enterText(find.byKey(InsuranceAppealScreen.denialFieldKey),
        'not medically necessary');
    await tester.tap(find.byKey(InsuranceAppealScreen.draftButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(InsuranceAppealScreen.letterFieldKey), findsOneWidget);
    expect(find.byKey(InsuranceAppealScreen.copyButtonKey), findsOneWidget);
    final TextField letter =
        tester.widget<TextField>(find.byKey(InsuranceAppealScreen.letterFieldKey));
    expect(letter.controller!.text, contains('physical therapy'));
    expect(letter.controller!.text, contains('BlueCross'));
  });

  testWidgets('requires both inputs before drafting',
      (WidgetTester tester) async {
    await _pump(tester);

    await tester.tap(find.byKey(InsuranceAppealScreen.draftButtonKey));
    await tester.pumpAndSettle();

    expect(find.byKey(InsuranceAppealScreen.letterFieldKey), findsNothing);
    expect(find.textContaining('what was denied'), findsOneWidget);
  });
}
