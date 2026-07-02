import 'package:holdclose/models/journal_entry.dart';
import 'package:holdclose/providers/photo_attacher_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/providers/voice_note_recorder_provider.dart';
import 'package:holdclose/screens/journal/journal_entry_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Spying recorder that captures every call without touching a real
/// audio plugin (BUILD_SPEC.md §5.6 — "mock the audio plugin"). Returns
/// a deterministic path so the journal-entry screen's "🔊 attached"
/// affordance lights up after stop().
class _SpyRecorder implements VoiceNoteRecorder {
  final List<String> events = <String>[];
  final List<String> played = <String>[];
  bool _recording = false;
  String? nextPath = 'voice-fixture-1.m4a';

  @override
  bool get isRecording => _recording;

  @override
  Future<void> start() async {
    events.add('start');
    _recording = true;
  }

  @override
  Future<String?> stop() async {
    events.add('stop');
    _recording = false;
    return nextPath;
  }

  @override
  Future<void> play(String path) async {
    events.add('play');
    played.add(path);
  }

  @override
  Future<void> stopPlayback() async {
    events.add('stopPlayback');
  }
}

class _SpyPhotoAttacher implements PhotoAttacher {
  final List<String> events = <String>[];
  String? nextPath = 'photo-fixture-1.jpg';

  @override
  Future<String?> pickPhoto({
    PhotoSource source = PhotoSource.library,
    int maxSide = 2048,
    int quality = 80,
  }) async {
    events.add('pick');
    return nextPath;
  }
}

/// Caregiver-authored journal entry (the post-decoder shape: a free-text
/// situation + attempts, plus optional notes/voice/photo).
JournalEntry _entry({
  String id = 'entry-1',
  String? situationText = 'She kept asking to call her mother.',
  String? attemptsText = 'I redirected to the photo album.',
  String? notes,
  String? voiceNotePath,
  String? photoPath,
}) =>
    JournalEntry(
      id: id,
      createdAt: DateTime.utc(2026, 5, 29, 19, 42),
      occurredAt: DateTime.utc(2026, 5, 29, 19, 42),
      situationText: situationText,
      attemptsText: attemptsText,
      notes: notes,
      voiceNotePath: voiceNotePath,
      photoPath: photoPath,
    );

