import 'package:holdclose/models/forum.dart';
import 'package:holdclose/screens/community/admin_reports_screen.dart';
import 'package:holdclose/services/forum_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  final List<({String reportId, ForumReportAction action})> reviewCalls =
      <({String reportId, ForumReportAction action})>[];
  ForumApiException? nextReviewError;

  @override
  Future<ForumProfile> getMyProfile() async => _profile(role);

  @override
  Future<List<ForumReport>> listReports({String? status}) async =>
      reports
          .where((ForumReport r) => status == null || r.status == status)
          .toList();

  @override
  Future<ForumReportReviewResponse> reviewReport({
    required String reportId,
    required ForumReportAction action,
  }) async {
    reviewCalls.add((reportId: reportId, action: action));
    if (nextReviewError != null) {
      final ForumApiException err = nextReviewError!;
      nextReviewError = null;
      throw err;
    }
    final ForumReport target =
        reports.firstWhere((ForumReport r) => r.id == reportId);
    final ForumReport resolved = ForumReport(
      id: target.id,
      targetKind: target.targetKind,
      targetId: target.targetId,
      reporterId: target.reporterId,
      reason: target.reason,
      status: 'resolved',
      createdAt: target.createdAt,
      resolvedAt: _fixedNow,
    );
    reports.removeWhere((ForumReport r) => r.id == reportId);
    return ForumReportReviewResponse(
      report: resolved,
      action: action.queryValue,
      bannedUserId:
          action == ForumReportAction.banUser ? 'banned-${target.id}' : null,
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeForumApiClient client,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        forumApiClientProvider.overrideWithValue(client),
        // Pin "now" so the relative-time row ("Nd ago") is deterministic
        // rather than reading the wall clock.
        adminReportsClockProvider.overrideWithValue(() => _fixedNow),
      ],
      child: const MaterialApp(home: AdminReportsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('AdminReportsScreen — BUILD_SPEC.md §13 / Phase 13.12', () {
    testWidgets(
        'non-admin sees the forbidden stub instead of any pending row',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(
        role: 'user',
        initialReports: <ForumReport>[_report('r1')],
      );
      await _pump(tester, client: client);

      expect(find.byKey(AdminReportsScreen.forbiddenKey), findsOneWidget);
      expect(find.byKey(AdminReportsScreen.listKey), findsNothing);
      expect(find.text('Moderation is admin-only.'), findsOneWidget);
    });

    testWidgets('admin sees the empty state when queue is clear',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(role: 'admin');
      await _pump(tester, client: client);

      expect(find.byKey(AdminReportsScreen.emptyKey), findsOneWidget);
      expect(find.byKey(AdminReportsScreen.forbiddenKey), findsNothing);
      expect(find.text('Queue is empty.'), findsOneWidget);
    });

    testWidgets('admin sees one card per pending report',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(
        role: 'admin',
        initialReports: <ForumReport>[
          _report('r1', reason: 'spam'),
          _report('r2', reason: 'medical advice', targetKind: 'post'),
        ],
      );
      await _pump(tester, client: client);

      expect(find.byKey(AdminReportsScreen.listKey), findsOneWidget);
      expect(find.byKey(AdminReportsScreen.reportRowKey('r1')), findsOneWidget);
      expect(find.byKey(AdminReportsScreen.reportRowKey('r2')), findsOneWidget);
      expect(find.textContaining('Reason: spam'), findsOneWidget);
    });

    testWidgets('Dismiss action calls reviewReport with no_action',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(
        role: 'admin',
        initialReports: <ForumReport>[_report('r1')],
      );
      await _pump(tester, client: client);

      await tester.tap(find.byKey(AdminReportsScreen.actionNoActionKey('r1')));
      await tester.pumpAndSettle();

      expect(client.reviewCalls, hasLength(1));
      expect(client.reviewCalls.first.action, ForumReportAction.noAction);
      // Row removed from the list.
      expect(find.byKey(AdminReportsScreen.reportRowKey('r1')), findsNothing);
    });

    testWidgets('Hide action calls reviewReport with hide_target',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(
        role: 'admin',
        initialReports: <ForumReport>[_report('r1')],
      );
      await _pump(tester, client: client);

      await tester.tap(find.byKey(AdminReportsScreen.actionHideKey('r1')));
      await tester.pumpAndSettle();

      expect(client.reviewCalls, hasLength(1));
      expect(client.reviewCalls.first.action, ForumReportAction.hideTarget);
    });

    testWidgets('Ban action calls reviewReport with ban_user',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(
        role: 'admin',
        initialReports: <ForumReport>[_report('r1')],
      );
      await _pump(tester, client: client);

      await tester.tap(find.byKey(AdminReportsScreen.actionBanKey('r1')));
      await tester.pumpAndSettle();

      expect(client.reviewCalls, hasLength(1));
      expect(client.reviewCalls.first.action, ForumReportAction.banUser);
    });

    testWidgets('admin error path surfaces the error message',
        (WidgetTester tester) async {
      final _FakeForumApiClient client = _FakeForumApiClient(
        role: 'admin',
        initialReports: <ForumReport>[_report('r1')],
      )..nextReviewError =
          ForumApiException(statusCode: 500, error: 'server_blew_up');
      await _pump(tester, client: client);

      await tester.tap(find.byKey(AdminReportsScreen.actionHideKey('r1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('server_blew_up'), findsOneWidget);
      // Row stays — the action failed.
      expect(find.byKey(AdminReportsScreen.reportRowKey('r1')), findsOneWidget);
    });
  });
}
