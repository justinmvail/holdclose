import 'package:careblazers/l10n/app_localizations.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/journal/journal_wizard_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Pump [JournalWizardScreen] at `/journal/new` with an in-memory store so
/// the test can read back whether an entry was (or wasn't) persisted. A `/`
/// stub makes a successful save's pop/go observable.
Future<InMemoryStorageProvider> _pumpWizard(
  WidgetTester tester, {
  JournalWizardArgs? args,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  addTearDown(storage.dispose);

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
            const Scaffold(body: Center(child: Text('home-stub'))),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return storage;
}

void main() {
  group('JournalWizardScreen — validate-on-submit highlighting', () {
    testWidgets(
        'quick note: empty Save is tappable, shows inline error, persists nothing',
        (WidgetTester tester) async {
      final InMemoryStorageProvider storage = await _pumpWizard(
        tester,
        args: const JournalWizardArgs(quickNote: true),
      );

      // The Save button is tappable even when empty — pressing it surfaces
      // the inline reason instead of silently doing nothing.
      await tester.tap(find.byKey(JournalWizardScreen.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Add a few words about what happened.'), findsOneWidget);
      final List<JournalEntry> saved = await storage.listAllJournalEntries();
      expect(saved, isEmpty, reason: 'empty quick note must not persist');

      // Typing clears the error and lets the note save.
      await tester.enterText(
        find.byKey(JournalWizardScreen.situationFieldKey),
        'She kept asking for her mother.',
      );
      await tester.pumpAndSettle();
      expect(find.text('Add a few words about what happened.'), findsNothing);

      await tester.tap(find.byKey(JournalWizardScreen.submitButtonKey));
      await tester.pumpAndSettle();
      final List<JournalEntry> after = await storage.listAllJournalEntries();
      expect(after, hasLength(1));
    });

    testWidgets(
        'wizard step 1: empty situation blocks Next and highlights the field',
        (WidgetTester tester) async {
      await _pumpWizard(tester);

      // Step 0 (When) — pick a preset so we can advance to the situation step.
      await tester.tap(find.byKey(JournalWizardScreen.whenPresetJustNowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
      await tester.pumpAndSettle();

      // On the situation step with an empty field, Next is tappable but
      // surfaces the inline error and does NOT advance.
      expect(find.byKey(JournalWizardScreen.situationFieldKey), findsOneWidget);
      await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Add a few words about what was happening.'),
          findsOneWidget);
      // Still on the situation step (attempts field not yet shown).
      expect(find.byKey(JournalWizardScreen.attemptsFieldKey), findsNothing);
    });

    testWidgets(
        'wizard step 0: tapping Next with no time picked highlights the error',
        (WidgetTester tester) async {
      await _pumpWizard(tester);

      await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Pick when it happened.'), findsOneWidget);
      // Did not advance — situation field absent.
      expect(find.byKey(JournalWizardScreen.situationFieldKey), findsNothing);
    });
  });
}
