import 'package:alchemist/alchemist.dart';
import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/providers/journal_entries_provider.dart';
import 'package:holdclose/providers/pattern_detector_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/journal/journal_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime(2026, 5, 29, 12, 0);

/// Caregiver-authored journal entry (the current shape: free-text
/// situation + attempts, no behavior/triage/result).
JournalEntry _entry({
  required String id,
  required DateTime createdAt,
  String situationText = 'She kept asking to call her mother.',
  String attemptsText = 'I redirected to the photo album and we made tea.',
}) =>
    JournalEntry(
      id: id,
      createdAt: createdAt,
      occurredAt: createdAt,
      situationText: situationText,
      attemptsText: attemptsText,
    );

InMemoryStorageProvider _populatedStorage() {
  final InMemoryStorageProvider storage =
      InMemoryStorageProvider(clock: () => _fixedNow);
  storage.insertJournalEntry(
    _entry(
      id: 'today-1',
      createdAt: _fixedNow.subtract(const Duration(hours: 4)),
    ),
  );
  storage.insertJournalEntry(
    _entry(
      id: 'yesterday-1',
      createdAt: _fixedNow.subtract(const Duration(days: 1, hours: 3)),
      situationText: 'He was sure someone had taken his wallet.',
      attemptsText: 'We looked together and found it in the drawer.',
    ),
  );
  storage.insertJournalEntry(
    _entry(
      id: 'earlier-1',
      createdAt: _fixedNow.subtract(const Duration(days: 4)),
    ),
  );
  return storage;
}

/// CI golden — populated journal with a triggered pattern alert. Picks
/// the most visually-loaded state so the golden catches regressions in
/// the summary card, alert card, group headers and entry tiles in one
/// pass.
void main() {
  group('JournalScreen golden', () {
    goldenTest(
      'renders week summary, alert card, and grouped list',
      fileName: 'journal_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (§5.5 full layout)',
            child: ProviderScope(
              overrides: <Override>[
                storageBackendProvider.overrideWithValue(_populatedStorage()),
                journalScreenClockProvider
                    .overrideWithValue(() => _fixedNow),
                patternDetectorProvider
                    .overrideWithValue(const <PatternAlert>[
                  PatternAlert(
                    kind: 'falls_3plus_7d',
                    text:
                        '3 falls this week. Worth mentioning at the next '
                        'visit.',
                    severity: PatternSeverity.warning,
                  ),
                ]),
              ],
              child: SizedBox(
                width: 420,
                height: 900,
                child: MaterialApp.router(
                  routerConfig: _goldenRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: holdcloseColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/journal',
    routes: <RouteBase>[
      GoRoute(
        path: '/journal',
        builder: (BuildContext context, GoRouterState state) =>
            const JournalScreen(),
      ),
      GoRoute(
        path: '/journal/new',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
      GoRoute(
        path: '/journal/:id',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
}
