import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/journal_entries_provider.dart';
import 'package:careblazers/providers/pattern_detector_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/decoder/behavior_picker_screen.dart';
import 'package:careblazers/screens/journal/journal_entry_screen.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

import '_semantics_matchers.dart';

/// Fixed "now" for every test — pinned at midday so "Today" rolls
/// safely without depending on the host clock. The journal grouping is
/// keyed off this via [journalScreenClockProvider]; the storage layer
/// is fed entries whose `createdAt` is computed off the same anchor.
final DateTime _fixedNow = DateTime(2026, 5, 29, 12, 0);

const Behavior _sundowning =
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');
const Behavior _accusing =
    Behavior(id: 'accusing', label: 'Accusing me', glyph: '💸');

const TriageAnswers _triage = TriageAnswers(
  when: TriageWhen.lateAfternoonEvening,
  whatChanged: TriageWhatChanged.nothing,
  whatTried: TriageWhatTried.talked,
);

JournalEntry _entry({
  required String id,
  required Behavior behavior,
  required DateTime createdAt,
  JournalOutcome outcome = JournalOutcome.positive,
  List<String> tweak = const <String>['dimming lights'],
}) =>
    JournalEntry(
      id: id,
      behavior: behavior,
      triage: _triage,
      result: DecoderResult(
        say: const <String>['line 1'],
        tweak: tweak,
        dontSay: const <String>["don't argue"],
        generatedAt: createdAt,
      ),
      outcome: outcome,
      attempt: 0,
      createdAt: createdAt,
    );

/// Pumps the journal screen behind the real router so `context.push`
/// against `/decoder/behavior` lands on the real builder + the tab
/// shell renders. Storage starts empty by default; callers seed the
/// returned [InMemoryStorageProvider] before pumping. The surface is
/// sized tall enough that the full populated layout (week summary +
/// optional alert + three group sections) lays out within the viewport
/// — otherwise the bottom Earlier group falls outside the lazy-
/// rendering cache and `find.byKey` would silently miss it.
Future<({GoRouter router, InMemoryStorageProvider storage})> _pumpJournal(
  WidgetTester tester, {
  List<JournalEntry> entries = const <JournalEntry>[],
  List<PatternAlert> alerts = const <PatternAlert>[],
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final InMemoryStorageProvider storage =
      InMemoryStorageProvider(clock: () => _fixedNow);
  for (final JournalEntry e in entries) {
    await storage.insertJournalEntry(e);
  }
  final GoRouter router = buildRouter(initialLocation: '/journal');
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
        journalScreenClockProvider.overrideWithValue(() => _fixedNow),
        patternDetectorProvider.overrideWithValue(alerts),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, storage: storage);
}

