import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/providers/auth_provider.dart';
import 'package:careblazers/providers/home_clock_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/screens/appointment/appointment_list_screen.dart'
    show appointmentListClockProvider;
import 'package:careblazers/screens/medication/dose_log_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI-only golden of the Home dashboard (Phase 14.7) in its empty
/// scaffold state — AppBar-less, the greeting + profile top row, and no
/// cards yet (those arrive in 14.8–14.12). Pumped through the real
/// router so the golden catches shell-level regressions (tab bar,
/// back-button suppression on the tab root).
///
/// The clock is pinned to a fixed morning hour and a signed-in fake
/// caregiver supplies the greeting name so the render is deterministic.
final DateTime _goldenNow = DateTime.utc(2026, 5, 30, 9);

void main() {
  group('HomeScreen golden', () {
    goldenTest(
      'renders the empty dashboard scaffold',
      fileName: 'home_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'default (Home tab root)',
            // TabScaffold (Phase 12.8) watches settingsProvider, which
            // hydrates off storageProvider — the in-memory override keeps
            // the golden off the on-device sqlite file. The auth fake
            // supplies the greeting name; the clock pins the time-of-day.
            child: ProviderScope(
              overrides: <Override>[
                storageBackendProvider.overrideWithValue(
                  InMemoryStorageProvider(),
                ),
                authProvider.overrideWithValue(
                  FakeAuthProvider()..signInWithGoogle(),
                ),
                homeClockProvider.overrideWithValue(() => _goldenNow),
                // The Medications Today card (Phase 14.9) reads the
                // dose-log providers; an empty in-memory repo keeps the
                // golden off on-device sqlite and renders the card's
                // "No medications today." empty state.
                medicationRepositoryBackendProvider.overrideWithValue(
                  MedicationRepository(
                    CareblazersDatabase(NativeDatabase.memory()),
                    clock: () => _goldenNow,
                  ),
                ),
                doseLogClockProvider.overrideWithValue(() => _goldenNow),
                // The Next Appointment card (Phase 14.10) reads the
                // appointment repository; an empty in-memory repo keeps
                // the golden deterministic and renders the card's "No
                // upcoming appointments." empty state.
                appointmentRepositoryBackendProvider.overrideWithValue(
                  AppointmentRepository(
                    CareblazersDatabase(NativeDatabase.memory()),
                    clock: () => _goldenNow,
                  ),
                ),
                appointmentListClockProvider.overrideWithValue(
                  () => _goldenNow,
                ),
              ],
              child: SizedBox(
                width: 390,
                height: 780,
                // No `theme:` — google_fonts can't fetch under
                // `flutter test` (see test/golden/flutter_test_config.dart).
                // HomeScreen pulls brand colors directly off
                // careblazersColors, so the scaffold stays brand-accurate
                // without dragging the google_fonts TextTheme through.
                child: MaterialApp.router(
                  routerConfig: buildRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.surfaceWarm,
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
