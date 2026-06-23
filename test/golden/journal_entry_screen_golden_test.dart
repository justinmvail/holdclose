import 'package:alchemist/alchemist.dart';
import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/providers/photo_attacher_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/voice_note_recorder_provider.dart';
import 'package:holdclose/screens/journal/journal_entry_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Caregiver-authored entry with every optional field populated, so the
/// golden exercises the situation + attempts read-only blocks, the notes
/// editor, and the voice row in one pass.
JournalEntry _populatedEntry() => JournalEntry(
      id: 'golden-entry',
      createdAt: DateTime.utc(2026, 5, 29, 19, 42),
      occurredAt: DateTime.utc(2026, 5, 29, 19, 42),
      situationText:
          'She kept asking to call her mother, getting more upset each time.',
      attemptsText:
          'I dimmed the overhead lights and we sat together with a warm lamp.',
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
      'renders situation + attempts blocks, notes, voice + photo rows',
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