void main() {
  group('JournalScreen — BUILD_SPEC.md §5.5', () {
    testWidgets('renders the empty state with CTA when zero entries',
        (WidgetTester tester) async {
      await _pumpJournal(tester);

      expect(find.text('Your journal fills itself.'), findsOneWidget);
      expect(
        find.textContaining('Each time you use the decoder'),
        findsOneWidget,
      );
      expect(find.byKey(JournalScreen.emptyCtaKey), findsOneWidget);
      expect(find.byKey(JournalScreen.weekSummaryKey), findsNothing);
      expect(find.byKey(JournalScreen.entriesListKey), findsNothing);
    });

    testWidgets('empty-state CTA pushes /decoder/behavior',
        (WidgetTester tester) async {
      await _pumpJournal(tester);

      await tester.tap(find.byKey(JournalScreen.emptyCtaKey));
      await tester.pumpAndSettle();

      expect(find.byType(BehaviorPickerScreen), findsOneWidget);
    });

    testWidgets(
        'entries group correctly by Today / Yesterday / Earlier',
        (WidgetTester tester) async {
      final JournalEntry todayEntry = _entry(
        id: 'today-1',
        behavior: _sundowning,
        createdAt: _fixedNow.subtract(const Duration(hours: 2)),
      );
      final JournalEntry yesterdayEntry = _entry(
        id: 'yesterday-1',
        behavior: _accusing,
        createdAt: _fixedNow.subtract(const Duration(days: 1, hours: 3)),
      );
      final JournalEntry earlierEntry = _entry(
        id: 'earlier-1',
        behavior: _sundowning,
        createdAt: _fixedNow.subtract(const Duration(days: 4)),
      );

      await _pumpJournal(
        tester,
        entries: <JournalEntry>[todayEntry, yesterdayEntry, earlierEntry],
      );

      expect(find.byKey(JournalScreen.weekSummaryKey), findsOneWidget);
      expect(find.byKey(JournalScreen.entriesListKey), findsOneWidget);

      // All three group headers present.
      expect(find.byKey(JournalScreen.groupHeaderKey('Today')), findsOneWidget);
      expect(
        find.byKey(JournalScreen.groupHeaderKey('Yesterday')),
        findsOneWidget,
      );
      expect(
        find.byKey(JournalScreen.groupHeaderKey('Earlier')),
        findsOneWidget,
      );

      // And each entry is rendered under the right header — assert the
      // visual top-down order by reading the y-offsets of each header
      // and tile.
      double y(Key k) => tester.getTopLeft(find.byKey(k)).dy;

      expect(y(JournalScreen.groupHeaderKey('Today')),
          lessThan(y(JournalScreen.entryTileKey('today-1'))));
      expect(y(JournalScreen.entryTileKey('today-1')),
          lessThan(y(JournalScreen.groupHeaderKey('Yesterday'))));
      expect(y(JournalScreen.groupHeaderKey('Yesterday')),
          lessThan(y(JournalScreen.entryTileKey('yesterday-1'))));
      expect(y(JournalScreen.entryTileKey('yesterday-1')),
          lessThan(y(JournalScreen.groupHeaderKey('Earlier'))));
      expect(y(JournalScreen.groupHeaderKey('Earlier')),
          lessThan(y(JournalScreen.entryTileKey('earlier-1'))));
    });

    testWidgets('pattern alert card displays when detector returns one',
        (WidgetTester tester) async {
      const PatternAlert alert = PatternAlert(
        kind: 'falls_3plus_7d',
        text: '3+ falls this week. Worth mentioning at the next visit.',
        severity: PatternSeverity.warning,
      );

      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          _entry(
            id: 'today-1',
            behavior: _sundowning,
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
          ),
        ],
        alerts: <PatternAlert>[alert],
      );

      expect(find.byKey(JournalScreen.patternAlertKey), findsOneWidget);
      expect(find.textContaining('Heads up'), findsOneWidget);
      expect(find.text(alert.text), findsOneWidget);
    });

    testWidgets(
        'pattern alert card hidden when detector returns empty list',
        (WidgetTester tester) async {
      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          _entry(
            id: 'today-1',
            behavior: _sundowning,
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
          ),
        ],
      );

      expect(find.byKey(JournalScreen.patternAlertKey), findsNothing);
    });

    testWidgets('entry tile push routes to /journal/:id',
        (WidgetTester tester) async {
      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          _entry(
            id: 'today-1',
            behavior: _sundowning,
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
          ),
        ],
      );

      // The journal-entry detail route is registered at /journal/:id on
      // the root navigator (BUILD_SPEC.md §4.2), so a successful push
      // mounts JournalEntryScreen above the tab shell and the new
      // entryId arrives via path-parameters.
      await tester.tap(find.byKey(JournalScreen.entryTileKey('today-1')));
      await tester.pumpAndSettle();

      expect(find.byType(JournalEntryScreen), findsOneWidget);
      final JournalEntryScreen pushed =
          tester.widget<JournalEntryScreen>(find.byType(JournalEntryScreen));
      expect(pushed.entryId, 'today-1');
    });

    testWidgets('AppBar title is "Journal" and has no BackButton',
        (WidgetTester tester) async {
      await _pumpJournal(tester);

      expect(find.widgetWithText(AppBar, 'Journal'), findsOneWidget);
      // Journal is a tab root — never an auto back arrow.
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('empty-state CTA announces the decoder hand-off',
        (WidgetTester tester) async {
      await _pumpJournal(tester);

      expect(
        hasSemanticsLabel(tester, RegExp('Open the decoder')),
        isTrue,
      );
    });

    testWidgets('entry tiles announce behavior and time',
        (WidgetTester tester) async {
      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          _entry(
            id: 'today-1',
            behavior: _sundowning,
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
          ),
        ],
      );

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('Sundowning.*Double-tap to open this entry'),
        ),
        isTrue,
      );
    });

    testWidgets('week summary shows top behavior and trend subline',
        (WidgetTester tester) async {
      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          _entry(
            id: 't1',
            behavior: _sundowning,
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
          ),
          _entry(
            id: 't2',
            behavior: _sundowning,
            createdAt: _fixedNow.subtract(const Duration(days: 2)),
          ),
          _entry(
            id: 't3',
            behavior: _accusing,
            createdAt: _fixedNow.subtract(const Duration(days: 3)),
          ),
        ],
      );

      expect(
        find.textContaining('3 incidents logged'),
        findsOneWidget,
      );
      // Sundowning leads the rank — 2 this week.
      expect(
        find.textContaining('Sundowning'),
        findsWidgets,
      );
    });
  });
}
