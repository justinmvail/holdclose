/// Integration coverage for the Journal flow (BUILD_SPEC.md §5.5 list +
/// §5.6 entry detail + the §5.5 wizard).
///
/// These drive the *real* [HoldcloseApp] over the shared Phase 15
/// harness (fake LLM, in-memory drift-backed storage, pinned clock,
/// no-op TTS/analytics) and assert real navigation + persistence via
/// keys + visible text — never goldens. Caregiver flows covered:
///   1. **Week summary** — the "This week" card shows the trailing-7-day
///      entry count + a trend subline.
///   2. **Pattern alert** — three entries mentioning a fall this week
///      surface the journal's "Heads up" card with the §7.6 falls text.
///   3. **Day grouping** — Today / Yesterday / Earlier section headers
///      render in that vertical order.
///   4. **Entry detail** — tapping an entry row pushes
///      [JournalEntryScreen] with the read-only situation + attempts
///      blocks and the saved notes.
///   5. **Empty CTA** — with zero entries the empty-state CTA opens the
///      add-entry chooser sheet (it no longer hands off to the removed
///      behavior decoder).
///   6. **Wizard end-to-end** — the multi-step [JournalWizardScreen] →
///      step through when / situation / attempts → Save → back on the
///      list with the new entry rendered.
///
/// The journal list's add affordance is the FAB chooser sheet (Quick
/// note / Guided entry); the guided path is the wizard at `/journal/new`.
/// Several flows launch the wizard through the production router — the
/// same programmatic-push idiom the dose-log and appointment-edit flows
/// use — then assert the save round-trips back onto the list.
library;

import 'dart:async';

import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/providers/journal_entries_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/routing/router.dart';
import 'package:holdclose/screens/journal/journal_entry_screen.dart';
import 'package:holdclose/screens/journal/journal_screen.dart';
import 'package:holdclose/screens/journal/journal_wizard_screen.dart';
import 'package:holdclose/screens/medical/medical_hub_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

/// The journal screen's "now", pinned to a [kHarnessClock]-day evening so
/// the seeded 5pm/4:50pm entries read as *earlier today* (not the
/// future) under the grouping + pattern windows. The harness's
/// in-memory storage windows entries off its own [kHarnessClock]
/// (same calendar day, 30-day lower bound only), so a later wall-time
/// here only shifts the screen's Today/Yesterday math — every seed stays
/// inside the watch window.
final DateTime _now = DateTime(2026, 6, 1, 20, 0);

