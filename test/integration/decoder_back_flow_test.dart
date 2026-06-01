/// Integration coverage for the decoder back-stack + escape paths
/// (BUILD_SPEC.md §5.2 → §5.3 → §5.4), per TASKS.md Phase 15.4.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (in-memory drift, pinned clock, no-op TTS, [FakeUrlLauncher])
/// and assert real navigation + persistence — never goldens. Four
/// groups, each a distinct way *out* of the wedge:
///   1. Back from triage Q1 pops the whole flow — the route returns to
///      the screen that pushed triage (the behavior picker).
///   2. Back from Q2 reverts to Q1 (an in-screen setState, not a route
///      pop) with Q1's prior pick still painted/selected.
///   3. Back from a still-streaming DecoderResultScreen returns to Home
///      WITHOUT persisting — the auto-log only fires on the LLM's `done`
///      chunk, so backing out mid-stream must leave the journal empty.
///   4. The "I need to talk to Natali" outcome hands the Care Collective
///      URL to [FakeUrlLauncher] — asserted by exact string match.
///
/// Navigation notes:
///   * Every `/decoder/*` route pushes onto the ROOT navigator (see
///     `routing/router.dart`), so each screen is an independent pushed
///     page. Group 3 pushes `/decoder/result` straight onto Home so that
///     popping the result lands back on Home — the literal "returns to
///     Home" the task asks for.
///   * go_router keeps the address (`currentConfiguration.uri`) at the
///     underlying location (`/` here) across *imperative* pushes, so the
///     "router location returned" signal is the re-appearance of the
///     pushing screen, not a path string on the intermediate pushes.
library;

import 'dart:async';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/decoder_result_provider.dart';
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/triage_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/decoder/decoder_result_screen.dart';
import 'package:careblazers/screens/decoder/triage_screen.dart';
import 'package:careblazers/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

/// The exact Care Collective endpoint the "Talk to Natali" outcome opens
/// (BUILD_SPEC.md §5.4). Hard-coded here so group 4 is a genuine
/// string-equality guard against the shipped [careCollectiveUrl] — a
/// pattern/host check would silently pass if the path or utm tags drifted.
const String kExpectedCareCollectiveUrl =
    'https://careblazers.com/care-collective?utm_source=app&utm_medium=decoder';

const Behavior _sundowning =
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');

const TriageAnswers _triage = TriageAnswers(
  when: TriageWhen.lateAfternoonEvening,
  whatChanged: TriageWhatChanged.nothing,
  whatTried: TriageWhatTried.talked,
);

/// Pin the decoder auto-log's clock + id minter so any journal row lands
/// deterministically (mirrors the Phase 15.3 flow test). The pinned clock
/// also keeps an auto-logged row inside the Home "catch me up" window so
/// that surface behaves predictably; group 3 asserts NO row is written at
/// all.
List<Override> _decoderOverrides() {
  int counter = 0;
  return <Override>[
    decoderResultClockProvider.overrideWithValue(() => kHarnessClock),
    decoderResultEntryIdFactoryProvider.overrideWithValue(() {
      counter += 1;
      return 'back-flow-entry-$counter';
    }),
  ];
}

