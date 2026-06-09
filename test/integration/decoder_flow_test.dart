/// End-to-end integration coverage for THE WEDGE — the Behavior Decoder
/// flow (BUILD_SPEC.md §5.2 → §5.3 → §5.4), per TASKS.md Phase 15.3.
///
/// These drive the *real* [CareblazersApp] over the shared Phase 15
/// harness (fake LLM, in-memory drift, pinned clock, no-op TTS) and
/// assert visible state via keys + text — never goldens. Three flows:
///   1. Canonical happy path — picker → triage → result → "That helped"
///      writes a journal row.
///   2. Free-text "Something else" path — the bottom pill routes through
///      triage to the free-text result variant.
///   3. "Try a different approach" — retry bumps the attempt counter and
///      the marked journal row reflects it.
///
/// Mapping to the Phase 15.3 task wording vs. the shipped code:
///   * The task names a "Repetitive questions" card; the locked
///     behavior set (BUILD_SPEC.md §5.2, `Behavior.canonical`) has no
///     such entry, so the canonical path exercises `sundowning` — a real
///     card with a seeded FakeLLMProvider response.
///   * `outcome=helped` is [JournalOutcome.positive] in the model.
///   * The decoder's `attempt` counter is 0-based: the picker→triage push
///     starts at 0, and "Try a different approach" increments to 1. The
///     task's "attempt 1 / attempt 2" therefore assert as 0 / 1 here.
library;

import 'dart:async';

import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/providers/decoder_result_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/decoder/decoder_result_screen.dart';
import 'package:careblazers/screens/decoder/triage_screen.dart';
import 'package:flutter/widgets.dart' show Key;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import 'test_harness.dart';

