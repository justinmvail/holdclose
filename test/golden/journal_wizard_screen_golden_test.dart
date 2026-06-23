import 'package:alchemist/alchemist.dart';
import 'package:holdclose/l10n/app_localizations.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/journal/journal_wizard_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI goldens of the journal wizard at `/journal/new` — both shapes the
/// screen takes:
///   * the three-step flow (When / situation / attempts), captured on
///     step 0 (the "When did it happen?" preset list + progress dots), and
///   * the single-page quick-note variant ([JournalWizardArgs.quickNote]).
///
/// An in-memory store backs [storageProvider] (the wizard only writes on
/// submit) so the golden never opens the on-device sqlite file.
Widget _host({JournalWizardArgs? args}) {
  final GoRouter router = GoRouter(
    initialLocation: '/journal/new',
    routes: <RouteBase>[
      GoRoute(
        path: '/journal/new',
        builder: (BuildContext context, GoRouterState state) =>
            JournalWizardScreen(args: args),
      ),
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
    ],
    child: SizedBox(
      width: 420,
      height: 900,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('JournalWizardScreen golden', () {
    goldenTest(
      'three-step wizard — step 0 (When did it happen?)',
      fileName: 'journal_wizard_screen_wizard',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'wizard · when step',
            child: _host(),
          ),
        ],
      ),
    );

    goldenTest(
      'quick-note variant — single free-text page',
      fileName: 'journal_wizard_screen_quick_note',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'quick note',
            child: _host(args: const JournalWizardArgs(quickNote: true)),
          ),
        ],
      ),
    );
  });
}
