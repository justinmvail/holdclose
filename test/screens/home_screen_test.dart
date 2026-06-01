import 'dart:async';

import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/providers/home_clock_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:careblazers/screens/settings/settings_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pumps Home inside the real router so the AppBar-less dashboard renders
/// in the tab shell it ships in, with the clock pinned to [now] and a
/// signed-in fake caregiver (Sarah Henderson) driving the greeting name.
Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  required DateTime now,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  // FakeAuthProvider starts signedOut; sign in so the greeting renders
  // the caregiver's first name. `_signIn` flips state synchronously, so
  // the StreamBuilder replays signedIn on subscribe.
  final FakeAuthProvider auth = FakeAuthProvider();
  unawaited(auth.signInWithGoogle());
  addTearDown(auth.dispose);

  final GoRouter router = buildRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
        authProvider.overrideWithValue(auth),
        homeClockProvider.overrideWithValue(() => now),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: careblazersLightTheme,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('greetingForHour — pure boundaries (BUILD_SPEC.md Phase 14.7)', () {
    test('morning before noon', () {
      expect(greetingForHour(0), 'Good morning');
      expect(greetingForHour(11), 'Good morning');
    });

    test('afternoon from noon through 4:59pm', () {
      expect(greetingForHour(12), 'Good afternoon');
      expect(greetingForHour(16), 'Good afternoon');
    });

    test('evening from 5pm on', () {
      expect(greetingForHour(17), 'Good evening');
      expect(greetingForHour(23), 'Good evening');
    });
  });

  group('firstNameOf', () {
    test('takes the first whitespace-delimited token', () {
      expect(firstNameOf('Sarah Henderson'), 'Sarah');
      expect(firstNameOf('  Sarah   Henderson '), 'Sarah');
      expect(firstNameOf('Sarah'), 'Sarah');
    });

    test('empty for a blank name', () {
      expect(firstNameOf(''), '');
      expect(firstNameOf('   '), '');
    });
  });

  group('HomeScreen — dashboard scaffold (Phase 14.7)', () {
    testWidgets('AppBar-less scroll view with greeting + profile',
        (WidgetTester tester) async {
      await _pumpHome(tester, now: DateTime(2026, 6, 1, 9));

      expect(find.byType(HomeScreen), findsOneWidget);
      // The dashboard is AppBar-less — no AppBar anywhere in the shell.
      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(HomeScreen.dashboardListKey), findsOneWidget);
      expect(find.byKey(HomeScreen.greetingKey), findsOneWidget);
      expect(find.byKey(HomeScreen.profileButtonKey), findsOneWidget);
    });

    testWidgets('greeting says "Good morning" before noon',
        (WidgetTester tester) async {
      await _pumpHome(tester, now: DateTime(2026, 6, 1, 9));
      expect(find.text('Good morning, Sarah'), findsOneWidget);
    });

    testWidgets('greeting says "Good afternoon" mid-day',
        (WidgetTester tester) async {
      await _pumpHome(tester, now: DateTime(2026, 6, 1, 14));
      expect(find.text('Good afternoon, Sarah'), findsOneWidget);
    });

    testWidgets('greeting says "Good evening" at night',
        (WidgetTester tester) async {
      await _pumpHome(tester, now: DateTime(2026, 6, 1, 20));
      expect(find.text('Good evening, Sarah'), findsOneWidget);
    });

    testWidgets('profile icon is account_circle_outlined at 32px',
        (WidgetTester tester) async {
      await _pumpHome(tester, now: DateTime(2026, 6, 1, 9));
      final IconButton button = tester
          .widget<IconButton>(find.byKey(HomeScreen.profileButtonKey));
      expect((button.icon as Icon).icon, Icons.account_circle_outlined);
      expect(button.iconSize, 32);
    });

    testWidgets('tapping the profile icon pushes Settings',
        (WidgetTester tester) async {
      await _pumpHome(tester, now: DateTime(2026, 6, 1, 9));

      expect(find.byType(SettingsScreen), findsNothing);
      await tester.tap(find.byKey(HomeScreen.profileButtonKey));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });
}
