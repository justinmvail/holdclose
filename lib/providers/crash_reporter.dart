import 'dart:async';
import 'dart:io' show Platform;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../config/build_info.dart';

part 'crash_reporter.g.dart';

/// Backend for AUTOMATIC crash aggregation (observability).
///
/// This runs ALONGSIDE — never replaces — the existing on-device,
/// user-initiated report path (`LogBuffer` + `CrashLog` in `main.dart`,
/// surfaced by the feedback sheet). That path is caregiver-controlled and
/// stays intact. This interface adds an OPT-IN automatic pipe to a
/// SELF-HOSTED aggregator so a crash that the caregiver never reports is
/// still visible to the operator.
///
/// Privacy posture (non-negotiable — this app carries PHI):
///  * Disabled unless a `--dart-define=SENTRY_DSN` is baked in. EMPTY dsn =
///    disabled, so dev / `flutter test` / demo builds initialize NOTHING and
///    behave exactly as before.
///  * NEVER initializes under `flutter test` (guarded on `FLUTTER_TEST`).
///  * A mandatory PHI scrubber ([scrubEvent]) runs on every outbound event —
///    it strips message bodies, breadcrumb data, request bodies, user
///    email/name, and any chat/journal/med free text, keeping only the
///    exception type + stack + non-PII device/app context.
///
/// The concrete impl (the aggregation SDK) is DEV-FACING only — its vendor
/// name never appears in any user-facing string. Consumers reach this
/// through [crashReporterProvider], which defaults to the no-op, so tests +
/// demo never touch the real SDK (same pattern as [AnalyticsProvider]).
abstract class CrashReporter {
  /// Wire the platform error handlers into the aggregator and open the
  /// transport. A no-op unless a real impl is selected AND a non-empty DSN
  /// was provided. [appRunner] runs the app; a real impl runs it inside the
  /// SDK's error-guarded zone so uncaught async errors are captured.
  Future<void> init(FutureOr<void> Function() appRunner);

  /// Manually record a caught error (e.g. from a swallowed catch that the
  /// operator still wants aggregated). No-op in the default impl. The
  /// scrubber applies here too.
  Future<void> recordError(Object error, StackTrace? stack);
}

/// Discards every call. The default — nothing leaves the device.
///
/// [init] simply runs [appRunner] with no error-handler wiring and no
/// transport, so a build with no DSN (dev / test / demo) behaves exactly as
/// it did before this feature existed. Returning real `Future`s matches the
/// interface without ever awaiting a network call.
class NoopCrashReporter implements CrashReporter {
  const NoopCrashReporter();

  @override
  Future<void> init(FutureOr<void> Function() appRunner) async {
    await appRunner();
  }

  @override
  Future<void> recordError(Object error, StackTrace? stack) async {}
}

/// Real impl — pipes crashes to a SELF-HOSTED aggregator behind [dsn].
///
/// Only ever constructed when a non-empty DSN is present AND we're not under
/// `flutter test`; [crashReporterBackend] enforces that, and [init] re-checks
/// as a belt-and-suspenders guard. The vendor SDK name stays dev-facing —
/// this class is never referenced from user-facing copy.
class SentryCrashReporter implements CrashReporter {
  const SentryCrashReporter(this.dsn);

  /// The self-hosted aggregator endpoint, from `--dart-define=SENTRY_DSN`.
  final String dsn;

  @override
  Future<void> init(FutureOr<void> Function() appRunner) async {
    // Belt-and-suspenders: never open a transport under test or with an
    // empty DSN, even if this impl is somehow selected directly.
    if (dsn.isEmpty || CrashReporterConfig.isUnderTest) {
      await appRunner();
      return;
    }
    await SentryFlutter.init(
      (SentryFlutterOptions options) {
        options.dsn = dsn;
        // NEVER let the SDK auto-attach PII (IP, user, request headers).
        // The scrubber is the second line; this is the first.
        options.sendDefaultPii = false;
        options.attachStacktrace = true;
        options.attachThreads = false;
        // Don't screenshot — a captured frame could show a loved one's care
        // data. (View-hierarchy capture also defaults off; we leave that
        // experimental option at its default rather than touch it.)
        options.attachScreenshot = false;
        // Breadcrumbs can accrete PHI (navigation args, HTTP bodies). We
        // keep zero — the scrubber also drops any that slip through.
        options.maxBreadcrumbs = 0;
        options.enableAutoNativeBreadcrumbs = false;
        options.release = BuildInfo.fullVersion;
        options.dist = BuildInfo.buildStamp;
        options.environment =
            BuildInfo.gitBranch.isEmpty ? 'release' : BuildInfo.gitBranch;
        // The mandatory PHI scrubber on every outbound event.
        options.beforeSend = (SentryEvent event, Hint hint) =>
            scrubEvent(event);
        // Breadcrumbs are scrubbed at the source too — drop every one.
        options.beforeBreadcrumb =
            (Breadcrumb? breadcrumb, Hint hint) => null;
      },
      appRunner: () async {
        await appRunner();
      },
    );
  }

