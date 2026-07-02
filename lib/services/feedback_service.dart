import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/build_info.dart';
import '../providers/llm_provider.dart' show shimBaseUrl, shimAuthHeaders;

/// In-app alpha bug/feedback reporter (alpha testing).
///
/// Self-contained on purpose: it never touches the production drift DB or
/// [AppSettings] — a schema migration for a throwaway alpha tool is risk
/// the feature doesn't need. Reports queue as plain files in the app
/// documents dir ([FeedbackOutbox]) so a report is NEVER lost when the
/// laptop/shim is unreachable, then sync to the shim's `/feedback`
/// endpoint ([FeedbackSender]) which appends them to a JSONL + screenshot
/// folder on the operator's machine.

/// Whether the in-app Report affordance is live. **Off by default** so
/// production, `flutter test`, and every golden never render the button
/// or touch the outbox — no golden shifts. Turn on for tester builds with
/// `--dart-define=ALPHA_FEEDBACK=true`.
// ignore: do_not_use_environment
const bool alphaFeedbackEnabled =
    bool.fromEnvironment('ALPHA_FEEDBACK', defaultValue: false);

/// Enables ONLY the in-app feedback UI — the report button, the screenshot
/// overlay, and the alpha error detail in chat — independent of the
/// Google-gated alpha-tester AUTH flow ([alphaFeedbackEnabled], which forces
/// [AlphaAuthProvider]). Set `--dart-define=FEEDBACK=true` to dogfood on a
/// DEMO_MODE device build (fake auth, no Google/backend needed) and still
/// file reports. Full alpha builds get it for free. Production / tests /
/// goldens leave both false, so nothing renders.
// ignore: do_not_use_environment
const bool feedbackUiEnabled = alphaFeedbackEnabled ||
    bool.fromEnvironment('FEEDBACK', defaultValue: false);

/// DEMO_MODE mirror, read locally so this service stays decoupled from the
/// settings provider.
// ignore: do_not_use_environment
const bool _demoMode = bool.fromEnvironment('DEMO_MODE', defaultValue: false);

/// App version + per-build stamp stamped on each report come from the single
/// source of truth ([BuildInfo]); the scripts inject them per build so the
/// operator knows EXACTLY which build a tester was on.

/// The shim feedback endpoint, built from the same base URL the LLM shim
/// uses (so a tester build's `--dart-define=SHIM_URL=...` covers both).
const String feedbackEndpoint = '$shimBaseUrl/feedback';

/// What kind of note the tester is leaving. One tap on submit, huge payoff
/// at triage time.
enum FeedbackCategory { bug, idea, confusing }

extension FeedbackCategoryLabel on FeedbackCategory {
  String get label {
    switch (this) {
      case FeedbackCategory.bug:
        return 'Bug';
      case FeedbackCategory.idea:
        return 'Idea';
      case FeedbackCategory.confusing:
        return 'Confusing';
    }
  }
}

/// One report: the tester's note plus the context auto-captured so they
/// only have to type a sentence.
class FeedbackReport {
  const FeedbackReport({
    required this.id,
    required this.category,
    required this.message,
    required this.route,
    required this.testerName,
    required this.platform,
    required this.osVersion,
    required this.demoMode,
    required this.appVersion,
    required this.createdAt,
    required this.hasScreenshot,
    this.buildStamp = 'dev',
    this.logs = '',
  });

  final String id;
  final FeedbackCategory category;
  final String message;

  /// The go_router location the tester was on (e.g. `/medical/medications`).
  final String route;
  final String testerName;
  final String platform;
  final String osVersion;
  final bool demoMode;
  final String appVersion;
  final DateTime createdAt;
  final bool hasScreenshot;

  /// Per-build stamp (matches Settings → About) — pins which build the
  /// tester was running.
  final String buildStamp;

  /// Snapshot of recent on-device logs ([LogBuffer]) captured when the
  /// report was filed. Empty when nothing was logged. Stored alongside the
  /// report so a "works but wrong" bug carries the context telemetry can't
  /// see.
  final String logs;

