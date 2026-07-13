import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:holdclose/services/feedback_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final DateTime fixed = DateTime.utc(2026, 6, 5, 14, 30);
  FeedbackReport buildReport({
    FeedbackCategory category = FeedbackCategory.bug,
    String message = 'It crashed',
    String route = '/medical/medications',
    bool hasScreenshot = false,
    String logs = '',
    String id = 'fb_1',
  }) =>
      FeedbackReport.create(
        category: category,
        message: message,
        route: route,
        testerName: 'Sam',
        hasScreenshot: hasScreenshot,
        logs: logs,
        clock: () => fixed,
        idGen: () => id,
      );

  group('FeedbackReport', () {
    test('create() stamps id/clock/platform/demo/version', () {
      final FeedbackReport r = buildReport();
      expect(r.id, 'fb_1');
      expect(r.createdAt, fixed);
      expect(r.category, FeedbackCategory.bug);
      expect(r.message, 'It crashed');
      expect(r.route, '/medical/medications');
      expect(r.testerName, 'Sam');
      // Host platform under `flutter test` is the desktop OS, not empty.
      expect(r.platform, isNotEmpty);
      expect(r.demoMode, isFalse); // no DEMO_MODE define in tests
      // Single source of truth (BuildInfo): version name + 'dev' stamp when
      // no APP_VERSION/BUILD_STAMP defines are set (i.e. under `flutter test`).
      expect(r.appVersion, '0.1.0+dev');
      expect(r.buildStamp, 'dev'); // no BUILD_STAMP define in tests
      expect(r.logs, ''); // none attached
    });

    test('toJson/fromJson round-trips every field', () {
      final FeedbackReport r = buildReport(
        category: FeedbackCategory.idea,
        hasScreenshot: true,
        logs: 'line one\nline two',
      );
      final FeedbackReport back = FeedbackReport.fromJson(r.toJson());
      expect(back.id, r.id);
      expect(back.category, FeedbackCategory.idea);
      expect(back.message, r.message);
      expect(back.route, r.route);
      expect(back.testerName, r.testerName);
      expect(back.demoMode, r.demoMode);
      expect(back.appVersion, r.appVersion);
      expect(back.buildStamp, r.buildStamp);
      expect(back.logs, 'line one\nline two');
      expect(back.createdAt, r.createdAt);
      expect(back.hasScreenshot, isTrue);
    });

    test('unknown category falls back to bug', () {
      final FeedbackReport back = FeedbackReport.fromJson(<String, dynamic>{
        'id': 'x',
        'category': 'gibberish',
        'created_at': fixed.toIso8601String(),
      });
      expect(back.category, FeedbackCategory.bug);
    });
  });

  group('FeedbackOutbox (file queue)', () {
    late Directory tmp;
    late FeedbackOutbox outbox;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fb_outbox_test');
      outbox = FeedbackOutbox(overrideRoot: tmp);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('save → listPending → screenshotBytes → delete', () async {
      final FeedbackReport r = buildReport(hasScreenshot: true);
      await outbox.save(r, Uint8List.fromList(<int>[1, 2, 3, 4]));

      final List<FeedbackReport> pending = await outbox.listPending();
      expect(pending, hasLength(1));
      expect(pending.first.id, 'fb_1');
      expect(pending.first.message, 'It crashed');

      final Uint8List? shot = await outbox.screenshotBytes('fb_1');
      expect(shot, isNotNull);
      expect(shot!.length, 4);

      await outbox.delete('fb_1');
      expect(await outbox.listPending(), isEmpty);
      expect(await outbox.screenshotBytes('fb_1'), isNull);
    });

    test('listPending sorts oldest first and skips malformed files',
        () async {
      await outbox.save(buildReport(id: 'fb_2', message: 'second'), null);
      await outbox.save(
        FeedbackReport.create(
          category: FeedbackCategory.bug,
          message: 'first',
          route: '/x',
          testerName: 'Sam',
          hasScreenshot: false,
          clock: () => fixed.subtract(const Duration(minutes: 5)),
          idGen: () => 'fb_1',
        ),
        null,
      );
      // Drop a junk .json that must be skipped, not throw.
      await File('${tmp.path}/${FeedbackOutbox.dirName}/broken.json')
          .writeAsString('{not json');

      final List<FeedbackReport> pending = await outbox.listPending();
      expect(pending.map((FeedbackReport r) => r.id), <String>['fb_1', 'fb_2']);
    });
  });

  group('FeedbackSender', () {
    test('200 → true, body carries fields + screenshot base64', () async {
      final _StubAdapter adapter = _StubAdapter(200);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final FeedbackSender sender = FeedbackSender(dio: dio);

      final bool ok = await sender.send(
        buildReport(
          category: FeedbackCategory.confusing,
          hasScreenshot: true,
          logs: 'tapped mic\nrouteVoiceIntent -> chat',
        ),
        Uint8List.fromList(<int>[9, 8, 7]),
      );

      expect(ok, isTrue);
      expect(adapter.lastBody!['category'], 'confusing');
      expect(adapter.lastBody!['message'], 'It crashed');
      expect(adapter.lastBody!['route'], '/medical/medications');
      expect(adapter.lastBody!['screenshot_base64'],
          base64Encode(<int>[9, 8, 7]));
      // On-device logs ride along for triage context.
      expect(adapter.lastBody!['logs'], 'tapped mic\nrouteVoiceIntent -> chat');
    });

    test('500 → false (left queued)', () async {
      final Dio dio = Dio()..httpClientAdapter = _StubAdapter(500);
      final FeedbackSender sender = FeedbackSender(dio: dio);
      expect(await sender.send(buildReport(), null), isFalse);
    });

    test('401 → false (auth failure does not delete the report)', () async {
      final Dio dio = Dio()..httpClientAdapter = _StubAdapter(401);
      final FeedbackSender sender = FeedbackSender(dio: dio);
      expect(await sender.send(buildReport(), null), isFalse);
    });

    test('posts to the configured endpoint with the session JWT', () async {
      // Regression guard (2026-07-13): reports used to go to the operator's
      // laptop shim. That endpoint died when the backend moved to Cloudflare
      // and the laptop's Funnel was switched off — builds kept baking the dead
      // URL, so every tester report vanished and nothing noticed, because
      // nothing asserted where a report actually goes. This does.
      final _StubAdapter adapter = _StubAdapter(200);
      final FeedbackSender sender = FeedbackSender(
        dio: Dio()..httpClientAdapter = adapter,
        endpoint: 'https://worker.example/api/v1/feedback',
        tokenLoader: () async => 'session-jwt-123',
      );

      expect(await sender.send(buildReport(), null), isTrue);
      expect(adapter.lastUrl, 'https://worker.example/api/v1/feedback');
      expect(adapter.lastHeaders!['Authorization'], 'Bearer session-jwt-123');
    });

    test('a 401 re-exchanges the session and retries — a rotated secret must '
        'not strand a report', () async {
      // The 2026-07-13 outage: FORUM_JWT_SECRET was rotated on the Worker, so
      // the phone's stored token no longer verified. Every authed call 401'd,
      // including this one, and nothing re-authenticated — the tester's bug
      // report sat undelivered while the app looked fine.
      final _SequenceAdapter adapter = _SequenceAdapter(<int>[401, 200]);
      int recoveries = 0;
      final List<String> tokens = <String>['stale', 'fresh'];
      int calls = 0;
      final FeedbackSender sender = FeedbackSender(
        dio: Dio()..httpClientAdapter = adapter,
        endpoint: 'https://worker.example/api/v1/feedback',
        tokenLoader: () async => tokens[calls++],
        onUnauthorized: () async {
          recoveries += 1;
          return true;
        },
      );

      expect(await sender.send(buildReport(), null), isTrue);
      expect(recoveries, 1);
      expect(adapter.auths, <String>['Bearer stale', 'Bearer fresh']);
    });

    test('no session yet → the report stays QUEUED, never dropped', () async {
      // A tester who hits a bug before/while signing in must not lose their
      // report: a failed token load leaves it in the outbox for the next
      // launch rather than deleting it.
      final _StubAdapter adapter = _StubAdapter(200);
      final FeedbackSender sender = FeedbackSender(
        dio: Dio()..httpClientAdapter = adapter,
        endpoint: 'https://worker.example/api/v1/feedback',
        tokenLoader: () async => throw StateError('no session'),
      );

      expect(await sender.send(buildReport(), null), isFalse);
      expect(adapter.lastUrl, isNull, reason: 'must not post without auth');
    });
  });

  group('FeedbackController (queue then deliver)', () {
    late Directory tmp;
    late FeedbackOutbox outbox;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fb_ctrl_test');
      outbox = FeedbackOutbox(overrideRoot: tmp);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('flushPending RETRIES until the session exists (2026-07-13 regression)',
        () async {
      // The bug this guards: the launch flush fired once, from the first
      // post-frame callback — BEFORE the forum session JWT had been restored.
      // The send failed (correctly leaving the report queued), and nothing
      // retried for the rest of the session, so a real tester report sat
      // undelivered on the phone while every other authed call worked.
      await outbox.save(buildReport(id: 'fb_queued'), null);
      final _AuthLagsSender sender = _AuthLagsSender(succeedFromAttempt: 3);
      final FeedbackController controller =
          FeedbackController(outbox: outbox, sender: sender);

      // Injected sleep: assert the backoff without actually waiting on it.
      final List<Duration> slept = <Duration>[];
      final int delivered = await controller.flushPending(
        sleep: (Duration d) async => slept.add(d),
      );

      expect(delivered, 1, reason: 'the report must land once auth is ready');
      expect(sender.attempts, 3);
      expect(await outbox.listPending(), isEmpty);
      expect(slept, isNotEmpty, reason: 'it must back off between attempts');
    });

    test('flushPending on an empty outbox costs ONE check and no waiting',
        () async {
      final _AuthLagsSender sender = _AuthLagsSender(succeedFromAttempt: 1);
      final FeedbackController controller =
          FeedbackController(outbox: outbox, sender: sender);

      final List<Duration> slept = <Duration>[];
      expect(
        await controller.flushPending(sleep: (Duration d) async => slept.add(d)),
        0,
      );
      expect(sender.attempts, 0, reason: 'nothing queued → nothing to send');
      expect(slept, isEmpty, reason: 'a normal launch must not schedule timers');
    });

    test('submit delivers and clears the queue when the shim is up',
        () async {
      final FeedbackController c = FeedbackController(
        outbox: outbox,
        sender: FeedbackSender(dio: Dio()..httpClientAdapter = _StubAdapter(200)),
      );
      await c.submit(buildReport(hasScreenshot: true),
          Uint8List.fromList(<int>[1, 2, 3]));
      expect(await outbox.listPending(), isEmpty);
    });

    test('submit keeps the report queued when the shim is down, '
        'and a later flush delivers it', () async {
      final FeedbackController down = FeedbackController(
        outbox: outbox,
        sender: FeedbackSender(dio: Dio()..httpClientAdapter = _StubAdapter(500)),
      );
      await down.submit(buildReport(), null);
      expect(await outbox.listPending(), hasLength(1)); // not lost

      final FeedbackController up = FeedbackController(
        outbox: outbox,
        sender: FeedbackSender(dio: Dio()..httpClientAdapter = _StubAdapter(200)),
      );
      final int delivered = await up.flush();
      expect(delivered, 1);
      expect(await outbox.listPending(), isEmpty);
    });
  });

  group('TesterNameStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('get is null until set, then remembers (trimmed)', () async {
      const TesterNameStore store = TesterNameStore();
      expect(await store.get(), isNull);
      await store.set('  Sam  ');
      expect(await store.get(), 'Sam');
    });
  });

  group('FeedbackButtonStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('null until moved, then remembers side + vertical fraction',
        () async {
      const FeedbackButtonStore store = FeedbackButtonStore();
      expect(await store.get(), isNull);
      await store.set(rightEdge: false, vFrac: 0.42);
      final ({bool rightEdge, double vFrac})? pos = await store.get();
      expect(pos, isNotNull);
      expect(pos!.rightEdge, isFalse);
      expect(pos.vFrac, closeTo(0.42, 1e-9));
    });
  });
}

