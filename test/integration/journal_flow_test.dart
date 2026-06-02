/// Integration coverage for the Journal flow (BUILD_SPEC.md §5.5 list +
/// §5.6 entry detail + the §5.5 wizard), per TASKS.md Phase 15.11.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (fake LLM, in-memory drift-backed storage, pinned clock,
/// no-op TTS/analytics) and assert real navigation + persistence via
/// keys + visible text — never goldens. Six caregiver flows:
///   1. **Week summary** — the "This week" card shows the trailing-7-day
///      incident count + the top behaviors derived from the entries'
///      behavior chips.
///   2. **Pattern alert** — a run of the same evening behavior surfaces
///      the journal's "Heads up" card with the specific pattern text.
///   3. **Day grouping** — Today / Yesterday / Earlier section headers
///      render in that vertical order.
///   4. **Entry detail** — tapping an entry row pushes
///      [JournalEntryScreen] with the behavior chip, the read-only
///      decoder script, and the saved notes.
///   5. **Empty CTA** — with zero entries the empty-state CTA pushes
///      `/decoder/behavior`.
///   6. **Wizard end-to-end** — the multi-step [JournalWizardScreen] →
///      step through when / situation / attempts → Save → back on the
///      list with the new entry rendered.
///
/// Mapping the Phase 15.11 task wording to the shipped code (mirrors the
/// Phase 15.3 decoder flow's "the task names a card the locked set has
/// no entry for" note):
///   * The task's "repetitive-questions" behavior has no entry in the
///     locked [Behavior.canonical] set (BUILD_SPEC.md §5.2), so — like
///     the decoder flow — the canonical evening behavior `sundowning`
///     stands in for it.
///   * The pattern the alert test seeds is therefore the shipped
///     §7.6 rule that fires on a repeated *evening* behavior:
///     "Sundowning entries ≥ 5 in 7 days". There is no separate
///     "3+ repetitions" rule in `PatternDetector` (the §7.6 table locks
///     the v1 rule set), so the test seeds five evening sundowning rows
///     and asserts the surfaced sundowning alert.
///   * The journal list lost its in-screen "add" affordance in the
///     Phase 14 IA refactor (the screen moved out of the tab bar to a
///     root-level route reached from the Medical hub); the wizard at
///     `/journal/new` is now reached from Home + the chat coach. The
///     wizard flow therefore launches it through the production router —
///     the same programmatic-push idiom the Phase 15.6 dose-log and
///     15.7 appointment-edit flows use for routes with no on-screen
///     entry button — then asserts the save round-trips back onto the
///     list.
library;

