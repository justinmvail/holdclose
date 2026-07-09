import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/providers/crash_reporter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:sentry_flutter/sentry_flutter.dart';

/// Recording spy proving the riverpod override hook routes through — the
/// default is the silent no-op, so this never wires into production.
class _RecordingCrashReporter implements CrashReporter {
  final List<Object> recorded = <Object>[];
  int initCount = 0;

  @override
  Future<void> init(FutureOr<void> Function() appRunner) async {
    initCount++;
    await appRunner();
  }

  @override
  Future<void> recordError(Object error, StackTrace? stack) async {
    recorded.add(error);
  }
}

void main() {
  // ---- Default selection is the silent no-op (DSN empty under test) ------

  group('crashReporterProvider selection', () {
    test(
        'default container resolves to NoopCrashReporter '
        '(no DSN + under flutter test)', () {
      // The suite runs with FLUTTER_TEST set and no SENTRY_DSN define, so the
      // backend selector MUST hand back the no-op — the Sentry SDK is never
      // constructed, let alone initialized.
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      final CrashReporter impl = container.read(crashReporterProvider);
      expect(impl, isA<NoopCrashReporter>());
      expect(impl, isNot(isA<SentryCrashReporter>()));
    });

    test('config is disabled under test with an empty DSN', () {
      // Belt-and-suspenders on the two gates: an empty compile-time DSN and
      // the FLUTTER_TEST guard both point to "disabled".
      expect(CrashReporterConfig.dsn, isEmpty);
      expect(CrashReporterConfig.isUnderTest, isTrue);
      expect(CrashReporterConfig.enabled, isFalse);
    });

    test('override hook swaps in a custom impl end-to-end', () {
      final _RecordingCrashReporter spy = _RecordingCrashReporter();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          crashReporterProvider.overrideWithValue(spy),
        ],
      );
      addTearDown(container.dispose);

      final CrashReporter impl = container.read(crashReporterProvider);
      expect(identical(impl, spy), isTrue);
    });
  });

  // ---- NoopCrashReporter: never touches a transport ----------------------

  group('NoopCrashReporter', () {
    test('init runs the app runner and records nothing', () async {
      const NoopCrashReporter noop = NoopCrashReporter();
      bool ran = false;
      await noop.init(() async => ran = true);
      expect(ran, isTrue, reason: 'the app must still run without a reporter');
    });

    test('recordError swallows the call without throwing', () {
      const NoopCrashReporter noop = NoopCrashReporter();
      expect(
        () => noop.recordError(StateError('boom'), StackTrace.current),
        returnsNormally,
      );
    });

    test('still implements CrashReporter', () {
      const NoopCrashReporter noop = NoopCrashReporter();
      expect(noop, isA<CrashReporter>());
    });
  });

  // ---- SentryCrashReporter never opens a transport under test ------------

  group('SentryCrashReporter under flutter test', () {
    test('init just runs the app runner (no SDK init) even with a DSN',
        () async {
      // Even if the real impl is constructed directly with a DSN, its own
      // isUnderTest guard means init() must NOT call SentryFlutter.init — it
      // simply runs the app. If it tried to init, this test would hang/throw
      // against a bogus DSN + no native binding.
      const SentryCrashReporter reporter =
          SentryCrashReporter('https://public@example.invalid/1');
      bool ran = false;
      await reporter.init(() async => ran = true);
      expect(ran, isTrue);
    });

    test('recordError is a no-op under test even with a DSN', () {
      const SentryCrashReporter reporter =
          SentryCrashReporter('https://public@example.invalid/1');
      expect(
        () => reporter.recordError(StateError('boom'), StackTrace.current),
        returnsNormally,
      );
    });
  });

  // ---- The PHI scrubber (the mandatory beforeSend transform) -------------

  group('scrubEvent (PHI scrubbing)', () {
    test('drops the message body (chat/journal text can live here)', () {
      final SentryEvent phi = SentryEvent(
        message: SentryMessage(
          "Mom refused her Lisinopril and said she wants to go home",
        ),
        exceptions: <SentryException>[
          SentryException(type: 'StateError', value: 'redacted-by-sdk'),
        ],
      );

      final SentryEvent scrubbed = scrubEvent(phi);

      expect(scrubbed.message, isNull,
          reason: 'a free-text message could carry a loved one\'s care data');
      // The crash SIGNAL survives: the exception TYPE is retained.
      expect(scrubbed.exceptions, hasLength(1));
      expect(scrubbed.exceptions!.single.type, 'StateError');
      // ...but the exception VALUE string is passed through as-is here; the
      // scrubber keeps the exception object (type is the load-bearing part).
    });

    test('drops the request body/headers/cookies', () {
      final SentryEvent phi = SentryEvent(
        request: SentryRequest(
          url: 'https://api.example/v1/journal',
          data: '{"situation":"Dad fell in the bathroom at 3am"}',
          headers: <String, String>{'Authorization': 'Bearer secret'},
          cookies: 'session=abc123',
        ),
      );

      final SentryEvent scrubbed = scrubEvent(phi);
      expect(scrubbed.request, isNull);
    });

    test('drops user email / name / username / ip, keeps only an id', () {
      final SentryEvent phi = SentryEvent(
        user: SentryUser(
          id: 'anon-install-42',
          email: 'sarah@example.com',
          name: 'Sarah Henderson',
          username: 'sarah_h',
          ipAddress: '203.0.113.7',
        ),
      );

      final SentryEvent scrubbed = scrubEvent(phi);
      expect(scrubbed.user, isNotNull);
      expect(scrubbed.user!.id, 'anon-install-42');
      expect(scrubbed.user!.email, isNull);
      expect(scrubbed.user!.name, isNull);
      expect(scrubbed.user!.username, isNull);
      expect(scrubbed.user!.ipAddress, isNull);
    });

    test('drops a user carrying no id entirely (no PII leaks through)', () {
      final SentryEvent phi = SentryEvent(
        user: SentryUser(email: 'leak@example.com'),
      );
      final SentryEvent scrubbed = scrubEvent(phi);
      expect(scrubbed.user, isNull);
    });

    test('drops breadcrumbs and their data payloads', () {
      final SentryEvent phi = SentryEvent(
        breadcrumbs: <Breadcrumb>[
          Breadcrumb(
            message: 'navigated to /journal/entry',
            data: <String, dynamic>{
              'note': 'Grandpa combative during dinner',
            },
          ),
        ],
      );

      final SentryEvent scrubbed = scrubEvent(phi);
      expect(scrubbed.breadcrumbs, isNull);
    });

    test('drops the deprecated extra bag, tags, culprit, and transaction', () {
      final SentryEvent phi = SentryEvent(
        // ignore: deprecated_member_use
        extra: <String, dynamic>{'med_list': 'Aspirin, Atorvastatin'},
        tags: <String, String>{'loved_one': 'Mary Henderson'},
        culprit: 'JournalScreen (Mary Henderson)',
        transaction: '/journal/mary-henderson',
      );

      final SentryEvent scrubbed = scrubEvent(phi);
      // ignore: deprecated_member_use
      expect(scrubbed.extra, isNull);
      expect(scrubbed.tags, isNull);
      expect(scrubbed.culprit, isNull);
      expect(scrubbed.transaction, isNull);
    });

    test('keeps only os/app/runtimes context, drops the device context', () {
      final SentryEvent phi = SentryEvent(
        contexts: Contexts(
          operatingSystem: SentryOperatingSystem(name: 'iOS', version: '17.5'),
          app: SentryApp(name: 'Holdclose', version: '0.1.0'),
          // Device can carry a user-set device name → PHI-adjacent, must drop.
          device: SentryDevice(name: "Sarah's iPhone", model: 'iPhone15,2'),
        ),
      );

      final SentryEvent scrubbed = scrubEvent(phi);
      expect(scrubbed.contexts.operatingSystem?.name, 'iOS');
      expect(scrubbed.contexts.app?.name, 'Holdclose');
      expect(scrubbed.contexts.device, isNull,
          reason: 'device name/identifiers must not leave the device');
    });

    test('preserves the crash signal: exception + stack + build facts', () {
      final SentryEvent phi = SentryEvent(
        release: 'holdclose@0.1.0+28',
        dist: '28',
        environment: 'release',
        level: SentryLevel.fatal,
        message: SentryMessage('secret care note'),
        exceptions: <SentryException>[
          SentryException(
            type: 'RangeError',
            value: 'index out of range',
            stackTrace: SentryStackTrace(frames: <SentryStackFrame>[
              SentryStackFrame(function: 'buildDoseWindow', lineNo: 42),
            ]),
          ),
        ],
      );

      final SentryEvent scrubbed = scrubEvent(phi);
      // Non-PII build/platform facts survive.
      expect(scrubbed.release, 'holdclose@0.1.0+28');
      expect(scrubbed.dist, '28');
      expect(scrubbed.environment, 'release');
      expect(scrubbed.level, SentryLevel.fatal);
      // The crash itself survives — type + stack frames are code locations.
      expect(scrubbed.exceptions, hasLength(1));
      expect(scrubbed.exceptions!.single.type, 'RangeError');
      expect(
        scrubbed.exceptions!.single.stackTrace?.frames.single.function,
        'buildDoseWindow',
      );
      // But the PHI message is gone.
      expect(scrubbed.message, isNull);
    });
  });
}
