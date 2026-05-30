import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/forum.dart';
import '../../providers/post_detail_provider.dart';
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/community/comment_thread.dart';
import 'community_feed_screen.dart' show displayNameForAuthor, relativeTime;

part 'post_detail_screen.g.dart';

/// Wall clock the post-detail screen uses for relative timestamps
/// ("5m ago"). Overridable so golden + widget tests pin a fixed
/// reference time and rendered strings stay deterministic. Mirrors the
/// `communityFeedClockProvider` shape so test fixtures can share a
/// single fixed-now constant.
@Riverpod(keepAlive: true)
DateTime Function() postDetailClock(Ref ref) => DateTime.now;

/// Reasons surfaced in the long-press "Report this comment" menu
/// (BUILD_SPEC.md §13 / Phase 13.8 + 13.11). Wire values match the
/// `reason` strings the Worker's `POST /reports` route accepts.
const List<({String label, String reason})> _reportReasons =
    <({String label, String reason})>[
  (label: 'Spam', reason: 'spam'),
  (label: 'Harassment or harm', reason: 'harassment'),
  (label: 'Medical advice', reason: 'medical_advice'),
  (label: 'Off-topic', reason: 'off_topic'),
];

/// Post detail screen pushed from the community feed (BUILD_SPEC.md
/// §13 / Phase 13.11).
///
/// Renders:
///   * AppBar with a back arrow (auto-injected by go_router).
///   * Post header: title, author display name, relative time, full
///     body text, the post-level vote / comment counts, plus an
///     inline root-level reply composer.
///   * Scrollable nested-comments tree below, indented 24px per depth
///     level via [CommentThread]. Each comment has vote arrows
///     (salmon up / navy down), a reply button (hidden at max depth),
///     and a long-press report menu.
///
/// The screen drives the network through [PostDetail]:
///   * `initState` calls [PostDetail.load].
///   * Pull-to-refresh calls [PostDetail.refresh].
///   * Vote / reply / report tap-throughs proxy to the matching
///     notifier verb.
class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({
    super.key,
    required this.postId,
    this.initialPost,
  });

  /// Post id pulled from `/community/:postId`.
  final String postId;

  /// Optional pre-loaded post handed off by the feed tile so the
  /// header renders immediately instead of blanking during the fetch.
  final ForumPost? initialPost;

  static const Key bodyKey = Key('post-detail-body');
  static const Key loadingKey = Key('post-detail-loading');
  static const Key errorKey = Key('post-detail-error');
  static const Key emptyCommentsKey = Key('post-detail-empty-comments');
  static const Key commentsKey = Key('post-detail-comments');
  static const Key rootReplyButtonKey = Key('post-detail-root-reply');
  static const Key postUpvoteKey = Key('post-detail-post-upvote');
  static const Key postDownvoteKey = Key('post-detail-post-downvote');
  static const Key postReportKey = Key('post-detail-post-report');

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  /// Comment id whose inline reply composer is currently open. Null
  /// means no reply input is showing; the empty string means the
  /// post-level (root) composer is open.
  String? _activeReplyParentId;

  @override
  void initState() {
    super.initState();
    // Defer the load until after the first frame so providers settle
    // their initial state before we trigger the network fetch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(postDetailProvider.notifier).load(
            widget.postId,
            initialPost: widget.initialPost,
          );
    });
  }

  void _openReplyTo(String? parentCommentId) {
    setState(() {
      _activeReplyParentId = parentCommentId ?? '';
    });
  }

  void _cancelReply() {
    setState(() => _activeReplyParentId = null);
  }

  Future<void> _submitReply(String? parentCommentId, String body) async {
    final ForumCreateCommentResponse? resp =
        await ref.read(postDetailProvider.notifier).reply(
              parentCommentId: parentCommentId,
              body: body,
            );
    if (!mounted) return;
    if (resp != null) {
      setState(() => _activeReplyParentId = null);
      if (resp.crisisResources != null) {
        _showCrisisBanner(resp.crisisResources!);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Reply couldn't post. Try again."),
        ),
      );
    }
  }

  void _showCrisisBanner(ForumCrisisResources resources) {
    final String hotlines = resources.hotlines
        .map((ForumCrisisHotline h) => '${h.label}: ${h.number}')
        .join(' · ');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: careblazersColors.accentDeep,
        duration: const Duration(seconds: 8),
        content: Text(
          'You are not alone. $hotlines',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  Future<void> _showReportSheet({
    required ForumVoteTarget kind,
    required String targetId,
  }) async {
    final String? reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: careblazersColors.background,
      builder: (BuildContext sheetContext) {
        final TextTheme textTheme = Theme.of(sheetContext).textTheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  kind == ForumVoteTarget.post
                      ? 'Report this post'
                      : 'Report this comment',
                  style: textTheme.titleLarge?.copyWith(
                    color: careblazersColors.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "We'll take a look. Reports are private.",
                  style: textTheme.bodyMedium?.copyWith(
                    color: careblazersColors.primarySoft,
                  ),
                ),
                const SizedBox(height: 8),
                for (final ({String label, String reason}) opt in _reportReasons)
                  ListTile(
                    key: Key('report-reason-${opt.reason}'),
                    title: Text(
                      opt.label,
                      style: textTheme.bodyLarge?.copyWith(
                        color: careblazersColors.primary,
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(opt.reason),
                  ),
                TextButton(
                  key: const Key('report-cancel'),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: careblazersColors.primarySoft,
                  ),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (reason == null || !mounted) return;
    final bool ok = await ref.read(postDetailProvider.notifier).report(
          targetKind: kind,
          targetId: targetId,
          reason: reason,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? "Thanks. We'll take a look."
              : "Couldn't send the report. Try again.",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PostDetailState detail = ref.watch(postDetailProvider);
    final DateTime now = ref.watch(postDetailClockProvider)();

    final CommentThreadHandlers handlers = CommentThreadHandlers(
      onVote: (ForumComment c, int value) {
        ref.read(postDetailProvider.notifier).vote(
              targetKind: ForumVoteTarget.comment,
              targetId: c.id,
              value: value,
            );
      },
      onReplyTap: (ForumComment c) => _openReplyTo(c.id),
      onReport: (ForumComment c) async {
        await _showReportSheet(
          kind: ForumVoteTarget.comment,
          targetId: c.id,
        );
      },
      onSubmitReply: (ForumComment? parent, String body) async {
        await _submitReply(parent?.id, body);
      },
      onCancelReply: (ForumComment? _) => _cancelReply(),
      replyValueFor: (ForumComment c) {
        final String key =
            PostDetailState.voteKey(ForumVoteTarget.comment, c.id);
        return detail.pendingVotes[key] ?? 0;
      },
    );

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Post'),
      ),
      body: SafeArea(
        child: _Body(
          detail: detail,
          now: now,
          activeReplyParentId: _activeReplyParentId,
          handlers: handlers,
          onRefresh: () =>
              ref.read(postDetailProvider.notifier).refresh(),
          onPostUpvote: () => _voteOnPost(detail, 1),
          onPostDownvote: () => _voteOnPost(detail, -1),
          onPostReport: detail.post == null
              ? null
              : () => _showReportSheet(
                    kind: ForumVoteTarget.post,
                    targetId: detail.post!.id,
                  ),
          onOpenRootReply: () => _openReplyTo(null),
          onSubmitRootReply: (String body) => _submitReply(null, body),
          onCancelRootReply: _cancelReply,
        ),
      ),
    );
  }

  void _voteOnPost(PostDetailState detail, int direction) {
    final ForumPost? post = detail.post;
    if (post == null) return;
    final String key =
        PostDetailState.voteKey(ForumVoteTarget.post, post.id);
    final int current = detail.pendingVotes[key] ?? 0;
    final int next = current == direction ? 0 : direction;
    ref.read(postDetailProvider.notifier).vote(
          targetKind: ForumVoteTarget.post,
          targetId: post.id,
          value: next,
        );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.detail,
    required this.now,
    required this.activeReplyParentId,
    required this.handlers,
    required this.onRefresh,
    required this.onPostUpvote,
    required this.onPostDownvote,
    required this.onPostReport,
    required this.onOpenRootReply,
    required this.onSubmitRootReply,
    required this.onCancelRootReply,
  });

  final PostDetailState detail;
  final DateTime now;
  final String? activeReplyParentId;
  final CommentThreadHandlers handlers;
  final Future<void> Function() onRefresh;
  final VoidCallback onPostUpvote;
  final VoidCallback onPostDownvote;
  final VoidCallback? onPostReport;
  final VoidCallback onOpenRootReply;
  final Future<void> Function(String body) onSubmitRootReply;
  final VoidCallback onCancelRootReply;

  @override
  Widget build(BuildContext context) {
    if (detail.isLoading && detail.post == null) {
      return Center(
        key: PostDetailScreen.loadingKey,
        child: SizedBox(
          height: 32,
          width: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: careblazersColors.primarySoft,
          ),
        ),
      );
    }
    final ForumPost? post = detail.post;
    if (post == null) {
      return _ErrorView(
        message: detail.error?.toString() ?? 'unknown_error',
        onRetry: onRefresh,
      );
    }
    final List<CommentTreeNode> tree = buildCommentTree(detail.comments);
    final bool rootComposerOpen = activeReplyParentId == '';

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: careblazersColors.cta,
      child: ListView(
        key: PostDetailScreen.bodyKey,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          _PostHeader(
            post: post,
            now: now,
            pendingVote: detail.pendingVotes[PostDetailState.voteKey(
                  ForumVoteTarget.post,
                  post.id,
                )] ??
                0,
            onUpvote: onPostUpvote,
            onDownvote: onPostDownvote,
            onReply: rootComposerOpen ? null : onOpenRootReply,
            onReport: onPostReport,
          ),
          if (rootComposerOpen) ...<Widget>[
            const SizedBox(height: 12),
            InlineReplyComposer(
              parent: null,
              isSending: detail.postingReplyKeys
                  .contains(PostDetailState.replyKey(null)),
              onCancel: onCancelRootReply,
              onSubmit: onSubmitRootReply,
            ),
          ],
          const SizedBox(height: 20),
          if (tree.isEmpty)
            _EmptyComments(onReply: onOpenRootReply)
          else
            Padding(
              key: PostDetailScreen.commentsKey,
              padding: EdgeInsets.zero,
              child: CommentThread(
                nodes: tree,
                handlers: handlers,
                activeReplyParentId: activeReplyParentId == ''
                    ? null
                    : activeReplyParentId,
                replyingParentKeys: detail.postingReplyKeys,
              ),
            ),
        ],
      ),
    );
  }
}

