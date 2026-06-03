import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/care_event.dart';
import 'package:careblazers/providers/home_clock_provider.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/recent_activity_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// 9 AM Mon Jun 1 2026 — the relative-time stamps below are computed
/// against this fixed clock so the golden render stays deterministic.
DateTime _fixedNow() => DateTime(2026, 6, 1, 9, 0);

/// One row per kind so the golden captures every origin-dot hue
/// (plum=journal, teal=dose, coral=appointment) and the relative stamps.
/// Events are pre-projected with their activity-feed-style `subtitle`,
/// matching the shape [patientTimelineEventsProvider] hands the card.
final List<CareEvent> _populated = <CareEvent>[
  CareEvent(
    id: 'journal-1',
    kind: CareEventKind.journalEntry,
    title: 'Sundowning',
    subtitle: 'Sundowning',
    start: _fixedNow().subtract(const Duration(minutes: 20)),
    patientId: 'demo-patient-mary',
    externalRef: '1',
  ),
  CareEvent(
    id: 'dose-log-d1',
    kind: CareEventKind.doseLogged,
    title: 'Donepezil',
    subtitle: 'Gave Donepezil 10 mg',
    start: _fixedNow().subtract(const Duration(hours: 2)),
    patientId: 'demo-patient-mary',
    externalRef: 'd1',
  ),
  CareEvent(
    id: 'appt-7',
    kind: CareEventKind.appointment,
    title: 'Dr. Ortega',
    subtitle: 'Appointment with Dr. Ortega',
    start: _fixedNow().subtract(const Duration(days: 1)),
    patientId: 'demo-patient-mary',
    externalRef: '7',
  ),
];

GoRouter _goldenRouter() => GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (BuildContext context, GoRouterState state) =>
              const Scaffold(
            backgroundColor: Color(0xFFFFFFFF),
            body: Padding(
              padding: EdgeInsets.all(16),
              child: RecentActivityCard(),
            ),
          ),
        ),
      ],
    );

/// Hosts the card at a phone width with the feed pre-resolved to [items].
/// No `theme:` is passed — per `flutter_test_config.dart` goldens avoid
/// dragging google_fonts through the framework; the card pulls its brand
/// colors directly off `careblazersColors`.
Widget _host(List<CareEvent> events, double height) => ProviderScope(
      overrides: <Override>[
        homeClockProvider.overrideWithValue(_fixedNow),
        recentActivityProvider.overrideWith((ref) async => events),
      ],
      child: SizedBox(
        width: 390,
        height: height,
        child: MaterialApp.router(
          routerConfig: _goldenRouter(),
          builder: (BuildContext context, Widget? child) => ColoredBox(
            color: careblazersColors.background,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );

void main() {
  group('RecentActivityCard golden', () {
    goldenTest(
      'empty — no recent activity',
      fileName: 'recent_activity_card_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.11)',
            child: _host(const <CareEvent>[], 200),
          ),
        ],
      ),
    );

    goldenTest(
      'populated — one row per source with origin dots',
      fileName: 'recent_activity_card_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.11)',
            child: _host(_populated, 360),
          ),
        ],
      ),
    );
  });
}
