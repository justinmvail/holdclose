import 'package:alchemist/alchemist.dart';
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

/// One row per source so the golden captures every origin-dot hue
/// (plum=journal, teal=dose, coral=appointment) and the relative stamps.
final List<RecentActivityItem> _populated = <RecentActivityItem>[
  RecentActivityItem(
    id: 'journal-1',
    origin: RecentActivityOrigin.journal,
    summary: 'Sundowning',
    createdAt: _fixedNow().subtract(const Duration(minutes: 20)),
    route: '/journal/1',
  ),
  RecentActivityItem(
    id: 'dose-1',
    origin: RecentActivityOrigin.dose,
    summary: 'Gave Donepezil 10 mg',
    createdAt: _fixedNow().subtract(const Duration(hours: 2)),
    route: '/medications/today',
  ),
  RecentActivityItem(
    id: 'appointment-1',
    origin: RecentActivityOrigin.appointment,
    summary: 'Appointment with Dr. Ortega',
    createdAt: _fixedNow().subtract(const Duration(days: 1)),
    route: '/appointments/7',
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
Widget _host(List<RecentActivityItem> items, double height) => ProviderScope(
      overrides: <Override>[
        homeClockProvider.overrideWithValue(_fixedNow),
        recentActivityProvider.overrideWith((ref) async => items),
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
            child: _host(const <RecentActivityItem>[], 200),
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
