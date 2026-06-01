import 'package:careblazers/routing/router.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/emergency_card_pin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A two-route harness: the card sits at `/`, and the Emergency Card
/// destination is registered under its real name
/// ([CareblazersRoutes.medicalCardsEmergency], path
/// `/medical/cards/emergency`) so a `pushNamed` resolves end to end —
/// mirroring the route the app registers in Phase 14.5.
GoRouter _harnessRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: EmergencyCardPin()),
      ),
      GoRoute(
        path: '/medical/cards/emergency',
        name: CareblazersRoutes.medicalCardsEmergency,
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Text('EMERGENCY DEST')),
      ),
    ],
  );
}

Future<GoRouter> _pumpCard(WidgetTester tester) async {
  final GoRouter router = _harnessRouter();
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      theme: careblazersLightTheme,
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('EmergencyCardPin — rendering', () {
    testWidgets('shows the shield, label and sub-label',
        (WidgetTester tester) async {
      await _pumpCard(tester);

      expect(find.byType(EmergencyCardPin), findsOneWidget);
      expect(find.text('Emergency Card'), findsOneWidget);
      expect(
        find.text('One tap — info for first responders'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    });

    testWidgets('paints the orange→deeper-orange brand gradient',
        (WidgetTester tester) async {
      await _pumpCard(tester);

      // The gradient is painted by the card's [Ink] (the InkWell's
      // material), not a Container.
      final Ink ink = tester.widgetList<Ink>(find.byType(Ink)).firstWhere(
            (Ink i) =>
                i.decoration is BoxDecoration &&
                (i.decoration! as BoxDecoration).gradient is LinearGradient,
          );
      final LinearGradient gradient =
          (ink.decoration! as BoxDecoration).gradient! as LinearGradient;

      expect(gradient.colors.first, careblazersColors.cta);
      expect(gradient.colors.last, careblazersColors.accentDeep);
    });

    testWidgets('label is bold warm-white', (WidgetTester tester) async {
      await _pumpCard(tester);

      final Text label = tester.widget<Text>(find.text('Emergency Card'));
      expect(label.style?.fontWeight, FontWeight.w700);
      expect(label.style?.color, careblazersColors.background);
    });
  });

  group('EmergencyCardPin — navigation', () {
    testWidgets('a tap pushes the Emergency Card route onto the stack',
        (WidgetTester tester) async {
      await _pumpCard(tester);

      expect(find.text('EMERGENCY DEST'), findsNothing);

      await tester.tap(find.byType(EmergencyCardPin));
      await tester.pumpAndSettle();

      // The destination registered under
      // [CareblazersRoutes.medicalCardsEmergency] (path
      // `/medical/cards/emergency`) is now on screen — proof the named
      // push resolved to the right route. It's a push, so the root page
      // stays in the stack beneath it.
      expect(find.text('EMERGENCY DEST'), findsOneWidget);
    });
  });

  group('EmergencyCardPin — accessibility', () {
    testWidgets('exposes a single button node reading the first-responder '
        'label', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpCard(tester);

      expect(
        tester.getSemantics(find.byKey(EmergencyCardPin.cardKey)),
        matchesSemantics(
          label: 'Emergency Card. Show to first responders.',
          isButton: true,
          hasTapAction: true,
        ),
      );
      // The decorative copy is hidden so the reader hears the curated
      // label, not the duplicated visual text.
      expect(find.bySemanticsLabel('One tap — info for first responders'),
          findsNothing);

      handle.dispose();
    });
  });
}