class _PostHeader extends StatelessWidget {
  const _PostHeader({
    required this.post,
    required this.now,
    required this.pendingVote,
    required this.onUpvote,
    required this.onDownvote,
    required this.onReply,
    required this.onReport,
  });

  final ForumPost post;
  final DateTime now;
  final int pendingVote;
  final VoidCallback onUpvote;
  final VoidCallback onDownvote;
  final VoidCallback? onReply;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String displayName = displayNameForAuthor(post.authorId);
    final String time = relativeTime(post.createdAt, now);
    return Container(
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$displayName · $time',
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.primarySoft,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            post.title,
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
          if (post.body.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              post.body,
              style: textTheme.bodyLarge?.copyWith(
                color: careblazersColors.text,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              IconButton(
                key: PostDetailScreen.postUpvoteKey,
                onPressed: onUpvote,
                icon: const Icon(Icons.arrow_upward),
                iconSize: 22,
                color: pendingVote == 1
                    ? careblazersColors.cta
                    : careblazersColors.primarySoft,
                tooltip: 'Upvote',
              ),
              Text(
                '${post.voteCount}',
                style: textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                key: PostDetailScreen.postDownvoteKey,
                onPressed: onDownvote,
                icon: const Icon(Icons.arrow_downward),
                iconSize: 22,
                color: pendingVote == -1
                    ? careblazersColors.primary
                    : careblazersColors.primarySoft,
                tooltip: 'Downvote',
              ),
              const SizedBox(width: 8),
              if (onReply != null)
                TextButton.icon(
                  key: PostDetailScreen.rootReplyButtonKey,
                  onPressed: onReply,
                  icon: const Icon(Icons.reply, size: 18),
                  label: const Text('Reply'),
                  style: TextButton.styleFrom(
                    foregroundColor: careblazersColors.primarySoft,
                  ),
                ),
              const Spacer(),
              Icon(
                Icons.mode_comment_outlined,
                size: 18,
                color: careblazersColors.primarySoft,
              ),
              const SizedBox(width: 4),
              Text(
                '${post.commentCount}',
                style: textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.primarySoft,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (onReport != null)
                IconButton(
                  key: PostDetailScreen.postReportKey,
                  onPressed: onReport,
                  icon: const Icon(Icons.flag_outlined),
                  iconSize: 18,
                  tooltip: 'Report post',
                  color: careblazersColors.primarySoft,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyComments extends StatelessWidget {
  const _EmptyComments({required this.onReply});

  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: PostDetailScreen.emptyCommentsKey,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.mode_comment_outlined,
            size: 40,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 8),
          Text(
            'Be the first to reply.',
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'A few warm words go a long way.',
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.primarySoft,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onReply,
            style: TextButton.styleFrom(
              foregroundColor: careblazersColors.cta,
            ),
            child: const Text('Reply'),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: PostDetailScreen.errorKey,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: careblazersColors.primarySoft,
            ),
            const SizedBox(height: 12),
            Text(
              "We couldn't load this post.",
              style: textTheme.bodyLarge?.copyWith(
                color: careblazersColors.text,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              message,
              style: textTheme.bodyMedium?.copyWith(
                color: careblazersColors.primarySoft,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: careblazersColors.cta,
                foregroundColor: Colors.white,
              ),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
