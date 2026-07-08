import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/forum.dart';
import '../../providers/my_forum_profile_provider.dart';
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'admin_reports_screen.g.dart';

/// Injectable "now" for the moderation queue's relative timestamps
/// ("12d ago"). Defaults to the wall clock; tests + goldens override it so
/// the rendered string is deterministic. Without this seam the golden
/// drifts a day every real day — it bakes "Nd ago" against `DateTime.now()`,
/// so a baseline captured on day N fails on day N+1.
@Riverpod(keepAlive: true)
DateTime Function() adminReportsClock(Ref ref) => DateTime.now;

/// Pending moderation queue + per-row action set (BUILD_SPEC.md §13 /
/// Phase 13.12).
///
/// Loaded from `GET /reports?status=pending`. The list refreshes after
/// every successful action so a row the admin just resolved doesn't
/// linger as a fake-pending entry. `keepAlive: false` — admin returns
/// here intermittently; remounting is the cheapest invalidation.
@Riverpod(keepAlive: false)
class PendingReports extends _$PendingReports {
  @override
  Future<List<ForumReport>> build() async {
    final ForumApiClient client = ref.watch(forumApiClientProvider);
    return client.listReports(status: 'pending');
  }

  Future<void> refresh() async {
    state = const AsyncValue<List<ForumReport>>.loading();
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      state = AsyncValue<List<ForumReport>>.data(
        await client.listReports(status: 'pending'),
      );
    } catch (e, st) {
      state = AsyncValue<List<ForumReport>>.error(e, st);
    }
  }

  /// Apply [action] to [reportId] and drop the row from the in-memory
  /// list on success. Returns the Worker's review-response on success
  /// so the screen can SnackBar the action; null on failure.
  Future<ForumReportReviewResponse?> review({
    required String reportId,
    required ForumReportAction action,
  }) async {
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      final ForumReportReviewResponse resp = await client.reviewReport(
        reportId: reportId,
        action: action,
      );
      final List<ForumReport>? current = state.value;
      if (current != null) {
        state = AsyncValue<List<ForumReport>>.data(
          current.where((ForumReport r) => r.id != reportId).toList(
                growable: false,
              ),
        );
      }
      return resp;
    } on ForumApiException {
      // Surface the failure to the screen via a rethrow-style; the
      // screen catches and SnackBars.
      rethrow;
    }
  }
}

/// Admin moderation queue at `/community/admin/reports` (BUILD_SPEC.md
/// §13 / Phase 13.12).
///
/// Gated by [isForumAdminProvider]: non-admin caregivers who deep-link
/// here land on the same "not authorized" stub that the route guard
/// would have rendered. Admin tab visibility (the AppBar action on the
/// community feed) is gated separately so the surface stays hidden
/// from non-admins entirely.
///
/// Per-row actions mirror the Worker's `ForumReportAction` enum:
///   * No action — dismiss the report, leave the target alone.
///   * Hide content — drop the post / comment from public render.
///   * Ban user — hide + block the author from further posting.
class AdminReportsScreen extends ConsumerWidget {
  const AdminReportsScreen({super.key});

  static const Key listKey = Key('admin-reports-list');
  static const Key loadingKey = Key('admin-reports-loading');
  static const Key emptyKey = Key('admin-reports-empty');
  static const Key errorKey = Key('admin-reports-error');
  static const Key forbiddenKey = Key('admin-reports-forbidden');

  static Key reportRowKey(String reportId) =>
      Key('admin-reports-row-$reportId');
  static Key actionNoActionKey(String reportId) =>
      Key('admin-reports-action-no-action-$reportId');
  static Key actionHideKey(String reportId) =>
      Key('admin-reports-action-hide-$reportId');
  static Key actionBanKey(String reportId) =>
      Key('admin-reports-action-ban-$reportId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isAdmin = ref.watch(isForumAdminProvider);
    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Community', route: '/community'),
                  PathHeaderCrumb(label: 'Moderation queue'),
                ],
                title: 'Moderation queue',
                backLabel: 'Back to Community',
                leadingIcon: Icons.shield_outlined,
              ),
            ),
            Expanded(
              child:
                  isAdmin ? const _AdminReportsBody() : const _ForbiddenStub(),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminReportsBody extends ConsumerWidget {
  const _AdminReportsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ForumReport>> reports =
        ref.watch(pendingReportsProvider);
    return reports.when(
      loading: () => const Center(
        key: AdminReportsScreen.loadingKey,
        child: CircularProgressIndicator(),
      ),
      error: (Object err, _) => _ErrorState(
        message: err is ForumApiException
            ? 'Couldn’t load reports — ${err.error}'
            : "Couldn't load reports. Pull to refresh.",
        onRetry: () => ref.read(pendingReportsProvider.notifier).refresh(),
      ),
      data: (List<ForumReport> rows) {
        if (rows.isEmpty) {
          return const _EmptyState();
        }
        return RefreshIndicator(
          onRefresh: () =>
              ref.read(pendingReportsProvider.notifier).refresh(),
          child: ListView.separated(
            key: AdminReportsScreen.listKey,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (BuildContext context, int i) =>
                _ReportCard(report: rows[i]),
          ),
        );
      },
    );
  }
}

