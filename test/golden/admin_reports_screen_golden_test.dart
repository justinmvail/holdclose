import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/forum.dart';
import 'package:careblazers/screens/community/admin_reports_screen.dart';
import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

ForumReport _report(
  String id, {
  String targetKind = 'comment',
  String reason = 'medical advice',
}) =>
    ForumReport(
      id: id,
      targetKind: targetKind,
      targetId: 'target-$id',
      reporterId: 'reporter-$id',
      reason: reason,
      status: 'pending',
      createdAt: _fixedNow.subtract(const Duration(hours: 2)),
    );

ForumProfile _profile(String role) => ForumProfile(
      id: 'me',
      careblazersUserId: 'cb-1',
      displayName: 'Me',
      joinedAt: _fixedNow.subtract(const Duration(days: 30)),
      role: role,
    );

/// Deterministic [ForumApiClient] — mirrors the widget test's fake (role
/// gate + seeded report list) so the golden renders the moderation queue
/// without a deployed Worker.
class _FakeForumApiClient extends ForumApiClient {
  _FakeForumApiClient({
    required this.role,
    List<ForumReport>? initialReports,
  })  : reports = List<ForumReport>.of(initialReports ?? <ForumReport>[]),
        super(
          tokenLoader: _stubTokenLoader,
          baseUrl: 'https://example.test',
        );

  static Future<String> _stubTokenLoader() async => 'fake-jwt';

  final String role;
  final List<ForumReport> reports;

  @override
  Future<ForumProfile> getMyProfile() async => _profile(role);

  @override
  Future<List<ForumReport>> listReports({String? status}) async => reports
      .where((ForumReport r) => status == null || r.status == status)
      .toList();
}

Widget _host(_FakeForumApiClient client) {
  final GoRouter router = GoRouter(
    initialLocation: '/community/admin/reports',
    routes: <RouteBase>[
      GoRoute(
        path: '/community/admin/reports',
        builder: (BuildContext context, GoRouterState state) =>
            const AdminReportsScreen(),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      forumApiClientProvider.overrideWithValue(client),
      // Pin the moderation queue's "Nd ago" clock so the golden is
      // deterministic — with a fixed `now`, a report stamped `_fixedNow -
      // 2h` always renders "2h ago" instead of drifting a day every real
      // day against the wall clock.
      adminReportsClockProvider.overrideWithValue(() => _fixedNow),
    ],
    child: SizedBox(
      width: 420,
      height: 900,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('AdminReportsScreen golden', () {
    goldenTest(
      'populated moderation queue — two pending reports',
      fileName: 'admin_reports_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'admin · pending queue',
            child: _host(
              _FakeForumApiClient(
                role: 'admin',
                initialReports: <ForumReport>[
                  _report('r1', reason: 'spam', targetKind: 'post'),
                  _report('r2', reason: 'medical advice'),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'empty queue — admin, nothing pending',
      fileName: 'admin_reports_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'admin · empty queue',
            child: _host(_FakeForumApiClient(role: 'admin')),
          ),
        ],
      ),
    );

    goldenTest(
      'forbidden — non-admin sees the admin-only stub',
      fileName: 'admin_reports_screen_forbidden',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'non-admin · forbidden stub',
            child: _host(
              _FakeForumApiClient(
                role: 'user',
                initialReports: <ForumReport>[_report('r1')],
              ),
            ),
          ),
        ],
      ),
    );
  });
}