/// Minimal dio adapter: returns a fixed status + a JSON body, and records
/// the request body sent so the test can assert what the app posted.
/// A sender that FAILS until [succeedFromAttempt] — models the real launch
/// race: the forum session JWT is restored asynchronously, so the first flush
/// after a cold start finds no token and cannot deliver.
class _AuthLagsSender extends FeedbackSender {
  _AuthLagsSender({required this.succeedFromAttempt})
      : super(dio: Dio()..httpClientAdapter = _StubAdapter(200));

  final int succeedFromAttempt;
  int attempts = 0;

  @override
  Future<bool> send(FeedbackReport report, Uint8List? screenshot) async {
    attempts++;
    return attempts >= succeedFromAttempt;
  }
}

/// Replays a fixed sequence of status codes, recording the Authorization
/// header of each attempt — so a retry can be shown to carry the FRESH token.
class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.statuses);

  final List<int> statuses;
  final List<String> auths = <String>[];
  int _i = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    auths.add(options.headers['Authorization'] as String? ?? '');
    final int status = statuses[_i < statuses.length ? _i : statuses.length - 1];
    _i++;
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(<String, String>{'ok': 'x'})),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.status);

  final int status;
  Map<String, dynamic>? lastBody;
  String? lastUrl;
  Map<String, dynamic>? lastHeaders;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastUrl = options.uri.toString();
    lastHeaders = Map<String, dynamic>.from(options.headers);
    if (options.data is Map) {
      lastBody = Map<String, dynamic>.from(options.data as Map);
    }
    final List<int> bytes = utf8.encode(jsonEncode(<String, String>{'stored': 'x'}));
    return ResponseBody.fromBytes(
      bytes,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
