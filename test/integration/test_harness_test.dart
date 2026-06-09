import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/onboarding/sign_in_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

void main() {
  group('pumpCareblazersApp (TASKS.md Phase 15.1)', () {
    testWidgets('pumping yields a renderable app landing on Home at /',
        (WidgetTester tester) async {
      await pumpCareblazersApp(tester);

      // The app renders without throwing and the shell boots straight to
      // the Home dashboard root.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(homeGreeting, findsOneWidget);
    });

    testWidgets('FakeAuthProvider lands the shell directly on Home, not sign-in',
        (WidgetTester tester) async {
      await pumpCareblazersApp(tester);

      // demoMode=true signs Sarah in, so the §5.12 auth gate admits the
      // shell rather than redirecting to the sign-in screen.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      // The greeting is driven by the signed-in caregiver's first name.
      expect(find.textContaining('Sarah'), findsOneWidget);
    });

    testWidgets('the default clock override holds (morning greeting)',
        (WidgetTester tester) async {
      await pumpCareblazersApp(tester);
      expect(find.text('Good morning, Sarah'), findsOneWidget);
    });

    testWidgets('a custom clock override holds (evening greeting)',
        (WidgetTester tester) async {
      await pumpCareblazersApp(tester, clock: DateTime(2026, 6, 1, 20, 0));
      expect(find.text('Good evening, Sarah'), findsOneWidget);
    });

    testWidgets('findHubTile resolves both Care and Care Circle tiles',
        (WidgetTester tester) async {
      await pumpCareblazersApp(tester);

      // Care hub (renamed from Medical in the 2026-06-06 IA refactor).
      await tester.tap(tabFor('Care'));
      await tester.pumpAndSettle();
      expect(findHubTile('Medications'), findsOneWidget);

      // Care Circle hub — now reached via the Care hub's gated Care Circle
      // tile rather than a top-level Team tab.
      await openCareCircle(tester);
      expect(findHubTile('People'), findsOneWidget);
    });

    testWidgets('returns a usable container the test can read providers from',
        (WidgetTester tester) async {
      final ProviderContainer container = await pumpCareblazersApp(tester);

      // The harness seeders write through this container's overrides; a
      // round-trip proves the in-memory drift is wired and shared.
      await seedMaryHenderson(container);
      final Patient? patient =
          await container.read(storageProvider).getPatient();
      expect(patient?.name, 'Mary Henderson');
    });
  });
}
