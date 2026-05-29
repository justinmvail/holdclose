import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/journal_entries_provider.dart';
import 'package:careblazers/providers/pattern_detector_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/journal/journal_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

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
      outcome: JournalOutcome.positive,
      attempt: 0,
      createdAt: createdAt,
    );

InMemoryStorageProvider _populatedStorage() {
  final InMemoryStorageProvider storage =
      InMemoryStorageProvider(clock: () => _fixedNow);
  storage.insertJournalEntry(
    _entry(
      id: 'today-1',
      behavior: _sundowning,
      createdAt: _fixedNow.subtract(const Duration(hours: 4)),
    ),
  );
  storage.insertJournalEntry(
    _entry(
      id: 'yesterday-1',
      behavior: _accusing,
      createdAt: _fixedNow.subtract(const Duration(days: 1, hours: 3)),
    ),
  );
  storage.insertJournalEntry(
    _entry(
      id: 'earlier-1',
      behavior: _sundowning,
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
                    kind: 'sundowning_5plus_7d',
                    text:
                        'Sundowning is hitting hard this week. Talk to your '
                        'doctor about evening routines.',
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
                      color: careblazersColors.background,
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
        path: '/journal/:id',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
      GoRoute(
        path: '/decoder/behavior',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
}
