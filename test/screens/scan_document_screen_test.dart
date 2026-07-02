import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/screens/scan_document_screen.dart';

/// The unified "scan a document" chooser — offers the three extractors.
Future<void> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/scan',
    routes: <RouteBase>[
      GoRoute(
        path: '/scan',
        builder: (BuildContext context, GoRouterState state) =>
            const ScanDocumentScreen(),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp.router(routerConfig: router)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the three scan options', (WidgetTester tester) async {
    await _pump(tester);

    expect(find.byKey(ScanDocumentScreen.optionKey('prescription')),
        findsOneWidget);
    expect(find.byKey(ScanDocumentScreen.optionKey('appointment')),
        findsOneWidget);
    expect(find.byKey(ScanDocumentScreen.optionKey('insurance')),
        findsOneWidget);
    expect(find.text('Prescription label'), findsOneWidget);
    expect(find.text('Insurance card'), findsOneWidget);
  });
}