void main() {
  // Pin the journal screen + pattern-detector clock (both read
  // [journalScreenClockProvider]) so Today/Yesterday/Earlier grouping and
  // the 7-/14-day alert windows are deterministic regardless of the test
  // host's wall clock.
  List<Override> journalOverrides() => <Override>[
        journalScreenClockProvider.overrideWithValue(() => _now),
      ];

  group('Journal — week summary (Phase 15.11)', () {
    testWidgets(
        '"This week" card shows the entry count + trend subline',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpHoldcloseApp(tester, extraOverrides: journalOverrides());
      // 3 entries this week (2 today, 1 yesterday) → thisWeek=3, lastWeek=0.
      await _seed(container, <JournalEntry>[
        _entry(id: 'wk-today-1', createdAt: DateTime(2026, 6, 1, 17, 0)),
        _entry(id: 'wk-today-2', createdAt: DateTime(2026, 6, 1, 16, 50)),
        _entry(id: 'wk-yesterday-1', createdAt: DateTime(2026, 5, 31, 18, 0)),
      ]);

      await _openJournal(tester);

      expect(find.byKey(JournalScreen.weekSummaryKey), findsOneWidget);
      expect(find.text('This week'), findsOneWidget);
      expect(find.textContaining('3 entries logged'), findsOneWidget);
      // No prior week of data → the "first week tracking" subline.
      expect(
        find.descendant(
          of: find.byKey(JournalScreen.weekSummaryKey),
          matching: find.textContaining('first week tracking'),
        ),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });
  });

  group('Journal — pattern alert (Phase 15.11)', () {
    testWidgets(
        'three entries mentioning a fall surface the "Heads up" card',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpHoldcloseApp(tester, extraOverrides: journalOverrides());
      // Three fall-mentioning rows inside the trailing 7-day window → the
      // §7.6 "3+ falls / 7 days" rule fires (behavior-keyed rules retired
      // with the decoder; the falls rule scans the free-text fields).
      await _seed(container, <JournalEntry>[
        _entry(
          id: 'pat-1',
          createdAt: DateTime(2026, 6, 1, 17, 0),
          situationText: 'She had a fall getting up from the chair.',
        ),
        _entry(
          id: 'pat-2',
          createdAt: DateTime(2026, 5, 31, 18, 0),
          situationText: 'He fell in the hallway overnight.',
        ),
        _entry(
          id: 'pat-3',
          createdAt: DateTime(2026, 5, 30, 17, 0),
          situationText: 'Another near fall by the bathroom door.',
        ),
      ]);

      await _openJournal(tester);

      expect(find.byKey(JournalScreen.patternAlertKey), findsOneWidget);
      expect(find.textContaining('Heads up'), findsOneWidget);
      // The specific pattern is surfaced, not just a generic flag.
      expect(
        find.textContaining('3+ falls this week'),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });
  });

  group('Journal — day grouping (Phase 15.11)', () {
    testWidgets('Today / Yesterday / Earlier headers render in order',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpHoldcloseApp(tester, extraOverrides: journalOverrides());
      // One entry per bucket so all three headers stay on-screen together
      // and their vertical order is unambiguous.
      await _seed(container, <JournalEntry>[
        _entry(id: 'grp-today', createdAt: DateTime(2026, 6, 1, 17, 0)),
        _entry(id: 'grp-yesterday', createdAt: DateTime(2026, 5, 31, 18, 0)),
        _entry(id: 'grp-earlier', createdAt: DateTime(2026, 5, 24, 17, 0)),
      ]);

      await _openJournal(tester);

      final Finder today = find.byKey(JournalScreen.groupHeaderKey('Today'));
      final Finder yesterday =
          find.byKey(JournalScreen.groupHeaderKey('Yesterday'));
      final Finder earlier =
          find.byKey(JournalScreen.groupHeaderKey('Earlier'));
      expect(today, findsOneWidget);
      expect(yesterday, findsOneWidget);
      expect(earlier, findsOneWidget);

      final double todayY = tester.getTopLeft(today).dy;
      final double yesterdayY = tester.getTopLeft(yesterday).dy;
      final double earlierY = tester.getTopLeft(earlier).dy;
      expect(todayY, lessThan(yesterdayY));
      expect(yesterdayY, lessThan(earlierY));

      await _flushTimers(tester);
    });
  });

  group('Journal — entry detail (Phase 15.11)', () {
    testWidgets(
        'tapping a row opens the entry with situation, attempts + notes',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpHoldcloseApp(tester, extraOverrides: journalOverrides());
      await _seed(container, <JournalEntry>[
        _entry(
          id: 'detail-1',
          createdAt: DateTime(2026, 6, 1, 17, 0),
          situationText: 'She was anxious and pacing before dinner.',
          attemptsText: 'I put on her favourite music and we slowed down.',
          notes: 'Dimmed the lamps and she settled within ten minutes.',
        ),
      ]);

      await _openJournal(tester);

      final Finder tile =
          find.byKey(JournalScreen.entryTileKey('detail-1'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(find.byType(JournalEntryScreen), findsOneWidget);
      // Read-only situation + attempts blocks + the saved notes all render.
      expect(
        find.byKey(JournalEntryScreen.situationSectionKey),
        findsOneWidget,
      );
      expect(
        find.byKey(JournalEntryScreen.attemptsSectionKey),
        findsOneWidget,
      );
      expect(
        find.textContaining('She was anxious and pacing before dinner.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('I put on her favourite music'),
        findsOneWidget,
      );
      expect(
        find.text('Dimmed the lamps and she settled within ten minutes.'),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });
  });

  group('Journal — empty state (Phase 15.11)', () {
    testWidgets('empty-state CTA opens the add-entry chooser sheet',
        (WidgetTester tester) async {
      await pumpHoldcloseApp(tester, extraOverrides: journalOverrides());

      await _openJournal(tester);

      expect(find.text('Your journal, in your words.'), findsOneWidget);
      expect(find.byKey(JournalScreen.weekSummaryKey), findsNothing);

      await tester.tap(find.byKey(JournalScreen.emptyCtaKey));
      await tester.pumpAndSettle();
      // The CTA now opens the chooser sheet (quick note + guided entry),
      // not the removed behavior decoder.
      expect(find.byKey(JournalScreen.quickNoteOptionKey), findsOneWidget);
      expect(find.byKey(JournalScreen.wizardOptionKey), findsOneWidget);
      expect(find.text('Guided entry'), findsOneWidget);

      await _flushTimers(tester);
    });
  });

  group('Journal — wizard end-to-end (Phase 15.11)', () {
    testWidgets('wizard → when / situation / attempts → Save → back on list',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpHoldcloseApp(tester, extraOverrides: journalOverrides());

      // Land on the (empty) journal list first, then open the wizard the
      // way Home / the chat coach do — a root-level `/journal/new` push.
      await _openJournal(tester);
      expect(find.text('Your journal, in your words.'), findsOneWidget);

      unawaited(container.read(holdcloseRouterProvider).push('/journal/new'));
      await tester.pumpAndSettle();
      expect(find.byType(JournalWizardScreen), findsOneWidget);

      // Step 1 — when.
      await tester.tap(find.byKey(JournalWizardScreen.whenPresetJustNowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
      await tester.pumpAndSettle();

      // Step 2 — situation.
      await tester.enterText(
        find.byKey(JournalWizardScreen.situationFieldKey),
        'She kept asking to call her mother.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
      await tester.pumpAndSettle();

      // Step 3 — attempts → Save.
      await tester.enterText(
        find.byKey(JournalWizardScreen.attemptsFieldKey),
        'I reassured her and we walked to the kitchen for tea.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(JournalWizardScreen.submitButtonKey));
      // Drain the save (insert + pop + SnackBar) with bounded single-frame
      // pumps rather than `pumpAndSettle`: the save re-triggers Home's
      // recap card, whose progress spinner requests frames indefinitely
      // while the summary resolves, so `pumpAndSettle` would never reach
      // quiescence. Stepping advances the pop + SnackBar without waiting
      // on the spinner to go idle.
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Back on the list with the new wizard entry rendered. The tile's
      // title line is the first line of the situation text the caregiver
      // just typed — unique to the just-saved entry here.
      expect(find.byType(JournalScreen), findsOneWidget);
      expect(
        find.textContaining('She kept asking to call her mother.'),
        findsWidgets,
      );

      await _flushTimers(tester);
    });

    testWidgets(
        'the Back button at a middle step steps back, it does not pop the '
        'wizard', (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpHoldcloseApp(tester, extraOverrides: journalOverrides());

      await _openJournal(tester);
      unawaited(container.read(holdcloseRouterProvider).push('/journal/new'));
      await tester.pumpAndSettle();
      expect(find.byType(JournalWizardScreen), findsOneWidget);

      // Step 1 → Step 2 (situation).
      await tester.tap(find.byKey(JournalWizardScreen.whenPresetJustNowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
      await tester.pumpAndSettle();
      // On the situation step: its field is present, the when presets are not.
      expect(find.byKey(JournalWizardScreen.situationFieldKey), findsOneWidget);
      expect(
          find.byKey(JournalWizardScreen.whenPresetJustNowKey), findsNothing);

      // Tap Back — from a middle step this returns to the previous step
      // rather than popping the route, so the wizard stays mounted and the
      // when presets are back on screen.
      await tester.tap(find.byKey(JournalWizardScreen.backButtonKey));
      await tester.pumpAndSettle();
      expect(find.byType(JournalWizardScreen), findsOneWidget);
      expect(
          find.byKey(JournalWizardScreen.whenPresetJustNowKey), findsOneWidget);
      expect(find.byKey(JournalWizardScreen.situationFieldKey), findsNothing);

      await _flushTimers(tester);
    });

    testWidgets(
        'submitting with an empty required field is blocked and writes no '
        'entry', (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpHoldcloseApp(tester, extraOverrides: journalOverrides());

      await _openJournal(tester);
      unawaited(container.read(holdcloseRouterProvider).push('/journal/new'));
      await tester.pumpAndSettle();
      expect(find.byType(JournalWizardScreen), findsOneWidget);

      // Walk to the final (attempts) step with steps 1 + 2 satisfied but
      // leave the required attempts field blank.
      await tester.tap(find.byKey(JournalWizardScreen.whenPresetJustNowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(JournalWizardScreen.situationFieldKey),
        'She kept asking to call her mother.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(JournalWizardScreen.nextButtonKey));
      await tester.pumpAndSettle();

      // On the attempts step the Save button is now always tappable — the
      // wizard validates on submit (and surfaces an inline reason) instead
      // of greying the button out, so a caregiver gets feedback rather than
      // a dead control.
      expect(find.byKey(JournalWizardScreen.attemptsFieldKey), findsOneWidget);
      final ElevatedButton save = tester.widget<ElevatedButton>(
          find.byKey(JournalWizardScreen.submitButtonKey));
      expect(save.onPressed, isNotNull);

      // No inline error yet — it only appears once the caregiver submits.
      expect(
        find.text('Add what you tried — "Nothing yet" works too.'),
        findsNothing,
      );

      await tester.tap(find.byKey(JournalWizardScreen.submitButtonKey));
      await tester.pumpAndSettle();

      // The empty-field submit is blocked: the wizard stays mounted, the
      // attempts field shows its inline validation reason, and nothing was
      // persisted to the journal.
      expect(find.byType(JournalWizardScreen), findsOneWidget);
      expect(
        find.text('Add what you tried — "Nothing yet" works too.'),
        findsOneWidget,
      );
      // Read the storage snapshot outside the fake-async zone — awaiting a
      // bare stream future inside the test zone deadlocks (no pump turns
      // the event loop to deliver the `onListen` snapshot).
      final List<JournalEntry>? entries = await tester.runAsync(
        () => container.read(storageProvider).watchJournalEntries().first,
      );
      expect(entries, isEmpty);

      await _flushTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Home → Care tab → Journal tile → [JournalScreen]. The Journal tile is
/// on the Care hub grid, so it is scrolled into view before the tap on the
/// harness's 420×900 surface.
Future<void> _openJournal(WidgetTester tester) async {
  await tester.tap(tabFor('Care'));
  await tester.pumpAndSettle();
  expect(find.byType(MedicalHubScreen), findsOneWidget);

  final Finder journalTile = findHubTile('Journal');
  await tester.ensureVisible(journalTile);
  await tester.pumpAndSettle();
  await tester.tap(journalTile);
  await tester.pumpAndSettle();
  expect(find.byType(JournalScreen), findsOneWidget);
}

/// Insert [entries] through the harness's in-memory storage (the same
/// seam the journal screen watches), newest-first ordering handled by the
/// store.
Future<void> _seed(
  ProviderContainer container,
  List<JournalEntry> entries,
) async {
  final StorageProvider storage = container.read(storageProvider);
  for (final JournalEntry entry in entries) {
    await storage.insertJournalEntry(entry);
  }
}

/// Build a caregiver-authored journal row (the free-text shape the
/// post-decoder journal list + entry detail render): a situation +
/// attempts, plus optional notes.
JournalEntry _entry({
  required String id,
  required DateTime createdAt,
  String situationText = 'She kept asking to call her mother.',
  String attemptsText = 'I redirected to the photo album and we made tea.',
  String? notes,
}) {
  return JournalEntry(
    id: id,
    createdAt: createdAt,
    occurredAt: createdAt,
    situationText: situationText,
    attemptsText: attemptsText,
    notes: notes,
  );
}

/// Drain any bare-timer streams left mounted (Home's "catch me up" recap,
/// the wizard's save SnackBar) so none outlive the test and trip
/// flutter_test's "Timer still pending" invariant.
///
/// Advances fake time in small single-frame steps rather than a single
/// long pump + `pumpAndSettle`: while a recap streams, the Home card
/// shows a perpetual progress spinner (a ticker that never goes idle), so
/// an unbounded `pumpAndSettle` would never settle. Stepping fires every
/// chunk timer + the wizard's 4-second save SnackBar timer without
/// waiting on quiescence; the spinner's ticker is torn down with the tree
/// at teardown.
Future<void> _flushTimers(WidgetTester tester) async {
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}