class _ReportCard extends ConsumerWidget {
  const _ReportCard({required this.report});

  final ForumReport report;

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    ForumReportAction action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ForumReportReviewResponse? resp = await ref
          .read(pendingReportsProvider.notifier)
          .review(reportId: report.id, action: action);
      if (resp == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text(_actionSnack(action))),
      );
    } on ForumApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't apply: ${e.error}")),
      );
    }
  }

  static String _actionSnack(ForumReportAction action) {
    switch (action) {
      case ForumReportAction.noAction:
        return 'Dismissed.';
      case ForumReportAction.hideTarget:
        return 'Content hidden.';
      case ForumReportAction.banUser:
        return 'User banned + content hidden.';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: AdminReportsScreen.reportRowKey(report.id),
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.hc.surfaceWarm,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _TargetChip(targetKind: report.targetKind),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'id ${_shorten(report.targetId)}',
                  style: textTheme.bodyMedium?.copyWith(
                    color: context.hc.text.withValues(alpha: 0.55),
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Reason: ${report.reason}',
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Reported by ${_shorten(report.reporterId)} '
            '· ${_relativeTime(report.createdAt, ref.watch(adminReportsClockProvider)())}',
            style: textTheme.bodyMedium?.copyWith(
              color: context.hc.text.withValues(alpha: 0.55),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  key: AdminReportsScreen.actionNoActionKey(report.id),
                  onPressed: () =>
                      _apply(context, ref, ForumReportAction.noAction),
                  child: const Text('Dismiss'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  key: AdminReportsScreen.actionHideKey(report.id),
                  onPressed: () =>
                      _apply(context, ref, ForumReportAction.hideTarget),
                  child: const Text('Hide'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  key: AdminReportsScreen.actionBanKey(report.id),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.hc.error,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () =>
                      _apply(context, ref, ForumReportAction.banUser),
                  child: const Text('Ban'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _shorten(String id) =>
      id.length <= 8 ? id : '${id.substring(0, 8)}…';

  static String _relativeTime(DateTime ts, DateTime now) {
    final Duration delta = now.toUtc().difference(ts.toUtc());
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    return '${delta.inDays}d ago';
  }
}

class _TargetChip extends StatelessWidget {
  const _TargetChip({required this.targetKind});

  final String targetKind;

  @override
  Widget build(BuildContext context) {
    final bool isPost = targetKind == 'post';
    return Container(
      decoration: BoxDecoration(
        color: isPost
            ? context.hc.primary
            : context.hc.accentDeep,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        targetKind.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Center(
      key: AdminReportsScreen.emptyKey,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.verified_outlined,
                size: 56, color: context.hc.success),
            const SizedBox(height: 12),
            Text(
              'Queue is empty.',
              style: textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'No pending reports right now. Nice.',
              style: textTheme.bodyMedium?.copyWith(
                color: context.hc.text.withValues(alpha: 0.65),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Center(
      key: AdminReportsScreen.errorKey,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline,
                size: 56, color: context.hc.error),
            const SizedBox(height: 12),
            Text(message,
                style: textTheme.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForbiddenStub extends StatelessWidget {
  const _ForbiddenStub();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Center(
      key: AdminReportsScreen.forbiddenKey,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.lock_outline,
                size: 56, color: context.hc.text.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              'Moderation is admin-only.',
              style: textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              "This screen is hidden for everyone except the board's "
              'moderator.',
              style: textTheme.bodyMedium?.copyWith(
                color: context.hc.text.withValues(alpha: 0.65),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