Future<({
  GoRouter router,
  InMemoryStorageProvider storage,
  _SpyRecorder recorder,
  _SpyPhotoAttacher photos,
})> _pumpEntry(
  WidgetTester tester, {
  required JournalEntry seedEntry,
  _SpyRecorder? recorder,
  _SpyPhotoAttacher? photos,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  addTearDown(storage.dispose);
  await storage.insertJournalEntry(seedEntry);

  final _SpyRecorder rec = recorder ?? _SpyRecorder();
  final _SpyPhotoAttacher pic = photos ?? _SpyPhotoAttacher();

  final GoRouter router = GoRouter(
    initialLocation: '/journal/${seedEntry.id}',
    routes: <RouteBase>[
      GoRoute(
        path: '/journal',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('journal-list-fallback'))),
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

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
        voiceNoteRecorderProvider.overrideWithValue(rec),
        photoAttacherProvider.overrideWithValue(pic),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  // Storage stream's first emission lands a microtask after subscribe;
  // pumping under the real clock lets the AsyncValue settle to data
  // before tests assert any field.
  await tester.runAsync(() async {
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pumpAndSettle();

  return (router: router, storage: storage, recorder: rec, photos: pic);
}

Future<List<JournalEntry>> _readEntries(
  WidgetTester tester,
  InMemoryStorageProvider storage,
) async {
  // runAsync escapes the fake clock so the broadcast stream's microtask
  // round-trip lands before .first resolves.
  return await tester.runAsync(
        () => storage.watchJournalEntries().first,
      ) ??
      const <JournalEntry>[];
}

void main() {
  group('JournalEntryScreen — BUILD_SPEC.md §5.6', () {
    testWidgets('renders situation + attempts read-only blocks',
        (WidgetTester tester) async {
      await _pumpEntry(
        tester,
        seedEntry: _entry(
          situationText: 'She was anxious before dinner.',
          attemptsText: 'We sat by the window with tea.',
        ),
      );

      expect(
        find.byKey(JournalEntryScreen.situationSectionKey),
        findsOneWidget,
      );
      expect(find.text('She was anxious before dinner.'), findsOneWidget);
      expect(
        find.byKey(JournalEntryScreen.attemptsSectionKey),
        findsOneWidget,
      );
      expect(find.text('We sat by the window with tea.'), findsOneWidget);
      // Section headers describe the read-only content.
      expect(find.text('What happened'), findsOneWidget);
      expect(find.text('What you tried'), findsOneWidget);
    });

    testWidgets('situation/attempts blocks are dropped when fields are blank',
        (WidgetTester tester) async {
      await _pumpEntry(
        tester,
        seedEntry: _entry(situationText: null, attemptsText: null),
      );

      expect(find.byKey(JournalEntryScreen.situationSectionKey), findsNothing);
      expect(find.byKey(JournalEntryScreen.attemptsSectionKey), findsNothing);
      expect(find.text('What happened'), findsNothing);
      expect(find.text('What you tried'), findsNothing);
      // Notes editor still renders so a bare entry is still editable.
      expect(find.byKey(JournalEntryScreen.notesFieldKey), findsOneWidget);
    });

    testWidgets('shows "not here anymore" when id is unknown',
        (WidgetTester tester) async {
      // Seed an unrelated entry so the storage stream resolves, then
      // navigate to a bogus id.
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await storage.insertJournalEntry(_entry(id: 'real-entry'));

      final GoRouter router = GoRouter(
        initialLocation: '/journal/does-not-exist',
        routes: <RouteBase>[
          GoRoute(
            path: '/journal/:id',
            builder: (BuildContext context, GoRouterState state) =>
                JournalEntryScreen(
              entryId: state.pathParameters['id'] ?? '',
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            voiceNoteRecorderProvider.overrideWithValue(_SpyRecorder()),
            photoAttacherProvider.overrideWithValue(_SpyPhotoAttacher()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();

      expect(find.byKey(JournalEntryScreen.notFoundKey), findsOneWidget);
    });

    testWidgets('editing notes + tapping Save persists via storage',
        (WidgetTester tester) async {
      final pumped = await _pumpEntry(tester, seedEntry: _entry());

      await tester.enterText(
        find.byKey(JournalEntryScreen.notesFieldKey),
        'Sat with her on the porch. The light helped.',
      );
      await tester.tap(find.byKey(JournalEntryScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<JournalEntry> entries = await _readEntries(tester, pumped.storage);
      expect(entries, hasLength(1));
      expect(entries.single.notes,
          'Sat with her on the porch. The light helped.');
      // SnackBar confirmation surfaces.
      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('initial notes value hydrates from the loaded entry',
        (WidgetTester tester) async {
      await _pumpEntry(
        tester,
        seedEntry: _entry(notes: 'Already wrote this earlier.'),
      );

      expect(find.text('Already wrote this earlier.'), findsOneWidget);
    });

    testWidgets('record → stop captures path; Save persists voiceNotePath',
        (WidgetTester tester) async {
      final pumped = await _pumpEntry(tester, seedEntry: _entry());

      // First tap starts recording. Button label flips to "Stop".
      await tester.tap(find.byKey(JournalEntryScreen.recordButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Stop recording'), findsOneWidget);
      expect(pumped.recorder.events, <String>['start']);

      // Stop returns a path → the "🔊 attached" chip + play button appear.
      await tester.tap(find.byKey(JournalEntryScreen.recordButtonKey));
      await tester.pumpAndSettle();
      expect(pumped.recorder.events, <String>['start', 'stop']);
      expect(find.byKey(JournalEntryScreen.voiceChipKey), findsOneWidget);
      expect(
        find.byKey(JournalEntryScreen.playVoiceButtonKey),
        findsOneWidget,
      );

      // Save persists the captured path through the storage layer.
      await tester.tap(find.byKey(JournalEntryScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<JournalEntry> entries = await _readEntries(tester, pumped.storage);
      expect(entries.single.voiceNotePath, 'voice-fixture-1.m4a');
    });

    testWidgets('play button hands the stored path to the recorder',
        (WidgetTester tester) async {
      final pumped = await _pumpEntry(
        tester,
        seedEntry: _entry(voiceNotePath: 'pre-saved.m4a'),
      );

      expect(find.byKey(JournalEntryScreen.voiceChipKey), findsOneWidget);
      await tester.tap(find.byKey(JournalEntryScreen.playVoiceButtonKey));
      await tester.pumpAndSettle();

      expect(pumped.recorder.events, contains('play'));
      expect(pumped.recorder.played, <String>['pre-saved.m4a']);
    });

    testWidgets('photo attach hands path to PhotoAttacher and persists on Save',
        (WidgetTester tester) async {
      final pumped = await _pumpEntry(tester, seedEntry: _entry());

      // No thumbnail yet — entry starts photo-less.
      expect(find.byKey(JournalEntryScreen.photoThumbnailKey), findsNothing);

      await tester.tap(find.byKey(JournalEntryScreen.photoButtonKey));
      await tester.pumpAndSettle();

      expect(pumped.photos.events, <String>['pick']);
      // Thumbnail surfaces immediately once the picker returns.
      expect(
        find.byKey(JournalEntryScreen.photoThumbnailKey),
        findsOneWidget,
      );

      await tester.tap(find.byKey(JournalEntryScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<JournalEntry> entries = await _readEntries(tester, pumped.storage);
      expect(entries.single.photoPath, 'photo-fixture-1.jpg');
    });

    testWidgets('photo picker cancel leaves the entry photoPath null',
        (WidgetTester tester) async {
      final _SpyPhotoAttacher photos = _SpyPhotoAttacher()..nextPath = null;
      final pumped = await _pumpEntry(
        tester,
        seedEntry: _entry(),
        photos: photos,
      );

      await tester.tap(find.byKey(JournalEntryScreen.photoButtonKey));
      await tester.pumpAndSettle();

      expect(pumped.photos.events, <String>['pick']);
      expect(find.byKey(JournalEntryScreen.photoThumbnailKey), findsNothing);

      await tester.tap(find.byKey(JournalEntryScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<JournalEntry> entries = await _readEntries(tester, pumped.storage);
      expect(entries.single.photoPath, isNull);
    });
  });

  group('JournalEntryScreen — delete flow (§5.6)', () {
    testWidgets('kebab → Delete → Confirm removes the entry + pops',
        (WidgetTester tester) async {
      final pumped = await _pumpEntry(tester, seedEntry: _entry());

      await tester.tap(find.byKey(JournalEntryScreen.kebabMenuKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(JournalEntryScreen.deleteMenuItemKey));
      await tester.pumpAndSettle();

      // Confirm dialog visible.
      expect(find.text('Delete this entry?'), findsOneWidget);
      expect(find.byKey(JournalEntryScreen.deleteConfirmKey), findsOneWidget);
      expect(find.byKey(JournalEntryScreen.deleteCancelKey), findsOneWidget);

      await tester.tap(find.byKey(JournalEntryScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      // Entry gone from storage.
      final List<JournalEntry> entries = await _readEntries(tester, pumped.storage);
      expect(entries, isEmpty);

      // Pop dropped back to the /journal fallback.
      expect(
        pumped.router.routerDelegate.currentConfiguration.uri.path,
        '/journal',
      );
      expect(find.text('journal-list-fallback'), findsOneWidget);
    });

    testWidgets('kebab → Delete → Cancel leaves the entry intact',
        (WidgetTester tester) async {
      final pumped = await _pumpEntry(tester, seedEntry: _entry());

      await tester.tap(find.byKey(JournalEntryScreen.kebabMenuKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(JournalEntryScreen.deleteMenuItemKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(JournalEntryScreen.deleteCancelKey));
      await tester.pumpAndSettle();

      final List<JournalEntry> entries = await _readEntries(tester, pumped.storage);
      expect(entries, hasLength(1));
      expect(entries.single.id, 'entry-1');
      // Still on the entry screen.
      expect(
        pumped.router.routerDelegate.currentConfiguration.uri.path,
        '/journal/entry-1',
      );
    });
  });

  group('JournalEntryScreen — header', () {
    testWidgets('PathHeader title shows the entry timestamp',
        (WidgetTester tester) async {
      await _pumpEntry(tester, seedEntry: _entry());

      // The title moved from the AppBar into the body PathHeader.title
      // (rendered as a Text). Local-time render of the seed's UTC
      // 2026-05-29 19:42 — assert the month abbreviation + 12-hour
      // suffix without pinning the host's offset.
      final RegExp pattern =
          RegExp(r'^(May|Jun) \d{1,2} · \d{1,2}:\d{2} (AM|PM)$');
      final Finder titleText = find.byWidgetPredicate(
        (Widget widget) => widget is Text && pattern.hasMatch(widget.data ?? ''),
      );
      // Render uses local time; just assert the month + AM/PM suffix
      // shape so DST/timezone of the host doesn't make this flaky.
      expect(titleText, findsOneWidget);
    });
  });
}
