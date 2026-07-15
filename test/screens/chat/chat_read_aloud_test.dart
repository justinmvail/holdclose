/// The coach must actually SPEAK.
///
/// The whole TTS stack shipped — two engines, a quiet-hours-aware selector, and
/// a Settings toggle promising "Plays the coach's replies through your phone
/// voice" — and NOTHING in the app ever called `speak()`. The toggle was live,
/// persisted, and completely inert. These tests pin the callers, so the pipe
/// can never come unplugged again without a red suite.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/settings.dart';
import 'package:holdclose/providers/settings_provider.dart';
import 'package:holdclose/providers/tts_provider.dart';
import 'package:holdclose/screens/chat/chat_screen.dart';
import 'package:holdclose/services/chat_repository.dart';
import 'package:holdclose/services/chat_service.dart';
import 'package:holdclose/theme.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime.utc(2026, 5, 29, 19, 42);

/// Records every utterance instead of touching a platform channel.
class _RecordingTTS implements TTSProvider {
  final List<String> spoken = <String>[];
  int cancels = 0;

  @override
  Future<void> speak(
    String text, {
    required String voiceId,
    required double speed,
  }) async =>
      spoken.add(text);

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<List<TTSVoice>> availableVoices() async => const <TTSVoice>[];
}

/// Pins settings without the storage round-trip the real notifier does.
class _FixedSettings extends Settings {
  _FixedSettings(this._settings);
  final AppSettings _settings;

  @override
  AppSettings build() => _settings;
}

class _ScriptedBackend implements ChatLLMBackend {
  _ScriptedBackend(this.body);
  final String body;

  @override
  Stream<ChatDelta> streamReply({
    required String systemPrompt,
    required List<ChatTurn> history,
  }) async* {
    // Two fragments, so a naive implementation that spoke every streamed
    // snapshot would be caught saying the reply twice.
    yield ChatDeltaText(body.substring(0, body.length ~/ 2));
    await Future<void>.delayed(Duration.zero);
    yield ChatDeltaText(body.substring(body.length ~/ 2));
  }
}

