/// APP ↔ DEPLOYED BACKEND contract test — the only automated test where the
/// app's REAL networking code talks to a REAL Cloudflare Worker.
///
/// Why this exists. Everything else fakes one side of the wire:
///   * the widget/unit suites inject `FakeLLMProvider` / `FakeForumApiClient`;
///   * `critical_path_smoke_test.dart` boots the real app but overrides
///     `forumApiClientProvider` with a fake and runs in DEMO_MODE;
///   * `backend/test-live` drives the deployed Worker but over raw `fetch` —
///     it never runs a line of the app's client code.
/// So the seam between them — the app's `dio` client, the `/api/v1` path
/// building, the `Authorization` header, the JSON serialisation, and above
/// all the app's SSE PARSER — was covered by nothing but manual tapping.
///
/// That seam is exactly where the 2026-07-13 coach bug lived: the Worker's
/// chat stream never terminated, so `logUsage()` never ran and the LLM spend
/// caps were silently dead. Fixing it CHANGED THE WIRE (the Worker now emits
/// `data: [DONE]` and closes). This test is what proves the app still parses
/// that stream and — critically — that the reply stream COMPLETES rather than
/// hanging forever, which is what a caregiver would experience as a coach
/// reply that never finishes.
///
/// It uses the app's real [ForumApiClient] + [ApiChatBackend], constructed the
/// same way `chatLLMBackend` / `forumApiClient` construct them in production
/// (baseUrl + a token loader). The one thing it cannot automate is Google
/// sign-in itself (that needs a real Google ID token from the OS sheet), so it
/// injects a forged session JWT — byte-identical in shape to the one
/// `POST /auth/google` mints, since the Worker verifies it with the same
/// secret. Everything downstream of sign-in is the real thing.
///
/// RUN IT (never runs by default — `flutter test` only globs `test/`):
///
///   tools/live_backend_test.sh          # mints the JWT + runs this file
///
/// or by hand:
///
///   flutter test test_live/live_backend_test.dart \
///     --dart-define=FORUM_API_URL=https://holdclose-forum-dev.jcsvonellc.workers.dev \
///     --dart-define=LIVE_JWT=<a session JWT signed with the Worker's secret>
///
/// Without both defines every test SKIPS, so this can never hit the network or
/// spend inference money by accident. It lives in `test_live/` — NOT `test/`
/// (the no-live-LLM-in-`test/` invariant) and NOT `integration_test/` (which
/// `flutter test` refuses to run without a connected device, though this needs
/// none — it's pure Dart + HTTP). A default `flutter test` only globs `test/`,
/// so this file never fires unless you ask for it. It makes exactly ONE real
/// inference call and deletes the account it creates.
library;

import 'dart:convert' show base64Decode, jsonDecode;
import 'dart:typed_data' show Uint8List;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/chat.dart' show MessageRole;
import 'package:holdclose/models/forum.dart'
    show CircleDto, ForumProfile, SyncDoc;
import 'package:holdclose/services/api_chat_backend.dart';
import 'package:holdclose/services/chat_service.dart'
    show ChatDelta, ChatDeltaError, ChatDeltaText, ChatTurn;
import 'package:holdclose/services/feedback_service.dart';
import 'package:holdclose/services/forum_api_client.dart';

/// The deployed Worker origin. Same define the shipped app reads.
const String _baseUrl = String.fromEnvironment('FORUM_API_URL');

/// A session JWT signed with the Worker's FORUM_JWT_SECRET — stands in for
/// the token `POST /auth/google` would mint after a real sign-in.
const String _liveJwt = String.fromEnvironment('LIVE_JWT');

bool get _configured => _baseUrl.isNotEmpty && _liveJwt.isNotEmpty;

/// A 1x1 PNG — a genuine raster image, small enough to be free to upload.
final List<int> _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Guard: never let this suite point at production by accident.
bool get _looksLikeProd => _baseUrl.contains('holdclose.care');

