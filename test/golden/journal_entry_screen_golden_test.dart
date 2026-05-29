import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/photo_attacher_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/providers/voice_note_recorder_provider.dart';
import 'package:careblazers/screens/journal/journal_entry_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const Behavior _sundowning =
    Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅');

const TriageAnswers _triage = TriageAnswers(
  when: TriageWhen.lateAfternoonEvening,
  whatChanged: TriageWhatChanged.nothing,
  whatTried: TriageWhatTried.talked,
);

JournalEntry _populatedEntry() => JournalEntry(
      id: 'golden-entry',
      behavior: _sundowning,
      triage: _triage,
      result: DecoderResult(
        say: const <String>[
          "That sounds really hard. I'm right here with you.",
          "Let's sit together for a minute.",
        ],
        tweak: const <String>[
          'Dim overhead lights and switch on a warm lamp.',
        ],
        dontSay: const <String>[
          "Don't say 'you already asked me that'.",
        ],
        generatedAt: DateTime.utc(2026, 5, 29, 19, 42),
      ),
      outcome: JournalOutcome.positive,
      attempt: 0,
      createdAt: DateTime.utc(2026, 5, 29, 19, 42),
      notes: 'Sat with her on the porch — the lamp helped within a minute.',
      voiceNotePath: 'voice-fixture.m4a',
    );

InMemoryStorageProvider _populatedStorage() {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  storage.insertJournalEntry(_populatedEntry());
  return storage;
}

void main() {
  group('JournalEntryScreen golden', () {
    goldenTest(
      'renders behavior + outcome chips, scripts, notes, voice + photo rows',
      fileName: 'journal_entry_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (§5.6 full layout)',
            child: ProviderScope(
              overrides: <Override>[
                storageBackendProvider
                    .overrideWithValue(_populatedStorage()),
                voiceNoteRecorderProvider
                    .overrideWithValue(NoopVoiceNoteRecorder()),
                photoAttacherProvider
                    .overrideWithValue(const NoopPhotoAttacher()),
              ],
              child: SizedBox(
                width: 420,
                height: 1100,
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
    initialLocation: '/journal/golden-entry',
    routes: <RouteBase>[
      GoRoute(
        path: '/journal',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: ':id',
            builder: (BuildContext context, GoRouterState state) =>
                JournalEntryScreen(
              entryId: state.pathParameters['id'] ?? '',
            ),
          ),
        ],
      ),
    ],
  );
}
