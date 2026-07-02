import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/screens/medical/care_summary_screen.dart';

/// The care-summary screen renders its explanation + Share action. (The
/// build+share path hits the platform share sheet, so it's not tapped here.)
void main() {
  testWidgets('renders the share action', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final GoRouter router = GoRouter(
      initialLocation: '/care-summary',
      routes: <RouteBase>[
        GoRoute(
          path: '/care-summary',
          builder: (BuildContext context, GoRouterState state) =>
              const CareSummaryScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(CareSummaryScreen.shareButtonKey), findsOneWidget);
    expect(find.text('Share care summary'), findsOneWidget);
    expect(find.textContaining('same picture for every clinician'),
        findsOneWidget);
  });
}