  /// Build a report, auto-filling platform/OS/demo/version/id/clock.
  /// [clock] and [idGen] are injectable for deterministic tests.
  factory FeedbackReport.create({
    required FeedbackCategory category,
    required String message,
    required String route,
    required String testerName,
    required bool hasScreenshot,
    String logs = '',
    DateTime Function()? clock,
    String Function()? idGen,
  }) {
    final DateTime now = (clock ?? DateTime.now)();
    return FeedbackReport(
      id: idGen?.call() ?? 'fb_${now.microsecondsSinceEpoch}',
      category: category,
      message: message,
      route: route,
      testerName: testerName,
      platform: _safePlatform(),
      osVersion: _safeOsVersion(),
      demoMode: _demoMode,
      appVersion: BuildInfo.fullVersion,
      createdAt: now,
      hasScreenshot: hasScreenshot,
      buildStamp: BuildInfo.buildStamp,
      logs: logs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'category': category.name,
        'message': message,
        'route': route,
        'tester_name': testerName,
        'platform': platform,
        'os_version': osVersion,
        'demo_mode': demoMode,
        'app_version': appVersion,
        'build_stamp': buildStamp,
        'created_at': createdAt.toIso8601String(),
        'has_screenshot': hasScreenshot,
        'logs': logs,
      };

  factory FeedbackReport.fromJson(Map<String, dynamic> j) => FeedbackReport(
        id: j['id'] as String,
        category: FeedbackCategory.values.firstWhere(
          (FeedbackCategory c) => c.name == j['category'],
          orElse: () => FeedbackCategory.bug,
        ),
        message: j['message'] as String? ?? '',
        route: j['route'] as String? ?? '',
        testerName: j['tester_name'] as String? ?? '',
        platform: j['platform'] as String? ?? '',
        osVersion: j['os_version'] as String? ?? '',
        demoMode: j['demo_mode'] as bool? ?? false,
        appVersion: j['app_version'] as String? ?? '',
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        hasScreenshot: j['has_screenshot'] as bool? ?? false,
        buildStamp: j['build_stamp'] as String? ?? 'dev',
        logs: j['logs'] as String? ?? '',
      );
}

String _safePlatform() {
  try {
    return Platform.operatingSystem;
  } catch (_) {
    return 'unknown';
  }
}

String _safeOsVersion() {
  try {
    return Platform.operatingSystemVersion;
  } catch (_) {
    return '';
  }
}

/// Tester handle, asked once (on first report) and remembered, so the
/// operator knows who found what. Backed by shared_preferences — no
/// settings/DB coupling.
class TesterNameStore {
  const TesterNameStore();

  static const String prefsKey = 'feedback.tester_name';

  Future<String?> get() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? v = prefs.getString(prefsKey)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> set(String name) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, name.trim());
  }
}

/// Remembers where the tester dragged the floating Report button — which
/// side it snapped to and how far down — so it stays put across launches.
class FeedbackButtonStore {
  const FeedbackButtonStore();

  static const String edgeKey = 'feedback.btn_right_edge';
  static const String vFracKey = 'feedback.btn_v_frac';

  /// The saved position, or null if the tester has never moved it (use the
  /// default lower-right resting spot).
  Future<({bool rightEdge, double vFrac})?> get() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(vFracKey)) return null;
    return (
      rightEdge: prefs.getBool(edgeKey) ?? true,
      vFrac: prefs.getDouble(vFracKey) ?? 0.78,
    );
  }

  Future<void> set({required bool rightEdge, required double vFrac}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(edgeKey, rightEdge);
    await prefs.setDouble(vFracKey, vFrac);
  }
}

/// Durable local queue. A report is written here BEFORE any network
/// attempt, so the laptop being asleep can never lose a tester's effort —
/// it syncs on the next launch instead.
class FeedbackOutbox {
  FeedbackOutbox({Directory? overrideRoot}) : _overrideRoot = overrideRoot;

  /// Test seam: point the outbox at a temp dir instead of app documents.
  final Directory? _overrideRoot;

  static const String dirName = 'feedback_outbox';

