import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/forum.dart';
import '../../providers/community_feed_provider.dart';
import '../../providers/my_forum_profile_provider.dart';
import '../../providers/post_detail_provider.dart';
import '../../routing/router.dart' show CareblazersRoutes;
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/community/comment_thread.dart';
import '../../widgets/network_error_view.dart';
import '../../widgets/path_header.dart';
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
///   * A [PathHeader] (`Home › Community › Post`, back to Community) at
///     the top of the body — the screen has no AppBar.
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

  /// Overflow ("⋮") menu shown in the post header ONLY on the signed-in
  /// caregiver's own post — the owner's Edit / Delete entry point. Hidden
  /// on every other author's post so the menu can never act on content
  /// that isn't theirs.
  static const Key postOwnerMenuKey = Key('post-detail-post-owner-menu');

  /// The "Edit" item inside [postOwnerMenuKey].
  static const Key postEditKey = Key('post-detail-post-edit');

  /// The "Delete" item inside [postOwnerMenuKey].
  static const Key postDeleteKey = Key('post-detail-post-delete');

  /// Confirm button in the "Delete this post?" dialog.
  static const Key postDeleteConfirmKey = Key('post-detail-post-delete-confirm');

  /// Cancel button in the "Delete this post?" dialog.
  static const Key postDeleteCancelKey = Key('post-detail-post-delete-cancel');

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
        backgroundColor: context.cb.accentDeep,
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
      backgroundColor: context.cb.background,
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
                    color: context.cb.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "We'll take a look. Reports are private.",
                  style: textTheme.bodyMedium?.copyWith(
                    color: context.cb.primarySoft,
                  ),
                ),
                const SizedBox(height: 8),
                for (final ({String label, String reason}) opt in _reportReasons)
                  ListTile(
                    key: Key('report-reason-${opt.reason}'),
                    title: Text(
                      opt.label,
                      style: textTheme.bodyLarge?.copyWith(
                        color: context.cb.primary,
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(opt.reason),
                  ),
                TextButton(
                  key: const Key('report-cancel'),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: context.cb.primarySoft,
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

  /// Open the compose surface in edit mode, prefilled with this post's
  /// title + body. The compose screen submits the edit through
  /// [ForumApiClient.updatePost] and pops back here; we re-fetch so the
  /// header shows the saved body. Only ever reachable from the owner menu,
  /// which is gated on [myForumProfileIdProvider].
  Future<void> _editPost(ForumPost post) async {
    await context.pushNamed(
      CareblazersRoutes.communityPostEdit,
      pathParameters: <String, String>{'postId': post.id},
      extra: post,
    );
    if (!mounted) return;
    // The compose screen refreshes the feed itself; re-pull the detail so
    // the edited body lands on this header without a manual pull.
    await ref.read(postDetailProvider.notifier).refresh();
  }

  /// Confirm + delete this post, then pop back to the feed. Only reachable
  /// from the owner menu. On success the feed re-fetches so the deleted row
  /// drops out of every sort.
  Future<void> _deletePost(ForumPost post) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.cb.background,
        title: Text(
          'Delete this post?',
          style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(
                color: context.cb.primary,
              ),
        ),
        content: Text(
          "This removes your post and its replies for everyone. This can't "
          'be undone.',
          style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                color: context.cb.text,
              ),
        ),
        actions: <Widget>[
          TextButton(
            key: PostDetailScreen.postDeleteCancelKey,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: context.cb.primarySoft,
            ),
            child: const Text('Keep it'),
          ),
          TextButton(
            key: PostDetailScreen.postDeleteConfirmKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: context.cb.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final bool ok =
        await ref.read(postDetailProvider.notifier).deletePost(post.id);
    if (!mounted) return;
    if (ok) {
      // Refresh the feed so the deleted row is gone when we land back on it.
      unawaited(ref.read(communityFeedProvider.notifier).refresh());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post deleted.')),
      );
      context.goNamed(CareblazersRoutes.community);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't delete the post. Try again.")),
      );
    }
  }

  /// Long-press action sheet for one of the caregiver's OWN comments —
  /// mirrors the report sheet's interaction style (long-press → bottom
  /// sheet of actions). The single destructive "Delete reply" item is the
  /// deliberate second tap that confirms the delete, then drops the row from
  /// the thread. Only reachable when [CommentThreadHandlers.isOwn] is true.
  Future<void> _showOwnCommentSheet(ForumComment comment) async {
    final bool? deleteRequested = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: context.cb.background,
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
                  'Your reply',
                  style: textTheme.titleLarge?.copyWith(
                    color: context.cb.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Deleting removes it for everyone. This can't be undone.",
                  style: textTheme.bodyMedium?.copyWith(
                    color: context.cb.primarySoft,
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  key: CommentThread.deleteKey(comment.id),
                  leading: Icon(
                    Icons.delete_outline,
                    color: context.cb.error,
                  ),
                  title: Text(
                    'Delete reply',
                    style: textTheme.bodyLarge?.copyWith(
                      color: context.cb.error,
                    ),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(true),
                ),
                TextButton(
                  key: CommentThread.deleteCancelKey(comment.id),
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                  style: TextButton.styleFrom(
                    foregroundColor: context.cb.primarySoft,
                  ),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (deleteRequested != true || !mounted) return;

    final bool ok =
        await ref.read(postDetailProvider.notifier).deleteComment(comment.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Reply deleted.' : "Couldn't delete the reply. Try again.",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PostDetailState detail = ref.watch(postDetailProvider);
    final DateTime now = ref.watch(postDetailClockProvider)();
    // The signed-in caregiver's own profile id — the ownership signal the
    // edit / delete affordances gate on. Null while the profile resolves,
    // which keeps the owner controls hidden rather than flashing them onto
    // someone else's content.
    final String? myProfileId = ref.watch(myForumProfileIdProvider);

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
      // A comment is the caregiver's own when its author profile id matches
      // [myProfileId]. Hidden/moderated comments null their author, so they
      // never read as owned.
      isOwn: (ForumComment c) =>
          myProfileId != null && c.authorId == myProfileId,
      onDelete: (ForumComment c) => _showOwnCommentSheet(c),
    );

    return Scaffold(
      backgroundColor: context.cb.background,
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
                  PathHeaderCrumb(label: 'Post'),
                ],
                title: 'Post',
                backLabel: 'Back to Community',
                leadingIcon: Icons.forum_outlined,
              ),
            ),
            Expanded(
              child: _Body(
                detail: detail,
                now: now,
                activeReplyParentId: _activeReplyParentId,
                handlers: handlers,
                // The header post is mine when its author profile id matches
                // the signed-in caregiver's — gates the Edit / Delete menu.
                isOwnPost: detail.post != null &&
                    myProfileId != null &&
                    detail.post!.authorId == myProfileId,
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
                onPostEdit: detail.post == null
                    ? null
                    : () => _editPost(detail.post!),
                onPostDelete: detail.post == null
                    ? null
                    : () => _deletePost(detail.post!),
                onOpenRootReply: () => _openReplyTo(null),
                onSubmitRootReply: (String body) => _submitReply(null, body),
                onCancelRootReply: _cancelReply,
              ),
            ),
          ],
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
    required this.isOwnPost,
    required this.onRefresh,
    required this.onPostUpvote,
    required this.onPostDownvote,
    required this.onPostReport,
    required this.onPostEdit,
    required this.onPostDelete,
    required this.onOpenRootReply,
    required this.onSubmitRootReply,
    required this.onCancelRootReply,
  });

  final PostDetailState detail;
  final DateTime now;
  final String? activeReplyParentId;
  final CommentThreadHandlers handlers;

  /// Whether the header post belongs to the signed-in caregiver — gates the
  /// owner overflow menu (Edit / Delete) in [_PostHeader].
  final bool isOwnPost;
  final Future<void> Function() onRefresh;
  final VoidCallback onPostUpvote;
  final VoidCallback onPostDownvote;
  final VoidCallback? onPostReport;
  final VoidCallback? onPostEdit;
  final VoidCallback? onPostDelete;
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
            color: context.cb.primarySoft,
          ),
        ),
      );
    }
    final ForumPost? post = detail.post;
    if (post == null) {
      // Load failed before any post landed (the feed didn't hand one off, or
      // a refresh dropped it) → the branded retry surface instead of a blank
      // screen. Transport failures get the "check your connection" copy.
      return Padding(
        key: PostDetailScreen.errorKey,
        padding: EdgeInsets.zero,
        child: NetworkErrorView(
          headline: "We couldn't load this post.",
          detail: networkErrorDetail(detail.error),
          onRetry: onRefresh,
        ),
      );
    }
    final List<CommentTreeNode> tree = buildCommentTree(detail.comments);
    final bool rootComposerOpen = activeReplyParentId == '';

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: context.cb.cta,
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
            isOwn: isOwnPost,
            onUpvote: onPostUpvote,
            onDownvote: onPostDownvote,
            onReply: rootComposerOpen ? null : onOpenRootReply,
            onReport: onPostReport,
            onEdit: onPostEdit,
            onDelete: onPostDelete,
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
    required this.isOwn,
    required this.onUpvote,
    required this.onDownvote,
    required this.onReply,
    required this.onReport,
    required this.onEdit,
    required this.onDelete,
  });

  final ForumPost post;
  final DateTime now;
  final int pendingVote;

  /// Whether this post belongs to the signed-in caregiver. When true the
  /// trailing slot shows the owner overflow menu (Edit / Delete) instead of
  /// the "Report post" flag — you don't report your own post.
  final bool isOwn;
  final VoidCallback onUpvote;
  final VoidCallback onDownvote;
  final VoidCallback? onReply;
  final VoidCallback? onReport;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String displayName = displayNameForAuthor(
      post.authorId,
      username: post.authorUsername,
      displayName: post.authorDisplayName,
    );
    final String time = relativeTime(post.createdAt, now);
    return Container(
      decoration: BoxDecoration(
        color: context.cb.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$displayName · $time',
            style: textTheme.bodyMedium?.copyWith(
              color: context.cb.primarySoft,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            post.title,
            style: textTheme.headlineMedium?.copyWith(
              color: context.cb.primary,
            ),
          ),
          if (post.body.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              post.body,
              style: textTheme.bodyLarge?.copyWith(
                color: context.cb.text,
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
                    ? context.cb.cta
                    : context.cb.primarySoft,
                tooltip: 'Upvote',
              ),
              Text(
                '${post.voteCount}',
                style: textTheme.bodyMedium?.copyWith(
                  color: context.cb.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                key: PostDetailScreen.postDownvoteKey,
                onPressed: onDownvote,
                icon: const Icon(Icons.arrow_downward),
                iconSize: 22,
                color: pendingVote == -1
                    ? context.cb.primary
                    : context.cb.primarySoft,
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
                    foregroundColor: context.cb.primarySoft,
                  ),
                ),
              const Spacer(),
              Icon(
                Icons.mode_comment_outlined,
                size: 18,
                color: context.cb.primarySoft,
              ),
              const SizedBox(width: 4),
              Text(
                '${post.commentCount}',
                style: textTheme.bodyMedium?.copyWith(
                  color: context.cb.primarySoft,
                  fontWeight: FontWeight.w700,
                ),
              ),
              // The caregiver's own post shows the owner menu (Edit /
              // Delete); everyone else's shows the report flag. Gating the
              // two on [isOwn] keeps the destructive actions off content the
              // signed-in user doesn't own.
              if (isOwn)
                PopupMenuButton<_PostOwnerAction>(
                  key: PostDetailScreen.postOwnerMenuKey,
                  tooltip: 'Post options',
                  icon: Icon(
                    Icons.more_vert,
                    size: 20,
                    color: context.cb.primarySoft,
                  ),
                  onSelected: (_PostOwnerAction action) {
                    switch (action) {
                      case _PostOwnerAction.edit:
                        onEdit?.call();
                      case _PostOwnerAction.delete:
                        onDelete?.call();
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<_PostOwnerAction>>[
                    const PopupMenuItem<_PostOwnerAction>(
                      key: PostDetailScreen.postEditKey,
                      value: _PostOwnerAction.edit,
                      child: Text('Edit post'),
                    ),
                    const PopupMenuItem<_PostOwnerAction>(
                      key: PostDetailScreen.postDeleteKey,
                      value: _PostOwnerAction.delete,
                      child: Text('Delete post'),
                    ),
                  ],
                )
              else if (onReport != null)
                IconButton(
                  key: PostDetailScreen.postReportKey,
                  onPressed: onReport,
                  icon: const Icon(Icons.flag_outlined),
                  iconSize: 18,
                  tooltip: 'Report post',
                  color: context.cb.primarySoft,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The two owner actions surfaced in the post header overflow menu
/// ([PostDetailScreen.postOwnerMenuKey]).
enum _PostOwnerAction { edit, delete }

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
            color: context.cb.primarySoft,
          ),
          const SizedBox(height: 8),
          Text(
            'Be the first to reply.',
            style: textTheme.titleLarge?.copyWith(
              color: context.cb.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'A few warm words go a long way.',
            style: textTheme.bodyMedium?.copyWith(
              color: context.cb.primarySoft,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onReply,
            style: TextButton.styleFrom(
              foregroundColor: context.cb.cta,
            ),
            child: const Text('Reply'),
          ),
        ],
      ),
    );
  }
}