void main() {
  group('Decoder back-stack — Back from Q1 exits the flow (Phase 15.4)', () {
    testWidgets(
        'tapping Back on triage Q1 pops to the behavior picker that pushed it',
        (WidgetTester tester) async {
      final ProviderContainer container = await pumpCareblazersApp(tester);
      final GoRouter router = container.read(careblazersRouterProvider);

      // Enter the wedge from Home, then pick a behavior → triage Q1.
      unawaited(router.push('/decoder/behavior'));
      await tester.pumpAndSettle();
      await _tapScrolled(tester, BehaviorPickerScreen.cardKey('sundowning'));
      expect(find.byType(TriageScreen), findsOneWidget);
      expect(find.byKey(TriageScreen.questionKey(0)), findsOneWidget);

      // Back from Q1 (index 0) is a `maybePop` — it leaves triage entirely.
      await tester.tap(find.byKey(TriageScreen.backButtonKey));
      await tester.pumpAndSettle();

      // The route returns to the screen that pushed triage: the picker is
      // shown again and triage is gone. (go_router leaves the address at
      // the base `/` across imperative pushes, so the screen identity is
      // the location signal.)
      expect(find.byType(BehaviorPickerScreen), findsOneWidget);
      expect(find.byType(TriageScreen), findsNothing);
    });
  });

  group('Decoder back-stack — Back from Q2 reverts to Q1 (Phase 15.4)', () {
    testWidgets(
        'Back on Q2 returns to Q1 with the prior answer still selected',
        (WidgetTester tester) async {
      final ProviderContainer container = await pumpCareblazersApp(tester);
      final GoRouter router = container.read(careblazersRouterProvider);

      unawaited(router.push('/decoder/behavior'));
      await tester.pumpAndSettle();
      await _tapScrolled(tester, BehaviorPickerScreen.cardKey('sundowning'));

      // Q1: pick option 2 ("Late afternoon / evening") → advance to Q2.
      await tester.tap(find.byKey(TriageScreen.optionKey(0, 2)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(TriageScreen.nextButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(TriageScreen.questionKey(1)), findsOneWidget);

      // Back from Q2 → Q1 (an in-screen setState, not a route pop).
      await tester.tap(find.byKey(TriageScreen.backButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(TriageScreen.questionKey(0)), findsOneWidget);
      expect(find.text('1 of 3'), findsOneWidget);

      // The selected pill paints a check; an unselected one doesn't. This
      // is the "radio still selected" assertion (the design uses checked
      // pills, not Material Radios).
      expect(
        find.descendant(
          of: find.byKey(TriageScreen.optionKey(0, 2)),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(TriageScreen.optionKey(0, 0)),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
      // Provider state is the source of truth that the pick survived.
      expect(
        container.read(triageProvider).when,
        TriageWhen.lateAfternoonEvening,
      );
    });
  });

  group('Decoder back-stack — Back from result is non-persisting (Phase 15.4)',
      () {
    testWidgets(
        'backing out of a still-streaming result returns Home + writes no row',
        (WidgetTester tester) async {
      // The auto-log fires only on the LLM's `done` chunk. The seeded
      // FakeLLMProvider streams the (large) sundowning script in 8-token /
      // 60ms slices, so `done` is well over a second away — backing out a
      // few hundred ms in is reliably mid-stream, before any row is written.
      final ProviderContainer container = await pumpCareblazersApp(
        tester,
        extraOverrides: _decoderOverrides(),
      );
      final GoRouter router = container.read(careblazersRouterProvider);

      // Push the result straight onto Home (every /decoder route is a root
      // push), so popping it lands back on Home.
      unawaited(router.push(
        '/decoder/result',
        extra: const DecoderResultArgsExtra(
          behavior: _sundowning,
          triage: _triage,
        ),
      ));
      // Don't pumpAndSettle: the streaming view holds a repeating skeleton
      // animation that never settles (and settling would race the stream
      // all the way to `done`). Fixed pumps advance the page-in transition
      // while leaving the script still streaming.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byType(DecoderResultScreen), findsOneWidget);
      // Guard the precondition: we must still be pre-`done` (no outcome
      // layout yet), otherwise the auto-log would already have run.
      expect(find.text('Try saying:'), findsNothing);

      // Back out via the AppBar's Back button (scoped to the result screen
      // so Home's chrome can't shadow the match).
      await tester.tap(
        find.descendant(
          of: find.byType(DecoderResultScreen),
          matching: find.byType(BackButton),
        ),
      );
      // The result screen (and its skeleton) is gone after the pop, so the
      // tree settles now.
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(DecoderResultScreen), findsNothing);

      // Nothing was persisted — the journal stayed empty.
      final List<JournalEntry> entries = await _readEntries(tester, container);
      expect(entries, isEmpty);
    });
  });

  group('Decoder escape path — "Talk to Natali" outcome (Phase 15.4)', () {
    testWidgets(
        'the third outcome launches the Care Collective URL (exact match)',
        (WidgetTester tester) async {
      final ProviderContainer container = await pumpCareblazersApp(
        tester,
        extraOverrides: _decoderOverrides(),
      );
      final GoRouter router = container.read(careblazersRouterProvider);

      // The harness wires a [FakeUrlLauncher] as the link launcher; read it
      // back through the interface to assert what the CTA handed off.
      final FakeUrlLauncher launcher =
          container.read(linkLauncherProvider) as FakeUrlLauncher;

      unawaited(router.push('/decoder/behavior'));
      await tester.pumpAndSettle();
      await _tapScrolled(tester, BehaviorPickerScreen.cardKey('sundowning'));
      await _answerTriage(tester);

      // Done view — the third outcome button is present.
      expect(find.byType(DecoderResultScreen), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.talkToNataliKey), findsOneWidget);

      await _tapScrolled(tester, DecoderResultScreen.talkToNataliKey);

      expect(launcher.launched, hasLength(1));
      // Exact string match — not a host/path/pattern check.
      expect(launcher.launched.single.toString(), kExpectedCareCollectiveUrl);
      // ...and the shipped constant the screen launches matches it too, so
      // a drift on either side trips the test.
      expect(careCollectiveUrl, kExpectedCareCollectiveUrl);

      // Reaching the result auto-logged a pending journal row, which kicks
      // off Home's background "catch me up" recap. Its FakeLLMProvider
      // stream spaces chunks with bare 60ms timers that `pumpAndSettle`
      // won't advance (no frame is scheduled between chunks); a generous
      // fake-time elapse fires the whole chain so no timer outlives the
      // test.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}

/// Walk the three triage questions (BUILD_SPEC.md §5.3): pick an answer,
/// tap Next, repeat — landing on the result screen after Q3.
Future<void> _answerTriage(WidgetTester tester) async {
  // Q1 — "Late afternoon / evening" (index 2).
  await tester.tap(find.byKey(TriageScreen.optionKey(0, 2)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(TriageScreen.nextButtonKey));
  await tester.pumpAndSettle();
  // Q2 — "Nothing" (index 0).
  await tester.tap(find.byKey(TriageScreen.optionKey(1, 0)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(TriageScreen.nextButtonKey));
  await tester.pumpAndSettle();
  // Q3 — "Talked to them about it" (index 0) → Next pushes the result.
  await tester.tap(find.byKey(TriageScreen.optionKey(2, 0)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(TriageScreen.nextButtonKey));
  await tester.pumpAndSettle();
}

/// Scroll [key] into view (the picker grid + the result screen's outcome
/// buttons sit below the fold on the harness's 420×900 surface) then
/// tap + settle.
Future<void> _tapScrolled(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// Snapshot the journal via the harness's in-memory storage. Wrapped in
/// [WidgetTester.runAsync] so the broadcast change-stream's microtask
/// round-trip runs on the real clock rather than the parked fake one
/// (mirrors the decoder widget-test pattern).
Future<List<JournalEntry>> _readEntries(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final StorageProvider storage = container.read(storageProvider);
  return (await tester.runAsync(
        () => storage.watchJournalEntries().first,
      )) ??
      <JournalEntry>[];
}
