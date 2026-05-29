import 'package:careblazers/providers/onboarding_provider.dart';
import 'package:careblazers/screens/onboarding/welcome_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../_semantics_matchers.dart';

/// Pump the welcome carousel inside a minimal router that exposes a
/// `/sign-in` stub. Tests assert routing by inspecting
/// `router.routerDelegate.currentConfiguration.uri.path` and the
/// presence of the stub's marker text — same shape as the picker and
/// triage screen tests.
Future<({ProviderContainer container, GoRouter router})> _pumpCarousel(
  WidgetTester tester,
) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/onboarding',
    routes: <RouteBase>[
      GoRoute(
        path: '/onboarding',
        builder: (BuildContext context, GoRouterState state) =>
            const WelcomeCarousel(),
      ),
      GoRoute(
        path: '/sign-in',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('test-sign-in'))),
      ),
    ],
  );

  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, router: router);
}

/// Tap the bottom CTA and let the page-turn animation / route push
/// settle.
Future<void> _tapCta(WidgetTester tester) async {
  await tester.tap(find.byKey(WelcomeCarousel.primaryCtaKey));
  await tester.pumpAndSettle();
}

void main() {
  group('WelcomeCarousel — BUILD_SPEC.md §5.11 (locked copy)', () {
    testWidgets('page 1 renders the brand + tagline pair',
        (WidgetTester tester) async {
      await _pumpCarousel(tester);

      final WelcomeCarouselPage page1 = WelcomeCarousel.pages[0];
      expect(page1.title, 'Careblazers');
      expect(page1.body,
          'We make caregiving for someone with dementia easier.');
      expect(find.text(page1.title), findsOneWidget);
      expect(find.text(page1.body), findsOneWidget);
    });

    testWidgets('page 2 renders the pocket-coach copy after a swipe-next',
        (WidgetTester tester) async {
      await _pumpCarousel(tester);

      await _tapCta(tester);

      final WelcomeCarouselPage page2 = WelcomeCarousel.pages[1];
      expect(page2.title, 'Your pocket coach for the hard moments.');
      expect(page2.body,
          startsWith('When sundowning hits, when she accuses you of something'));
      expect(find.text(page2.title), findsOneWidget);
      expect(find.text(page2.body), findsOneWidget);
    });

    testWidgets('page 3 renders the journal-fills-itself copy',
        (WidgetTester tester) async {
      await _pumpCarousel(tester);

      await _tapCta(tester); // → page 2
      await _tapCta(tester); // → page 3

      final WelcomeCarouselPage page3 = WelcomeCarousel.pages[2];
      expect(page3.title, 'Your journal fills itself.');
      expect(page3.body, startsWith('Every coaching moment auto-logs.'));
      expect(find.text(page3.title), findsOneWidget);
      expect(find.text(page3.body), findsOneWidget);
    });

    testWidgets(
        'CTA reads "Next →" on pages 1-2 and "Get started" on page 3',
        (WidgetTester tester) async {
      await _pumpCarousel(tester);

      expect(find.text('Next →'), findsOneWidget);
      expect(find.text('Get started'), findsNothing);

      await _tapCta(tester);
      expect(find.text('Next →'), findsOneWidget);
      expect(find.text('Get started'), findsNothing);

      await _tapCta(tester);
      expect(find.text('Next →'), findsNothing);
      expect(find.text('Get started'), findsOneWidget);
    });

    testWidgets('dot indicator renders one dot per page',
        (WidgetTester tester) async {
      await _pumpCarousel(tester);

      // The dot indicator hosts one AnimatedContainer per page —
      // selecting through its key keeps the count assertion stable
      // even if a future polish pass changes the shape primitive.
      final Finder dots = find.descendant(
        of: find.byKey(WelcomeCarousel.dotIndicatorKey),
        matching: find.byType(AnimatedContainer),
      );
      expect(dots, findsNWidgets(WelcomeCarousel.pages.length));
    });
  });

  group('WelcomeCarousel — navigation', () {
    testWidgets('Skip routes to /sign-in', (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) pumped =
          await _pumpCarousel(tester);

      expect(find.text('test-sign-in'), findsNothing);

      await tester.tap(find.byKey(WelcomeCarousel.skipButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('test-sign-in'), findsOneWidget);
      expect(
        pumped.router.routerDelegate.currentConfiguration.uri.path,
        '/sign-in',
      );
    });

    testWidgets(
        'Get started flips onboardingCompletedProvider AND routes to /sign-in',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) pumped =
          await _pumpCarousel(tester);

      expect(pumped.container.read(onboardingCompletedProvider), isFalse,
          reason: 'sanity: provider starts false');

      // Advance to page 3 first — the page 1-2 CTA is "Next →" and
      // must NOT flip the provider.
      await _tapCta(tester);
      expect(pumped.container.read(onboardingCompletedProvider), isFalse,
          reason: 'Next on page 1 must not flip the onboarding flag');

      await _tapCta(tester);
      expect(pumped.container.read(onboardingCompletedProvider), isFalse,
          reason: 'Next on page 2 must not flip the onboarding flag');

      // Now on page 3 — CTA is "Get started".
      await _tapCta(tester);

      expect(pumped.container.read(onboardingCompletedProvider), isTrue);
      expect(find.text('test-sign-in'), findsOneWidget);
      expect(
        pumped.router.routerDelegate.currentConfiguration.uri.path,
        '/sign-in',
      );
    });

    testWidgets('Skip does NOT flip onboardingCompletedProvider',
        (WidgetTester tester) async {
      final ({ProviderContainer container, GoRouter router}) pumped =
          await _pumpCarousel(tester);

      await tester.tap(find.byKey(WelcomeCarousel.skipButtonKey));
      await tester.pumpAndSettle();

      // Skipping is "I'll come back to this" — only "Get started"
      // signals an intentional completion, so the provider stays false.
      expect(pumped.container.read(onboardingCompletedProvider), isFalse);
    });
  });

  group('WelcomeCarousel — VoiceOver labels (BUILD_SPEC.md §11.5)', () {
    testWidgets('Skip button has an explicit Semantics label',
        (WidgetTester tester) async {
      await _pumpCarousel(tester);

      expect(
        hasSemanticsLabel(tester, RegExp('Skip onboarding')),
        isTrue,
        reason: 'Skip must announce its purpose to assistive tech',
      );
    });
  });

  group('OnboardingCompleted notifier', () {
    test('starts false and flips to true on complete()', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(onboardingCompletedProvider), isFalse);

      container.read(onboardingCompletedProvider.notifier).complete();

      expect(container.read(onboardingCompletedProvider), isTrue);
    });

    test('complete() is idempotent', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final OnboardingCompleted notifier =
          container.read(onboardingCompletedProvider.notifier);

      notifier.complete();
      notifier.complete();

      expect(container.read(onboardingCompletedProvider), isTrue);
    });
  });
}
