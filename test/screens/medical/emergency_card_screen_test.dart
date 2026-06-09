import 'package:careblazers/models/medication.dart';
import 'package:careblazers/screens/medical/emergency_card_screen.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The read-only Emergency Card screen. Its only back affordance is the
/// PathHeader breadcrumb (no AppBar), so the breadcrumb must be present on
/// EVERY branch — including the loading and error states — or the screen is
/// swipe-only (alpha bug fb_1780932762335231).
EmergencyCardView _view() => EmergencyCardView(
      patient: maryHenderson(),
      card: null,
      medications: const <Medication>[],
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/medical/cards/emergency',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/cards/emergency',
        builder: (BuildContext context, GoRouterState state) =>
            const EmergencyCardScreen(),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EmergencyCardScreen — PathHeader back affordance', () {
    testWidgets('renders the PathHeader breadcrumb on the data branch',
        (WidgetTester tester) async {
      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith((Ref ref) async => _view()),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
      expect(find.text('Emergency Card'), findsWidgets);
      // The Edit affordance lives in the header's trailing slot.
      expect(find.byKey(EmergencyCardScreen.editActionKey), findsOneWidget);
    });

    testWidgets('keeps the PathHeader breadcrumb on the error branch',
        (WidgetTester tester) async {
      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith(
            (Ref ref) async => throw Exception('boom'),
          ),
        ],
      );
      await tester.pumpAndSettle();

      // Even when the card fails to load, the breadcrumb back affordance
      // is on screen — the screen is never a swipe-only dead-end.
      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
    });
  });
}