void main() {
  // The app's real client, wired exactly as production wires it.
  late ForumApiClient api;
  late ApiChatBackend coach;

  setUpAll(() {
    if (!_configured) return;
    if (_looksLikeProd) {
      fail('live_backend_test must not be pointed at production ($_baseUrl)');
    }
    api = ForumApiClient(
      baseUrl: _baseUrl,
      tokenLoader: () async => _liveJwt,
    );
    coach = ApiChatBackend(
      baseUrl: _baseUrl,
      tokenLoader: () async => _liveJwt,
    );
  });

  tearDownAll(() async {
    if (!_configured) return;
    // The forged identity is a real account on the dev backend — remove it
    // (cascades its circle + synced care data) so runs don't accrete rows.
    try {
      await api.deleteMyProfile();
    } catch (_) {
      // Already gone / never created — nothing to undo.
    }
  });

  group('app → deployed Worker', () {
    test('the app can bootstrap its profile through the real client', () async {
      final ForumProfile profile = await api.bootstrapProfile();
      expect(profile.id, isNotEmpty);
    }, skip: _configured ? false : 'set FORUM_API_URL + LIVE_JWT');

    test(
      'the app can create a circle and round-trip care data through sync',
      () async {
        // This is the app's own serialisation — SyncDocWrite.toWire(), the
        // patient envelope, the cursor handling — against the real D1, not a
        // hand-rolled JSON body like the backend suite sends.
        final CircleDto circle = await api.createCircle(
          'live-app-test circle',
          patient: SyncPatientWrite(
            payload: const <String, dynamic>{'name': 'App Test Loved One'},
            clientUpdatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        expect(circle.id, isNotEmpty);

        final String medId = 'live-app-med-${DateTime.now().microsecondsSinceEpoch}';
        final SyncPushResult pushed = await api.syncPush(
          circle.id,
          docs: <SyncDocWrite>[
            SyncDocWrite(
              id: medId,
              collection: 'medication',
              payload: const <String, dynamic>{
                'name': 'Lisinopril',
                'dose': '10 mg',
              },
              clientUpdatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ],
        );
        expect(pushed.cursor, greaterThan(0));

        // Pull it back through the app's parser — proves the wire the server
        // speaks is the wire the app reads (field names, nesting, types).
        // `payload` crosses the wire as a JSON STRING, so assert on its
        // decoded content rather than the envelope.
        final SyncPullResult pulled = await api.syncPull(circle.id, since: 0);
        expect(pulled.patient, isNotNull);
        expect(
          jsonDecode(pulled.patient!.payload) as Map<String, dynamic>,
          containsPair('name', 'App Test Loved One'),
        );
        expect(
          pulled.docs.map((SyncDoc d) => d.id),
          contains(medId),
          reason: 'the doc the app pushed must come back through syncPull',
        );
      },
      skip: _configured ? false : 'set FORUM_API_URL + LIVE_JWT',
    );

    test(
      'the app can upload an avatar and the URL it gets back actually loads',
      () async {
        // The avatar feature was dead end-to-end until 2026-07-13: no upload
        // route existed and R2_PUBLIC_URL pointed at a domain that resolved
        // nowhere. The load-bearing assertion is the SECOND one — that the URL
        // the app receives can actually be fetched, which is what the community
        // feed does when it renders a face.
        final ForumProfile updated = await api.uploadAvatar(
          bytes: _tinyPng,
          contentType: 'image/png',
        );
        expect(updated.avatarUrl, isNotNull);

        // Fetch the ABSOLUTE url the API handed us, exactly as the feed's
        // Image.network would — no auth header, no base-path assumptions.
        final Response<List<int>> fetched = await Dio().get<List<int>>(
          updated.avatarUrl!,
          options: Options(responseType: ResponseType.bytes),
        );
        expect(fetched.statusCode, 200);
        expect(fetched.headers.value('content-type'), 'image/png');
        expect(fetched.data, _tinyPng);
      },
      skip: _configured ? false : 'set FORUM_API_URL + LIVE_JWT',
    );

    test(
      "the app's REAL FeedbackSender delivers a report to the Worker",
      () async {
        // The Report button stopped delivering when the backend moved to
        // Cloudflare (the shim it posted to went dark). This drives the app's
        // ACTUAL FeedbackSender — same dio, same headers, same payload — at the
        // deployed Worker, so "the client code works" stops being an assumption.
        final FeedbackSender sender = FeedbackSender(
          endpoint: '$_baseUrl/api/v1/feedback',
          tokenLoader: () async => _liveJwt,
        );
        final FeedbackReport report = FeedbackReport.create(
          category: FeedbackCategory.bug,
          message: 'live-suite: FeedbackSender end-to-end probe',
          route: '/setup',
          testerName: 'live-suite',
          hasScreenshot: true,
          logs: 'probe log line',
        );

        final bool delivered = await sender.send(
          report,
          Uint8List.fromList(_tinyPng),
        );
        expect(delivered, isTrue,
            reason: 'the app-side sender must reach the Worker');
      },
      skip: _configured ? false : 'set FORUM_API_URL + LIVE_JWT',
    );

    test(
      "the coach's reply streams AND COMPLETES — the app's SSE parser against "
      'the real Worker (2026-07-13 regression)',
      () async {
        // THE point of this file. The Worker's chat stream used to never
        // terminate; the fix made it emit `data: [DONE]` and close. If the
        // app's parser disagreed with that wire — or if the stream still hung
        // — a caregiver would watch a reply that never finishes. `await for`
        // completing IS the assertion: a hung stream fails this test by
        // timing out rather than passing quietly.
        final StringBuffer reply = StringBuffer();
        final List<String> errors = <String>[];

        await coach
            .streamReply(
              systemPrompt:
                  'You are a supportive caregiving coach. Reply in one short '
                  'sentence.',
              history: const <ChatTurn>[
                ChatTurn(
                  role: MessageRole.user,
                  content: 'Say hello to a caregiver testing the app.',
                ),
              ],
            )
            .forEach((ChatDelta delta) {
          switch (delta) {
            case ChatDeltaText(:final String text):
              reply.write(text);
            case ChatDeltaError(:final String message):
              errors.add(message);
          }
        }).timeout(
          // Generous for real inference + a cold Worker, but FINITE: the bug
          // this guards against is precisely a stream that never ends.
          const Duration(seconds: 60),
          onTimeout: () => fail(
            'the coach stream never completed — the Worker is hanging again '
            '(usage logging + the spend caps die with it)',
          ),
        );

        expect(errors, isEmpty, reason: 'the coach stream reported an error');
        expect(
          reply.toString().trim(),
          isNotEmpty,
          reason: 'the app parsed no text out of the real SSE stream',
        );
        // The vendor must never reach the client (a UI-copy invariant that
        // only a REAL response can actually prove).
        expect(reply.toString().toLowerCase(), isNot(contains('llama')));
        expect(reply.toString().toLowerCase(), isNot(contains('cloudflare')));
      },
      skip: _configured ? false : 'set FORUM_API_URL + LIVE_JWT',
    );
  });
}
