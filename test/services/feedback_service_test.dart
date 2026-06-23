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
      expect(r.appVersion, '0.1.0+2');
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
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.status);

  final int status;
  Map<String, dynamic>? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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
