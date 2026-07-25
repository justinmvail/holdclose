import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/providers/journal_entries_provider.dart';
import 'package:holdclose/providers/pattern_detector_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/routing/router.dart';
import 'package:holdclose/screens/journal/journal_entry_screen.dart';
import 'package:holdclose/screens/journal/journal_screen.dart';
import 'package:holdclose/widgets/path_header.dart';
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

/// Build a caregiver-authored journal entry (the current shape:
/// free-text situation + attempts, no behavior/triage/result).
JournalEntry _entry({
  required String id,
  required DateTime createdAt,
  String situationText = 'She kept asking to call her mother.',
  String attemptsText = 'I redirected to the photo album.',
}) =>
    JournalEntry(
      id: id,
      createdAt: createdAt,
      occurredAt: createdAt,
      situationText: situationText,
      attemptsText: attemptsText,
    );

/// Pumps the journal screen behind the real router so `context.push`
/// against `/journal/new` + `/journal/:id` lands on the real builders +
/// the tab shell renders. Storage starts empty by default; callers seed
/// the returned [InMemoryStorageProvider] before pumping. The surface is
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

      expect(find.text('Your journal, in your words.'), findsOneWidget);
      expect(
        find.textContaining('what happened, what you'),
        findsOneWidget,
      );
      expect(find.byKey(JournalScreen.emptyCtaKey), findsOneWidget);
      expect(find.byKey(JournalScreen.weekSummaryKey), findsNothing);
      expect(find.byKey(JournalScreen.entriesListKey), findsNothing);
    });

    testWidgets('empty-state CTA opens the add sheet (opens the add sheet)',
        (WidgetTester tester) async {
      await _pumpJournal(tester);

      await tester.tap(find.byKey(JournalScreen.emptyCtaKey));
      await tester.pumpAndSettle();

      // The CTA now opens the entry-method chooser sheet — both options
      // (quick note + guided entry) surface; the 'Guided entry' option is
      // the renamed wizard.
      expect(find.byKey(JournalScreen.quickNoteOptionKey), findsOneWidget);
      expect(find.byKey(JournalScreen.wizardOptionKey), findsOneWidget);
      expect(find.text('Guided entry'), findsOneWidget);
    });

    testWidgets('add FAB opens the chooser sheet with both entry options',
        (WidgetTester tester) async {
      await _pumpJournal(tester);

      await tester.tap(find.byKey(JournalScreen.addEntryFabKey));
      await tester.pumpAndSettle();

      expect(find.byKey(JournalScreen.quickNoteOptionKey), findsOneWidget);
      expect(find.byKey(JournalScreen.wizardOptionKey), findsOneWidget);
    });

    testWidgets(
        'entries group correctly by Today / Yesterday / Earlier',
        (WidgetTester tester) async {
      final JournalEntry todayEntry = _entry(
        id: 'today-1',
        createdAt: _fixedNow.subtract(const Duration(hours: 2)),
      );
      final JournalEntry yesterdayEntry = _entry(
        id: 'yesterday-1',
        createdAt: _fixedNow.subtract(const Duration(days: 1, hours: 3)),
      );
      final JournalEntry earlierEntry = _entry(
        id: 'earlier-1',
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

    testWidgets('entry tile shows the situation text + attempts preview',
        (WidgetTester tester) async {
      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          _entry(
            id: 'today-1',
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
            situationText: 'She was anxious before dinner.',
            attemptsText: 'We sat by the window with tea.',
          ),
        ],
      );

      // Title line = first line of the situation; sub line = attempts.
      expect(
        find.textContaining('She was anxious before dinner.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('We sat by the window with tea.'),
        findsOneWidget,
      );
    });

    testWidgets('entry with no situation falls back to "Journal note"',
        (WidgetTester tester) async {
      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          JournalEntry(
            id: 'bare-1',
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
            notes: 'Just a quiet day.',
          ),
        ],
      );

      expect(find.textContaining('Journal note'), findsOneWidget);
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

    testWidgets('PathHeader title is "Journal" and there is no auto BackButton',
        (WidgetTester tester) async {
      await _pumpJournal(tester);

      // The Journal root moved from an AppBar to the shared [PathHeader]
      // (CLAUDE.md: feature pages below a hub use PathHeader, never a bare
      // AppBar). Its title is "Journal" (the same word also appears as the
      // trailing breadcrumb crumb, so assert the title property directly).
      final PathHeader header =
          tester.widget<PathHeader>(find.byType(PathHeader));
      expect(header.title, 'Journal');
      // Journal is a tab root reached via the Care hub — navigation is the
      // PathHeader breadcrumb, never an OS-implied AppBar back arrow.
      expect(find.byType(BackButton), findsNothing);
      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('empty-state CTA carries an "add your first entry" semantics',
        (WidgetTester tester) async {
      await _pumpJournal(tester);

      expect(
        hasSemanticsLabel(tester, RegExp('Add your first journal entry')),
        isTrue,
      );
    });

    testWidgets('entry tiles announce the situation and time',
        (WidgetTester tester) async {
      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          _entry(
            id: 'today-1',
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
            situationText: 'She was restless after lunch.',
          ),
        ],
      );

      expect(
        hasSemanticsLabel(
          tester,
          RegExp('She was restless after lunch.*Double-tap to open this entry'),
        ),
        isTrue,
      );
    });

    testWidgets('week summary shows entry count and trend subline',
        (WidgetTester tester) async {
      await _pumpJournal(
        tester,
        entries: <JournalEntry>[
          _entry(
            id: 't1',
            createdAt: _fixedNow.subtract(const Duration(hours: 1)),
          ),
          _entry(
            id: 't2',
            createdAt: _fixedNow.subtract(const Duration(days: 2)),
          ),
          _entry(
            id: 't3',
            createdAt: _fixedNow.subtract(const Duration(days: 3)),
          ),
        ],
      );

      expect(
        find.textContaining('3 entries logged'),
        findsOneWidget,
      );
      // No prior week → "first week tracking" subline.
      expect(
        find.textContaining('first week tracking'),
        findsOneWidget,
      );
    });
  });
}