import 'dart:async';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/journal_entries_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/journal/journal_entry_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/screens/journal/journal_wizard_screen.dart';
import 'package:careblazers/screens/medical/medical_hub_screen.dart';
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
        '"This week" card shows the incident count + behaviors from the '
        'entry chips', (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: journalOverrides());
      // 3 sundowning this week (2 today, 1 yesterday) + 2 accusing last
      // week → thisWeek=3, lastWeek=2, top behavior = Sundowning ×3.
      await _seed(container, <JournalEntry>[
        _decoderEntry(id: 'wk-today-1', createdAt: DateTime(2026, 6, 1, 17, 0)),
        _decoderEntry(id: 'wk-today-2', createdAt: DateTime(2026, 6, 1, 16, 50)),
        _decoderEntry(
            id: 'wk-yesterday-1', createdAt: DateTime(2026, 5, 31, 18, 0)),
        _decoderEntry(
            id: 'wk-last-1',
            behaviorId: 'accusing',
            createdAt: DateTime(2026, 5, 24, 17, 0)),
        _decoderEntry(
            id: 'wk-last-2',
            behaviorId: 'accusing',
            createdAt: DateTime(2026, 5, 23, 17, 0)),
      ]);

      await _openJournal(tester);

      expect(find.byKey(JournalScreen.weekSummaryKey), findsOneWidget);
      expect(find.text('This week'), findsOneWidget);
      expect(find.textContaining('3 incidents logged'), findsOneWidget);
      // Top-behavior topics are derived from the behavior chips.
      expect(find.text('Most common:'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(JournalScreen.weekSummaryKey),
          matching: find.textContaining('Sundowning'),
        ),
        findsWidgets,
      );

      await _flushTimers(tester);
    });
  });

  group('Journal — pattern alert (Phase 15.11)', () {
    testWidgets(
        'a repeated evening behavior surfaces the "Heads up" pattern card',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: journalOverrides());
      // Five evening sundowning rows inside the trailing 7-day window →
      // the §7.6 "Sundowning ≥ 5 / 7 days" rule fires.
      await _seed(container, <JournalEntry>[
        _decoderEntry(id: 'pat-1', createdAt: DateTime(2026, 6, 1, 17, 0)),
        _decoderEntry(id: 'pat-2', createdAt: DateTime(2026, 6, 1, 16, 50)),
        _decoderEntry(id: 'pat-3', createdAt: DateTime(2026, 5, 31, 18, 0)),
        _decoderEntry(id: 'pat-4', createdAt: DateTime(2026, 5, 30, 17, 0)),
        _decoderEntry(id: 'pat-5', createdAt: DateTime(2026, 5, 29, 17, 0)),
      ]);

      await _openJournal(tester);

      expect(find.byKey(JournalScreen.patternAlertKey), findsOneWidget);
      expect(find.textContaining('Heads up'), findsOneWidget);
      // The specific pattern is surfaced, not just a generic flag.
      expect(
        find.textContaining('Sundowning is hitting hard'),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });
  });

  group('Journal — day grouping (Phase 15.11)', () {
    testWidgets('Today / Yesterday / Earlier headers render in order',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: journalOverrides());
      // One entry per bucket so all three headers stay on-screen together
      // and their vertical order is unambiguous.
      await _seed(container, <JournalEntry>[
        _decoderEntry(id: 'grp-today', createdAt: DateTime(2026, 6, 1, 17, 0)),
        _decoderEntry(
            id: 'grp-yesterday', createdAt: DateTime(2026, 5, 31, 18, 0)),
        _decoderEntry(
            id: 'grp-earlier',
            behaviorId: 'accusing',
            createdAt: DateTime(2026, 5, 24, 17, 0)),
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
        'tapping a row opens the entry with chip, decoder script + notes',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: journalOverrides());
      await _seed(container, <JournalEntry>[
        _decoderEntry(
          id: 'detail-1',
          createdAt: DateTime(2026, 6, 1, 17, 0),
          say: const <String>['Mom is safe and resting here with us.'],
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
      // Behavior chip + read-only decoder script + saved notes all render.
      expect(find.byKey(JournalEntryScreen.behaviorChipKey), findsOneWidget);
      expect(find.byKey(JournalEntryScreen.scriptsSectionKey), findsOneWidget);
      expect(find.textContaining('Mom is safe and resting'), findsOneWidget);
      expect(
        find.text('Dimmed the lamps and she settled within ten minutes.'),
        findsOneWidget,
      );

      await _flushTimers(tester);
    });
  });

  group('Journal — empty state (Phase 15.11)', () {
    testWidgets('empty-state CTA pushes /decoder/behavior',
        (WidgetTester tester) async {
      await pumpCareblazersApp(tester, extraOverrides: journalOverrides());

      await _openJournal(tester);

      expect(find.text('Your journal fills itself.'), findsOneWidget);
      expect(find.byKey(JournalScreen.weekSummaryKey), findsNothing);

      await tester.tap(find.byKey(JournalScreen.emptyCtaKey));
      await tester.pumpAndSettle();
      expect(find.byType(BehaviorPickerScreen), findsOneWidget);

      await _flushTimers(tester);
    });
  });

  group('Journal — wizard end-to-end (Phase 15.11)', () {
    testWidgets('wizard → when / situation / attempts → Save → back on list',
        (WidgetTester tester) async {
      final ProviderContainer container =
          await pumpCareblazersApp(tester, extraOverrides: journalOverrides());

      // Land on the (empty) journal list first, then open the wizard the
      // way Home / the chat coach do — a root-level `/journal/new` push.
      await _openJournal(tester);
      expect(find.text('Your journal fills itself.'), findsOneWidget);

      unawaited(container.read(careblazersRouterProvider).push('/journal/new'));
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

      // Back on the list with the new wizard entry rendered. A
      // wizard-authored row carries the [JournalEntry.wizardSentinelBehavior]
      // ("A moment") label — unique to the just-saved entry here.
      expect(find.byType(JournalScreen), findsOneWidget);
      expect(find.textContaining('A moment'), findsWidgets);

      await _flushTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Home → Medical tab → Journal tile → [JournalScreen]. The Journal tile
/// is the last on the Medical hub grid, so it is scrolled into view
/// before the tap on the harness's 420×900 surface.
Future<void> _openJournal(WidgetTester tester) async {
  await tester.tap(tabFor('Medical'));
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

/// Build a decoder-flavored journal row (a real [Behavior] + a full
/// [DecoderResult]) — the auto-logged shape the journal list + entry
/// detail render. Defaults to an evening `sundowning` positive outcome.
JournalEntry _decoderEntry({
  required String id,
  required DateTime createdAt,
  String behaviorId = 'sundowning',
  JournalOutcome outcome = JournalOutcome.positive,
  List<String> say = const <String>['Mom is safe and resting here with us.'],
  List<String> tweak = const <String>['Dim the overhead lights.'],
  List<String> dontSay = const <String>["Don't argue about the time."],
  String? notes,
}) {
  final Behavior behavior = Behavior.byId(behaviorId)!;
  return JournalEntry(
    id: id,
    behavior: behavior,
    triage: const TriageAnswers(
      when: TriageWhen.lateAfternoonEvening,
      whatChanged: TriageWhatChanged.nothing,
      whatTried: TriageWhatTried.talked,
    ),
    result: DecoderResult(
      say: say,
      tweak: tweak,
      dontSay: dontSay,
      generatedAt: createdAt,
    ),
    outcome: outcome,
    attempt: 0,
    createdAt: createdAt,
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