void main() {
  // Pin the decoder auto-log's clock + id minter so journal rows land at
  // a deterministic [kHarnessClock] (inside the 30-day watch window the
  // InMemoryStorageProvider computes from the same pinned clock) with
  // stable, collision-free ids.
  List<Override> decoderOverrides() {
    int counter = 0;
    return <Override>[
      decoderResultClockProvider.overrideWithValue(() => kHarnessClock),
      decoderResultEntryIdFactoryProvider.overrideWithValue(() {
        counter += 1;
        return 'flow-entry-$counter';
      }),
    ];
  }

  group('Decoder flow — canonical happy path (Phase 15.3)', () {
    testWidgets(
        'picker → triage → result renders all sections + "That helped" '
        'logs a positive journal row', (WidgetTester tester) async {
      final ProviderContainer container = await pumpCareblazersApp(
        tester,
        extraOverrides: decoderOverrides(),
      );

      // Enter the wedge from Home (BUILD_SPEC.md §5.18 decoder launcher).
      unawaited(
          container.read(careblazersRouterProvider).push('/decoder/behavior'));
      await tester.pumpAndSettle();
      expect(find.byType(BehaviorPickerScreen), findsOneWidget);

      // Pick the "Sundowning" card → triage.
      await _tapScrolled(
          tester, BehaviorPickerScreen.cardKey('sundowning'));
      expect(find.byType(TriageScreen), findsOneWidget);
      expect(find.byKey(TriageScreen.progressKey), findsOneWidget);

      await _answerTriage(tester);

      // Result screen — the three §5.4 sections all populated from the
      // seeded FakeLLMProvider response.
      expect(find.byType(DecoderResultScreen), findsOneWidget);
      expect(find.text('Dr. Natali says:'), findsOneWidget);
      expect(find.text('Try saying:'), findsOneWidget);
      expect(find.text('Try this in the room:'), findsOneWidget);
      expect(find.text("Don't say:"), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.sayLineKey(0)), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.tweakLineKey(0)), findsOneWidget);
      expect(
          find.byKey(DecoderResultScreen.dontSayLineKey(0)), findsOneWidget);

      // Footer medical disclaimer (BUILD_SPEC.md §13.1).
      expect(find.byKey(DecoderResultScreen.footerKey), findsOneWidget);
      expect(find.textContaining('not a substitute for medical advice'),
          findsOneWidget);

      // PLAY-button keys for TTS exist (NoopTTSProvider.speak is a no-op
      // stub — tapping must not throw).
      expect(find.byKey(DecoderResultScreen.playAllKey), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.sayLinePlayKey(0)), findsOneWidget);
      await tester.tap(find.byKey(DecoderResultScreen.playAllKey));
      await tester.pumpAndSettle();

      // "That helped — log it" → marks the auto-logged row positive and
      // pops home.
      await _tapScrolled(tester, DecoderResultScreen.thatHelpedKey);
      await _drainHome(tester);

      final List<JournalEntry> entries = await _readEntries(tester, container);
      expect(entries, hasLength(1));
      final JournalEntry entry = entries.single;
      expect(entry.behavior.id, 'sundowning');
      expect(entry.outcome, JournalOutcome.positive);
      expect(entry.attempt, 0); // picker→triage push starts at attempt 0
    });
  });

  group('Decoder flow — free-text "Something else" path (Phase 15.3)', () {
    testWidgets(
        'bottom pill → triage → free-text result variant logs a freetext row',
        (WidgetTester tester) async {
      final ProviderContainer container = await pumpCareblazersApp(
        tester,
        extraOverrides: decoderOverrides(),
      );

      unawaited(
          container.read(careblazersRouterProvider).push('/decoder/behavior'));
      await tester.pumpAndSettle();

      // Tap the "Something else — describe it" pill (BUILD_SPEC.md §5.2).
      await _tapScrolled(tester, BehaviorPickerScreen.freeTextKey);
      expect(find.byType(TriageScreen), findsOneWidget);
      // The free-text path surfaces the generic behavior chip.
      expect(find.text('Something else'), findsWidgets);

      await _answerTriage(tester);

      // The result renders the free-text fallback variant (a non-canonical
      // behavior id routes FakeLLMProvider to its generic script).
      expect(find.byType(DecoderResultScreen), findsOneWidget);
      expect(find.text('Try saying:'), findsOneWidget);
      expect(find.text('Try this in the room:'), findsOneWidget);
      expect(find.text("Don't say:"), findsOneWidget);
      expect(find.byKey(DecoderResultScreen.footerKey), findsOneWidget);

      await _tapScrolled(tester, DecoderResultScreen.thatHelpedKey);
      await _drainHome(tester);

      final List<JournalEntry> entries = await _readEntries(tester, container);
      expect(entries, hasLength(1));
      expect(entries.single.behavior.id, 'freetext');
      expect(entries.single.outcome, JournalOutcome.positive);
      expect(entries.single.attempt, 0);
    });
  });

  group('Decoder flow — "Try a different approach" outcome (Phase 15.3)', () {
    testWidgets(
        'retry bumps attempt to 1; the marked row carries the new attempt',
        (WidgetTester tester) async {
      final ProviderContainer container = await pumpCareblazersApp(
        tester,
        extraOverrides: decoderOverrides(),
      );

      unawaited(
          container.read(careblazersRouterProvider).push('/decoder/behavior'));
      await tester.pumpAndSettle();
      await _tapScrolled(
          tester, BehaviorPickerScreen.cardKey('sundowning'));
      await _answerTriage(tester);
      expect(find.byType(DecoderResultScreen), findsOneWidget);

      // First pass auto-logs attempt 0. "Try a different approach"
      // re-runs the coach with attempt + 1 (a fresh stream + journal row).
      await _tapScrolled(tester, DecoderResultScreen.differentApproachKey);
      // Back on the done view after the second stream settles.
      expect(find.text('Try saying:'), findsOneWidget);

      // Accept the second attempt.
      await _tapScrolled(tester, DecoderResultScreen.thatHelpedKey);
      await _drainHome(tester);

      final List<JournalEntry> entries = await _readEntries(tester, container);
      // Two rows: the abandoned attempt-0 (still pending) + the marked
      // attempt-1.
      expect(entries, hasLength(2));
      final Iterable<JournalEntry> positive = entries
          .where((JournalEntry e) => e.outcome == JournalOutcome.positive);
      expect(positive, hasLength(1));
      expect(positive.single.attempt, 1);
      expect(positive.single.behavior.id, 'sundowning');
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

/// Drain Home's "catch me up" recap stream after a "That helped"
/// navigation. Returning Home with fresh journal activity kicks off
/// [FakeLLMProvider.generateActivitySummary], which spaces its chunks
/// with bare 60ms [Future.delayed] timers — `pumpAndSettle` won't advance
/// those (no frame is scheduled between chunks), so without nudging the
/// fake clock the timer outlives the test and trips the pending-timer
/// invariant. A generous fake-time elapse fires the whole chunk chain.
Future<void> _drainHome(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// Scroll [key] into view (the result screen's outcome buttons sit below
/// the fold on the harness's 420×900 surface) then tap + settle.
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