Future<_RecordingTTS> _pumpAndSend(
  WidgetTester tester, {
  required String reply,
  required bool readAloud,
  String send = 'How do I handle sundowning?',
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final ChatRepository repo = ChatRepository(db);
  await repo.createConversation(
    id: 'c1',
    title: 'placeholder',
    createdAt: _fixedNow(),
  );

  final _RecordingTTS tts = _RecordingTTS();
  int n = 0;
  final ChatService service = ChatService(
    repository: repo,
    backend: _ScriptedBackend(reply),
    idFactory: () => 'msg-${++n}',
    clock: _fixedNow,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        chatRepositoryBackendProvider.overrideWithValue(repo),
        chatServiceProvider.overrideWithValue(service),
        settingsProvider.overrideWith(
          () => _FixedSettings(
            AppSettings.defaults().copyWith(readScriptsAloud: readAloud),
          ),
        ),
        // Reproduce main.dart's wiring — settings flow into the TTS selector —
        // but swap the ENGINE for a recorder. Overriding `ttsProvider` outright
        // would defeat the very mute rule these tests exist to check, so the
        // production rule (`shouldMuteTts`) still decides; only the thing that
        // would touch a platform channel is faked.
        ttsSettingsProvider.overrideWith((Ref ref) => ref.watch(settingsProvider)),
        ttsProvider.overrideWith(
          (Ref ref) => shouldMuteTts(ref.watch(ttsSettingsProvider), _fixedNow())
              ? const NoopTTSProvider()
              : tts,
        ),
        // The mic/replay path — records into the SAME spy, so a replay tap is
        // observable regardless of the "Read replies aloud" toggle.
        voiceReplyTtsProvider.overrideWith(
          (Ref ref) =>
              shouldMuteVoiceReply(ref.watch(ttsSettingsProvider), _fixedNow())
                  ? const NoopTTSProvider()
                  : tts,
        ),
      ],
      child: MaterialApp.router(
        theme: ThemeData(scaffoldBackgroundColor: holdcloseColors.background),
        routerConfig: GoRouter(
          initialLocation: '/chat/c1',
          routes: <RouteBase>[
            GoRoute(
              path: '/chat/:id',
              builder: (BuildContext context, GoRouterState state) =>
                  ChatScreen(conversationId: state.pathParameters['id'] ?? ''),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).first, send);
  await tester.tap(find.byKey(ChatScreen.sendButtonKey));
  await tester.pumpAndSettle();

  return tts;
}

void main() {
  group('the coach reads its reply aloud when the caregiver asked it to', () {
    testWidgets('a completed reply is spoken once', (WidgetTester tester) async {
      final _RecordingTTS tts = await _pumpAndSend(
        tester,
        reply: 'Try dimming the lights an hour before dusk.',
        readAloud: true,
      );

      expect(tts.spoken, <String>['Try dimming the lights an hour before dusk.'],
          reason: 'exactly one utterance — the FINAL body, not every '
              'streamed snapshot of it');
    });

    testWidgets('nothing is spoken when "Read replies aloud" is off',
        (WidgetTester tester) async {
      final _RecordingTTS tts = await _pumpAndSend(
        tester,
        reply: 'Try dimming the lights an hour before dusk.',
        readAloud: false,
      );

      expect(tts.spoken, isEmpty);
    });

    testWidgets('action markers are never read out loud',
        (WidgetTester tester) async {
      // The body on the wire carries machine markers. Speaking one would have
      // the coach saying "open square bracket action colon add underscore
      // medication" to a caregiver.
      final _RecordingTTS tts = await _pumpAndSend(
        tester,
        reply: 'Added it. [action:add_medication name="Aspirin" dosage="81 mg"]',
        readAloud: true,
      );

      expect(tts.spoken.single, 'Added it.');
    });

    testWidgets('leaving the thread stops the voice', (WidgetTester tester) async {
      final _RecordingTTS tts = await _pumpAndSend(
        tester,
        reply: 'A long reply the caregiver walks out on.',
        readAloud: true,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      expect(tts.cancels, greaterThan(0),
          reason: 'a reply that keeps talking after you navigate away is the '
              'app shouting from another room, with no way to silence it');
    });
  });

  group('the replay button re-reads a message on demand', () {
    testWidgets('tapping replay speaks the message — even with the toggle off',
        (WidgetTester tester) async {
      // fb_1784071829881657: a caregiver who missed the reply wants to hear it
      // again. Toggle OFF so the auto-read stays silent and the ONLY utterance
      // is the deliberate replay tap.
      final _RecordingTTS tts = await _pumpAndSend(
        tester,
        reply: 'Try dimming the lights an hour before dusk.',
        readAloud: false,
      );
      expect(tts.spoken, isEmpty, reason: 'no auto-read with the toggle off');

      final Finder replay = find.byWidgetPredicate((Widget w) =>
          w is IconButton &&
          w.icon is Icon &&
          (w.icon as Icon).icon == Icons.volume_up_outlined);
      expect(replay, findsOneWidget, reason: 'the finalised reply offers replay');

      await tester.tap(replay);
      await tester.pumpAndSettle();

      expect(tts.spoken,
          <String>['Try dimming the lights an hour before dusk.'],
          reason: 'replay reads the message aloud regardless of the toggle');
    });
  });

  group('what gets spoken is written for the EAR, not the eye', () {
    test('markdown emphasis, headings and bullets are stripped', () {
      expect(
        speechText('**Take a breath.**\n\n- Dim the lights\n- Close the blinds'),
        'Take a breath.\nDim the lights\nClose the blinds',
      );
    });

    test('a body that is only markers speaks nothing', () {
      expect(speechText('   '), isEmpty);
    });
  });

  group('quiet hours vs the "Read replies aloud" toggle', () {
    final AppSettings on = AppSettings.defaults().copyWith(
      readScriptsAloud: true,
      quietHoursEnabled: true,
      allowAudioDuringQuietHours: false,
    );
    final DateTime threeAm = DateTime(2026, 7, 13, 3);
    final DateTime noon = DateTime(2026, 7, 13, 12);

    test('the mic speaks back even when the toggle is OFF', () {
      // Voice in, voice out. The caregiver SPOKE — a silent answer reads as a
      // broken mic, not as a respected preference.
      expect(
        shouldMuteVoiceReply(on.copyWith(readScriptsAloud: false), noon),
        isFalse,
      );
      expect(shouldMuteTts(on.copyWith(readScriptsAloud: false), noon), isTrue,
          reason: 'the TYPED path still obeys the toggle');
    });

    test('quiet hours still mute the mic — a 3am answer must not wake the house',
        () {
      expect(shouldMuteVoiceReply(on, threeAm), isTrue);
    });

    test('"allow audio anyway" un-mutes the mic during quiet hours', () {
      expect(
        shouldMuteVoiceReply(on.copyWith(allowAudioDuringQuietHours: true),
            threeAm),
        isFalse,
      );
    });
  });
}