  Future<Directory> _dir() async {
    final Directory base =
        _overrideRoot ?? await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(base.path, dirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Persist [report] (+ optional [screenshot] PNG bytes) to the queue.
  Future<void> save(FeedbackReport report, Uint8List? screenshot) async {
    final Directory dir = await _dir();
    if (screenshot != null) {
      await File(p.join(dir.path, '${report.id}.png'))
          .writeAsBytes(screenshot, flush: true);
    }
    await File(p.join(dir.path, '${report.id}.json'))
        .writeAsString(jsonEncode(report.toJson()), flush: true);
  }

  /// Every queued (not-yet-delivered) report, oldest first.
  Future<List<FeedbackReport>> listPending() async {
    final Directory dir = await _dir();
    final List<FeedbackReport> out = <FeedbackReport>[];
    await for (final FileSystemEntity e in dir.list()) {
      if (e is File && e.path.endsWith('.json')) {
        try {
          final Map<String, dynamic> m =
              jsonDecode(await e.readAsString()) as Map<String, dynamic>;
          out.add(FeedbackReport.fromJson(m));
        } catch (_) {
          // Skip a malformed/half-written file rather than blocking the rest.
        }
      }
    }
    out.sort((FeedbackReport a, FeedbackReport b) =>
        a.createdAt.compareTo(b.createdAt));
    return out;
  }

  Future<Uint8List?> screenshotBytes(String id) async {
    final Directory dir = await _dir();
    final File f = File(p.join(dir.path, '$id.png'));
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> delete(String id) async {
    final Directory dir = await _dir();
    for (final String ext in <String>['json', 'png']) {
      final File f = File(p.join(dir.path, '$id.$ext'));
      if (await f.exists()) {
        await f.delete();
      }
    }
  }
}

/// Posts a report to the shim. Returns true only on HTTP 200 so the
/// caller deletes it from the outbox; any other outcome (offline, 401,
/// 5xx) leaves it queued for the next flush.
class FeedbackSender {
  FeedbackSender({Dio? dio, this.endpoint = feedbackEndpoint}) : _dio = dio;

  final Dio? _dio;
  final String endpoint;

  Future<bool> send(FeedbackReport report, Uint8List? screenshot) async {
    // A bare Dio() has NO timeouts — a stalled connection would hang the
    // send forever, freezing the report sheet on "Sending…". Bound every
    // phase: on timeout the post throws, we return false, and the report
    // stays queued in the outbox for the next flush (nothing is lost).
    final Dio dio = _dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 20),
        ));
    final Map<String, dynamic> body = report.toJson();
    if (screenshot != null) {
      body['screenshot_base64'] = base64Encode(screenshot);
    }
    try {
      final Response<dynamic> resp = await dio.post<dynamic>(
        endpoint,
        data: body,
        options: Options(
          contentType: Headers.jsonContentType,
          headers: shimAuthHeaders(),
          validateStatus: (int? s) => s != null && s < 500,
        ),
      );
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

/// Orchestrates the two: queue locally, then try to deliver. Submit never
/// throws on a network failure — the report is already safe on disk.
class FeedbackController {
  FeedbackController({required this.outbox, required this.sender});

  final FeedbackOutbox outbox;
  final FeedbackSender sender;

  /// Persist a new report (never lost), then attempt a sync. Returns true
  /// if the queue was delivered (this report reached the shim), false if it
  /// stayed queued for a later flush — callers use it to word the
  /// confirmation honestly ("sent" vs "saved, will send later").
  Future<bool> submit(FeedbackReport report, Uint8List? screenshot) async {
    await outbox.save(report, screenshot);
    final int sent = await flush();
    return sent > 0;
  }

  /// Deliver every queued report; delete each that lands. Returns the
  /// count delivered. Leaves undelivered reports queued for next time.
  Future<int> flush() async {
    final List<FeedbackReport> pending = await outbox.listPending();
    int sent = 0;
    for (final FeedbackReport r in pending) {
      final Uint8List? shot =
          r.hasScreenshot ? await outbox.screenshotBytes(r.id) : null;
      if (await sender.send(r, shot)) {
        await outbox.delete(r.id);
        sent++;
      }
    }
    return sent;
  }
}

/// Fired by the in-header report button to ask [FeedbackOverlay] — which
/// holds the screenshot `RepaintBoundary` — to capture the current screen
/// and open the report sheet. A monotonically-increasing counter the
/// overlay listens to: the value is meaningless, the *change* is the
/// signal. Decouples the button (deep in a screen header) from the capture
/// host (above the router), since they can't share a context.
class FeedbackTrigger extends Notifier<int> {
  @override
  int build() => 0;

  /// Request a screenshot + report sheet from wherever the overlay lives.
  void fire() => state = state + 1;
}

final NotifierProvider<FeedbackTrigger, int> feedbackTriggerProvider =
    NotifierProvider<FeedbackTrigger, int>(FeedbackTrigger.new);

final Provider<FeedbackOutbox> feedbackOutboxProvider =
    Provider<FeedbackOutbox>((Ref ref) => FeedbackOutbox());

final Provider<FeedbackSender> feedbackSenderProvider =
    Provider<FeedbackSender>((Ref ref) => FeedbackSender());

final Provider<TesterNameStore> testerNameStoreProvider =
    Provider<TesterNameStore>((Ref ref) => const TesterNameStore());

final Provider<FeedbackButtonStore> feedbackButtonStoreProvider =
    Provider<FeedbackButtonStore>((Ref ref) => const FeedbackButtonStore());

final Provider<FeedbackController> feedbackControllerProvider =
    Provider<FeedbackController>(
  (Ref ref) => FeedbackController(
    outbox: ref.watch(feedbackOutboxProvider),
    sender: ref.watch(feedbackSenderProvider),
  ),
);