  @override
  Future<void> recordError(Object error, StackTrace? stack) async {
    if (dsn.isEmpty || CrashReporterConfig.isUnderTest) return;
    await Sentry.captureException(error, stackTrace: stack);
  }
}

/// Compile-time + runtime configuration for crash aggregation.
///
/// Split out so the DSN read + the test/empty gating are unit-testable
/// without importing the SDK path.
class CrashReporterConfig {
  const CrashReporterConfig._();

  /// The self-hosted aggregator DSN. EMPTY (the default) = disabled. The
  /// release build defines set this via `--dart-define=SENTRY_DSN=<dsn>`;
  /// every other build leaves it empty and sends nothing.
  static const String dsn = String.fromEnvironment('SENTRY_DSN');

  /// True under `flutter test` — Flutter sets this env var for every test
  /// run. Used to hard-guarantee the SDK is never initialized in the suite.
  static bool get isUnderTest =>
      const bool.fromEnvironment('FLUTTER_TEST') ||
      Platform.environment.containsKey('FLUTTER_TEST');

  /// Whether automatic aggregation should be live: a non-empty DSN AND not
  /// under test. When false, [crashReporterBackend] hands back the no-op.
  static bool get enabled => dsn.isNotEmpty && !isUnderTest;
}

/// The PHI scrubber — the mandatory `beforeSend` transform.
///
/// Rebuilds [incoming] as a MINIMAL event carrying only the exception type +
/// stack + non-PII device/app context. Everything that could carry a loved
/// one's care data is dropped: the message body, breadcrumbs (+ their data
/// payloads), the request body/headers/cookies, the [SentryUser]'s
/// email/name/username/ip (replaced by an anonymous install id at most), the
/// deprecated `extra` bag, `culprit`, and `transaction` (route/screen names
/// can leak the loved one's name). Tags are dropped wholesale — we can't
/// prove a tag value is PII-free, and "when in doubt, drop the field."
///
/// Pure + synchronous so it's unit-testable without initializing the SDK.
/// Returns a new event; never mutates [incoming].
SentryEvent scrubEvent(SentryEvent incoming) {
  final Contexts src = incoming.contexts;
  // Keep ONLY os / app / runtimes — coarse platform + build facts. The
  // `device` context can carry a device name / identifiers, so drop it.
  final Contexts safeContexts = Contexts(
    operatingSystem: src.operatingSystem,
    app: src.app,
    runtimes: src.runtimes,
  );

  // Preserve the anonymous install id if one was set (id only), never the
  // email / name / username / ip. If the user carried anything else, it's
  // dropped by simply not copying it.
  SentryUser? safeUser;
  final SentryUser? u = incoming.user;
  if (u != null && u.id != null && u.id!.isNotEmpty) {
    safeUser = SentryUser(id: u.id);
  }

  return SentryEvent(
    // Identity + coarse build/platform facts — all non-PII.
    eventId: incoming.eventId,
    timestamp: incoming.timestamp,
    platform: incoming.platform,
    sdk: incoming.sdk,
    release: incoming.release,
    dist: incoming.dist,
    environment: incoming.environment,
    level: incoming.level,
    type: incoming.type,
    // The actual crash signal: exception type + stack frames + threads.
    // Stack frames are code locations, not care data.
    exceptions: incoming.exceptions,
    threads: incoming.threads,
    contexts: safeContexts,
    user: safeUser,
    // Everything below is deliberately NOT carried over (dropped):
    //   message, breadcrumbs, request, extra, tags, modules,
    //   culprit, transaction, fingerprint, debugMeta.
  );
}

/// Riverpod-wired backend selection.
///
/// Returns [SentryCrashReporter] ONLY when [CrashReporterConfig.enabled]
/// (non-empty DSN and not under test); otherwise the silent
/// [NoopCrashReporter]. So `flutter test` + demo + any DSN-less build always
/// resolve to the no-op and never initialize the SDK.
///
/// Named `crashReporterBackend` (not `crashReporter`) so the generated class
/// is `CrashReporterBackendProvider`, avoiding a clash with the [CrashReporter]
/// interface — same convention as [analyticsBackend]. Consumers read through
/// the [crashReporterProvider] alias below.
@Riverpod(keepAlive: true)
CrashReporter crashReporterBackend(Ref ref) => CrashReporterConfig.enabled
    ? const SentryCrashReporter(CrashReporterConfig.dsn)
    : const NoopCrashReporter();

/// Natural-language alias for the generated provider. Consumers should always
/// reach for this name — `crashReporterBackendProvider` exists only because of
/// the riverpod_generator class-naming collision documented on
/// [crashReporterBackend].
final CrashReporterBackendProvider crashReporterProvider =
    crashReporterBackendProvider;
