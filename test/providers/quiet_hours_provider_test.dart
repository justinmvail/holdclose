// `fake_async` is a transitive dep of flutter_test; importing it
// directly avoids a pubspec.yaml entry (no new top-level deps without
// BUILD_SPEC.md §1).
// ignore_for_file: depend_on_referenced_packages

import 'package:careblazers/models/settings.dart';
import 'package:careblazers/providers/quiet_hours_provider.dart';
import 'package:careblazers/providers/settings_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Spins a container wired the same way `main.dart` does at boot:
/// `InMemoryStorageProvider` behind the storage backend, an optional
/// pinned [DateTime] for the auto-switches, and an optional persisted
/// [AppSettings] so the hydrate microtask snaps to a known value rather
/// than the defaults.
ProviderContainer _build({
  DateTime? now,
  AppSettings? seeded,
}) {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  if (seeded != null) {
    storage.updateSettings(seeded);
  }
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(storage),
      if (now != null) quietHoursClockProvider.overrideWithValue(() => now),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isAfterDarkModeStart — pure threshold (BUILD_SPEC.md §11.4)', () {
    test('false before 6pm', () {
      expect(
        isAfterDarkModeStart(DateTime(2026, 5, 29, 17, 59)),
        isFalse,
        reason: '5:59pm is before the dark-mode switch hour',
      );
      expect(
        isAfterDarkModeStart(DateTime(2026, 5, 29, 12, 0)),
        isFalse,
      );
    });

    test('true at-or-past 6pm', () {
      expect(
        isAfterDarkModeStart(DateTime(2026, 5, 29, 18, 0)),
        isTrue,
        reason: '6:00pm is the first dark-mode hour',
      );
      expect(
        isAfterDarkModeStart(DateTime(2026, 5, 29, 23, 0)),
        isTrue,
      );
    });

    test('honours a custom startHour', () {
      final DateTime sevenPm = DateTime(2026, 5, 29, 19, 0);
      expect(isAfterDarkModeStart(sevenPm, startHour: 20), isFalse);
      expect(isAfterDarkModeStart(sevenPm, startHour: 19), isTrue);
    });
  });

  group('quietHoursActiveProvider — BUILD_SPEC.md §11.2', () {
    test('at 11pm local, quiet hours active', () async {
      final ProviderContainer container = _build(
        now: DateTime(2026, 5, 29, 23, 0),
      );
      // Drain the SettingsNotifier hydrate microtask so the compute
      // sees the persisted (default) settings rather than the in-flight
      // defaults sentinel.
      await Future<void>.delayed(Duration.zero);
      expect(container.read(quietHoursActiveProvider), isTrue);
    });

    test('at noon, quiet hours inactive', () async {
      final ProviderContainer container = _build(
        now: DateTime(2026, 5, 29, 12, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(quietHoursActiveProvider), isFalse);
    });

    test('quietHoursEnabled=false: stays inactive even at 11pm', () async {
      final ProviderContainer container = _build(
        now: DateTime(2026, 5, 29, 23, 0),
        seeded:
            AppSettings.defaults().copyWith(quietHoursEnabled: false),
      );
      // Read once to kick the watch chain (settingsProvider → its
      // hydrate microtask → quietHoursActiveProvider's listen
      // callback). The first read sees defaults (quietHoursEnabled
      // ON → at 11pm → active=true); after the hydrate lands, the
      // listener flips the state.
      container.read(quietHoursActiveProvider);
      // Drain two microtask hops: one for build-scheduled microtask,
      // one for the awaited getSettings() inside it.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      expect(container.read(quietHoursActiveProvider), isFalse);
    });

    test('flipping quietHoursEnabled off re-evaluates without a timer tick',
        () async {
      final ProviderContainer container = _build(
        now: DateTime(2026, 5, 29, 23, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(quietHoursActiveProvider), isTrue);

      await container
          .read(settingsProvider.notifier)
          .setQuietHoursEnabled(false);
      await container.pump();

      expect(container.read(quietHoursActiveProvider), isFalse,
          reason: 'Settings change should flow through the listener');
    });

    test('boundary contract: 7am is NOT quiet, 10pm IS quiet', () async {
      final ProviderContainer sevenAm = _build(
        now: DateTime(2026, 5, 30, 7, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sevenAm.read(quietHoursActiveProvider), isFalse);

      final ProviderContainer tenPm = _build(
        now: DateTime(2026, 5, 29, 22, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(tenPm.read(quietHoursActiveProvider), isTrue);
    });
  });

  group('nightThemeModeProvider — BUILD_SPEC.md §11.4', () {
    test('after 6pm flips to ThemeMode.dark', () async {
      final ProviderContainer container = _build(
        now: DateTime(2026, 5, 29, 19, 30),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(nightThemeModeProvider), ThemeMode.dark);
    });

    test('before 6pm stays on ThemeMode.light', () async {
      final ProviderContainer container = _build(
        now: DateTime(2026, 5, 29, 14, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(nightThemeModeProvider), ThemeMode.light);
    });

    test('darkModeAtNight=false: ThemeMode.light regardless of hour',
        () async {
      final ProviderContainer container = _build(
        now: DateTime(2026, 5, 29, 23, 0),
        seeded: AppSettings.defaults().copyWith(darkModeAtNight: false),
      );
      // Kick the watch chain so the hydrate microtask is scheduled,
      // then drain microtasks before reading the resolved value.
      container.read(nightThemeModeProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      expect(container.read(nightThemeModeProvider), ThemeMode.light,
          reason: 'User override should suppress the auto-flip');
    });

    test('flipping darkModeAtNight off re-evaluates without a timer tick',
        () async {
      final ProviderContainer container = _build(
        now: DateTime(2026, 5, 29, 20, 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(nightThemeModeProvider), ThemeMode.dark);

      await container
          .read(settingsProvider.notifier)
          .setDarkModeAtNight(false);
      await container.pump();

      expect(container.read(nightThemeModeProvider), ThemeMode.light);
    });
  });

  group('timer-driven recompute (BUILD_SPEC.md §11.4)', () {
    test('quietHoursActiveProvider re-polls the clock every minute', () {
      fakeAsync((FakeAsync async) {
        // Walk through a 10pm transition entirely off-screen — the
        // provider's only job is to re-read DateTime.now() (or the
        // injected clock) once per minute and refresh the state if
        // the boundary has moved.
        DateTime now = DateTime(2026, 5, 29, 21, 59);
        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        final ProviderContainer container = ProviderContainer(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            quietHoursClockProvider.overrideWithValue(() => now),
          ],
        );
        addTearDown(container.dispose);

        // Subscribe and let the hydrate microtask drain.
        container.listen<bool>(
          quietHoursActiveProvider,
          (_, __) {},
        );
        async.flushMicrotasks();
        expect(container.read(quietHoursActiveProvider), isFalse,
            reason: '9:59pm is outside quiet hours');

        // Advance two minutes — past the 10pm boundary — and the
        // timer-driven refresh should flip the state without any
        // outside read or settings mutation.
        now = DateTime(2026, 5, 29, 22, 1);
        async.elapse(const Duration(minutes: 2));
        expect(container.read(quietHoursActiveProvider), isTrue,
            reason: '10:01pm is inside quiet hours');
      });
    });

    test('nightThemeModeProvider re-polls the clock every minute', () {
      fakeAsync((FakeAsync async) {
        DateTime now = DateTime(2026, 5, 29, 17, 59);
        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        final ProviderContainer container = ProviderContainer(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            quietHoursClockProvider.overrideWithValue(() => now),
          ],
        );
        addTearDown(container.dispose);

        container.listen<ThemeMode>(
          nightThemeModeProvider,
          (_, __) {},
        );
        async.flushMicrotasks();
        expect(container.read(nightThemeModeProvider), ThemeMode.light);

        now = DateTime(2026, 5, 29, 18, 1);
        async.elapse(const Duration(minutes: 2));
        expect(container.read(nightThemeModeProvider), ThemeMode.dark,
            reason: '6:01pm should auto-flip without app interaction');
      });
    });

    test('timer is cancelled when the provider is disposed', () {
      fakeAsync((FakeAsync async) {
        DateTime now = DateTime(2026, 5, 29, 17, 59);
        final InMemoryStorageProvider storage = InMemoryStorageProvider();
        final ProviderContainer container = ProviderContainer(
          overrides: <Override>[
            storageBackendProvider.overrideWithValue(storage),
            quietHoursClockProvider.overrideWithValue(() => now),
          ],
        );

        container.listen<ThemeMode>(
          nightThemeModeProvider,
          (_, __) {},
        );
        async.flushMicrotasks();
        expect(container.read(nightThemeModeProvider), ThemeMode.light);

        container.dispose();
        // After dispose, advancing the clock past 6pm must not throw
        // — the periodic timer must have been cancelled by ref.onDispose,
        // otherwise the callback would call `state =` on a disposed
        // notifier and the FakeAsync zone would surface the exception.
        now = DateTime(2026, 5, 29, 19, 0);
        async.elapse(const Duration(minutes: 5));
      });
    });
  });
}
