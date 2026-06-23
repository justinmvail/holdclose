import 'package:flutter/material.dart';

import '../../models/forum.dart';
import '../../theme.dart';

/// Maximum reply depth the forum API will accept (mirrors the Worker's
/// `MAX_COMMENT_DEPTH` constant). At depth [maxCommentDepth] the reply
/// button is hidden — a deeper post would 400 with `max_depth_exceeded`
/// (BUILD_SPEC.md §13 / Phase 13.11). Top-level comments have depth=0;
/// a 6-level-deep leaf has depth=6.
const int maxCommentDepth = 6;

/// Pixels of left-indent applied per nesting level (BUILD_SPEC.md §13 /
/// Phase 13.11 — "24px left-indent per depth level"). Matches the
/// Reddit visual the spec calls out.
const double commentIndentStep = 24.0;

/// Placeholder body used for comments the Worker has hidden (Phase
/// 13.6 — moderation nulls [ForumComment.body]). Renders as a dim
/// italic stub so the reply chain stitched below the parent stays
/// visible.
const String hiddenCommentPlaceholder = '[removed]';

/// One node in the rendered comment tree. Public so the screen / tests
/// can build expected trees by hand, and so [buildCommentTree] returns
/// a typed structure rather than a nested record.
@immutable
class CommentTreeNode {
  const CommentTreeNode({required this.comment, required this.children});

  final ForumComment comment;
  final List<CommentTreeNode> children;
}

/// Build a depth-ordered tree from the flat list the API returns. Roots
/// (no [ForumComment.parentCommentId]) come first; children attach to
/// their parent's [CommentTreeNode.children] in the same order they
/// appear in [flat]. Comments whose parent is missing from [flat] are
/// promoted to roots so a partial fetch never silently drops rows.
List<CommentTreeNode> buildCommentTree(Iterable<ForumComment> flat) {
  final Map<String, CommentTreeNode> nodes = <String, CommentTreeNode>{
    for (final ForumComment c in flat)
      // The children list intentionally stays *non-const* so we can
      // append to it as we walk the flat input below.
      // ignore: prefer_const_literals_to_create_immutables
      c.id: CommentTreeNode(comment: c, children: <CommentTreeNode>[]),
  };
  final List<CommentTreeNode> roots = <CommentTreeNode>[];
  for (final ForumComment c in flat) {
    final CommentTreeNode node = nodes[c.id]!;
    final String? parentId = c.parentCommentId;
    if (parentId == null) {
      roots.add(node);
      continue;
    }
    final CommentTreeNode? parent = nodes[parentId];
    if (parent == null) {
      // Parent missing from the page — promote to root so the comment
      // still renders rather than dangling off a non-existent anchor.
      roots.add(node);
    } else {
      parent.children.add(node);
    }
  }
  return roots;
}

/// Read-only voting + replying handlers wired through [CommentThread]
/// to each child comment row. Hosted on the parent so the recursive
/// tree itself stays pure (no state, no providers); the screen owns
/// the in-flight bookkeeping.
@immutable
class CommentThreadHandlers {
  const CommentThreadHandlers({
    required this.onVote,
    required this.onReplyTap,
    required this.onReport,
    required this.onSubmitReply,
    required this.onCancelReply,
    required this.replyValueFor,
    required this.isOwn,
    required this.onDelete,
  });

  /// Cast a vote on a comment. [value] is +1, -1, or 0 (to clear).
  final void Function(ForumComment comment, int value) onVote;

  /// User tapped the reply button on a row. The screen flips its
  /// `activeReplyParentId` to [comment].id so the recursive widget
  /// re-renders an inline composer below the row.
  final void Function(ForumComment comment) onReplyTap;

  /// User picked "Report" from the long-press menu. Returns the chosen
  /// reason key (`spam`, `harassment`, etc.) so the screen can call
  /// [PostDetail.report] with the correct payload.
  final Future<void> Function(ForumComment comment) onReport;

  /// Submit the inline reply input under [comment]. Triggered by the
  /// composer's send button.
  final Future<void> Function(ForumComment? parent, String body) onSubmitReply;

  /// Close an active reply input. The screen clears its
  /// `activeReplyParentId` and the composer disappears.
  final void Function(ForumComment? parent) onCancelReply;

  /// Pending-vote value to highlight for [comment]. Returns 0 when the
  /// row has no optimistic flip pending so the arrows render neutral.
  final int Function(ForumComment comment) replyValueFor;

  /// Whether [comment] belongs to the signed-in caregiver. When true the
  /// row's long-press opens the owner action sheet (Delete) via [onDelete]
  /// instead of the report sheet — a caregiver manages their own replies and
  /// reports everyone else's.
  final bool Function(ForumComment comment) isOwn;

  /// User long-pressed their OWN comment — open the delete action sheet.
  /// Only invoked for rows where [isOwn] returns true.
  final Future<void> Function(ForumComment comment) onDelete;
}

/// Recursive comment-tree widget (BUILD_SPEC.md §13 / Phase 13.11).
///
/// Renders each [CommentTreeNode] as a row of body text + a vote /
/// reply / report action bar. Children recurse with a 24px left-indent
/// per [maxCommentDepth] level, matching the Reddit visual the spec
/// calls out.
///
/// Stateless on purpose — the screen owns:
///   * which comment currently has its inline reply input open
///     ([activeReplyParentId]),
///   * the in-flight reply spinner set ([replyingParentKeys]),
///   * the optimistic vote-direction map (read through
///     [CommentThreadHandlers.replyValueFor]).
///
/// Hidden comments render as a placeholder so the reply chain remains
/// visible even when a parent has been moderated away.
class CommentThread extends StatelessWidget {
  const CommentThread({
    super.key,
    required this.nodes,
    required this.handlers,
    required this.activeReplyParentId,
    required this.replyingParentKeys,
  });

  /// Top-level comment nodes. Each node's children render recursively.
  final List<CommentTreeNode> nodes;

  final CommentThreadHandlers handlers;

  /// Comment id whose inline reply composer is currently open. Null
  /// means no reply input is showing under any comment.
  final String? activeReplyParentId;

  /// Comment ids (and the empty string for the root-level composer)
  /// whose reply submission is currently in flight. The matching row's
  /// composer renders a spinner instead of the send button.
  final Set<String> replyingParentKeys;

  static Key rowKey(String commentId) => Key('comment-row-$commentId');
  static Key upvoteKey(String commentId) => Key('comment-upvote-$commentId');
  static Key downvoteKey(String commentId) =>
      Key('comment-downvote-$commentId');
  static Key replyButtonKey(String commentId) =>
      Key('comment-reply-$commentId');

  /// Trailing "Reply options" icon shown on the caregiver's own comment row
  /// (the tap-equivalent of the long-press → delete sheet).
  static Key deleteTriggerKey(String commentId) =>
      Key('comment-delete-trigger-$commentId');

  /// "Delete reply" item in an own-comment's long-press action sheet.
  static Key deleteKey(String commentId) => Key('comment-delete-$commentId');

  /// Cancel button in an own-comment's long-press action sheet.
  static Key deleteCancelKey(String commentId) =>
      Key('comment-delete-cancel-$commentId');
  static Key replyComposerKey(String commentId) =>
      Key('comment-reply-composer-$commentId');
  static Key replySendKey(String commentId) =>
      Key('comment-reply-send-$commentId');
  static Key replyCancelKey(String commentId) =>
      Key('comment-reply-cancel-$commentId');
  static Key replyFieldKey(String commentId) =>
      Key('comment-reply-field-$commentId');

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final CommentTreeNode node in nodes)
          _CommentSubtree(
            node: node,
            handlers: handlers,
            activeReplyParentId: activeReplyParentId,
            replyingParentKeys: replyingParentKeys,
          ),
      ],
    );
  }
}

class _CommentSubtree extends StatelessWidget {
  const _CommentSubtree({
    required this.node,
    required this.handlers,
    required this.activeReplyParentId,
    required this.replyingParentKeys,
  });

  final CommentTreeNode node;
  final CommentThreadHandlers handlers;
  final String? activeReplyParentId;
  final Set<String> replyingParentKeys;

  @override
  Widget build(BuildContext context) {
    final ForumComment comment = node.comment;
    // Indent compounds via Padding nesting — each level adds exactly
    // [commentIndentStep] (24px per BUILD_SPEC.md §13 / Phase 13.11)
    // regardless of [ForumComment.depth]. Depth-based indenting would
    // double-count for nested rows and would mis-render orphans
    // promoted to root by [buildCommentTree].
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _CommentRow(
            comment: comment,
            handlers: handlers,
            isReplying: replyingParentKeys.contains(comment.id),
          ),
          if (activeReplyParentId == comment.id)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 0, 4),
              child: InlineReplyComposer(
                parent: comment,
                isSending: replyingParentKeys.contains(comment.id),
                onCancel: () => handlers.onCancelReply(comment),
                onSubmit: (String body) =>
                    handlers.onSubmitReply(comment, body),
              ),
            ),
          for (final CommentTreeNode child in node.children)
            Padding(
              padding: const EdgeInsets.only(left: commentIndentStep),
              child: _CommentSubtree(
                node: child,
                handlers: handlers,
                activeReplyParentId: activeReplyParentId,
                replyingParentKeys: replyingParentKeys,
              ),
            ),
        ],
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.handlers,
    required this.isReplying,
  });

  final ForumComment comment;
  final CommentThreadHandlers handlers;
  final bool isReplying;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool hidden = comment.hidden || comment.body == null;
    final String body = hidden ? hiddenCommentPlaceholder : comment.body!;
    final int pending = handlers.replyValueFor(comment);
    final bool canReply = !hidden && comment.depth < maxCommentDepth;
    // Own (non-hidden) comments long-press into the delete sheet; everyone
    // else's long-press into the report sheet. Hidden rows have no author,
    // so they're never "own" and keep no long-press action.
    final bool isOwn = !hidden && handlers.isOwn(comment);

    return GestureDetector(
      onLongPress: hidden
          ? null
          : () => isOwn
              ? handlers.onDelete(comment)
              : handlers.onReport(comment),
      child: Container(
        key: CommentThread.rowKey(comment.id),
        decoration: BoxDecoration(
          color: context.cb.surfaceWarm,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: context.cb.primary.withValues(alpha: 0.08),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              body,
              style: textTheme.bodyMedium?.copyWith(
                color: hidden
                    ? context.cb.primarySoft
                    : context.cb.text,
                fontStyle: hidden ? FontStyle.italic : FontStyle.normal,
              ),
            ),
            const SizedBox(height: 8),
            _ActionBar(
              comment: comment,
              pendingVote: pending,
              canReply: canReply,
              isReplying: isReplying,
              onUpvote: hidden
                  ? null
                  : () => handlers.onVote(comment, pending == 1 ? 0 : 1),
              onDownvote: hidden
                  ? null
                  : () => handlers.onVote(comment, pending == -1 ? 0 : -1),
              onReply: canReply ? () => handlers.onReplyTap(comment) : null,
              // On the caregiver's own comment the trailing slot is a Delete
              // affordance; on everyone else's it's the Report flag. Hidden
              // rows expose neither.
              onReport: (hidden || isOwn)
                  ? null
                  : () => handlers.onReport(comment),
              onDelete: isOwn ? () => handlers.onDelete(comment) : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.comment,
    required this.pendingVote,
    required this.canReply,
    required this.isReplying,
    required this.onUpvote,
    required this.onDownvote,
    required this.onReply,
    required this.onReport,
    required this.onDelete,
  });

  final ForumComment comment;
  final int pendingVote;
  final bool canReply;
  final bool isReplying;
  final VoidCallback? onUpvote;
  final VoidCallback? onDownvote;
  final VoidCallback? onReply;
  final VoidCallback? onReport;

  /// Non-null only on the caregiver's own comment — opens the delete sheet.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        IconButton(
          key: CommentThread.upvoteKey(comment.id),
          onPressed: onUpvote,
          // Salmon (CTA) for the upvote arrow so it matches the brand's
          // warm "yes, agree" colour. Brand spec §3 calls out the
          // salmon-orange as the primary affordance hue.
          color: pendingVote == 1
              ? context.cb.cta
              : context.cb.primarySoft,
          icon: const Icon(Icons.arrow_upward),
          iconSize: 20,
          tooltip: 'Upvote',
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        Text(
          '${comment.voteCount}',
          style: textTheme.bodyMedium?.copyWith(
            color: context.cb.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        IconButton(
          key: CommentThread.downvoteKey(comment.id),
          onPressed: onDownvote,
          // Navy (primary) for the downvote so the cooler colour reads
          // as the de-emphasized direction.
          color: pendingVote == -1
              ? context.cb.primary
              : context.cb.primarySoft,
          icon: const Icon(Icons.arrow_downward),
          iconSize: 20,
          tooltip: 'Downvote',
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        const SizedBox(width: 8),
        if (canReply)
          TextButton.icon(
            key: CommentThread.replyButtonKey(comment.id),
            onPressed: isReplying ? null : onReply,
            icon: const Icon(Icons.reply, size: 18),
            label: const Text('Reply'),
            style: TextButton.styleFrom(
              foregroundColor: context.cb.primarySoft,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        const Spacer(),
        if (onDelete != null)
          IconButton(
            key: CommentThread.deleteTriggerKey(comment.id),
            onPressed: onDelete,
            icon: const Icon(Icons.more_horiz),
            iconSize: 18,
            tooltip: 'Reply options',
            color: context.cb.primarySoft,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          )
        else if (onReport != null)
          IconButton(
            key: Key('comment-report-${comment.id}'),
            onPressed: onReport,
            icon: const Icon(Icons.flag_outlined),
            iconSize: 18,
            tooltip: 'Report',
            color: context.cb.primarySoft,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
      ],
    );
  }
}

/// Inline reply composer rendered under the comment that owns it
/// (BUILD_SPEC.md §13 / Phase 13.11 — "Replying inlines the input
/// below the parent — no modal"). [parent] is null for the
/// root-level composer the post-detail screen renders under the post
/// body itself.
class InlineReplyComposer extends StatefulWidget {
  const InlineReplyComposer({
    super.key,
    required this.parent,
    required this.isSending,
    required this.onCancel,
    required this.onSubmit,
    this.hintText,
  });

  final ForumComment? parent;
  final bool isSending;
  final VoidCallback onCancel;
  final Future<void> Function(String body) onSubmit;
  final String? hintText;

  static const Key rootKey = Key('reply-composer-root');

  @override
  State<InlineReplyComposer> createState() => _InlineReplyComposerState();
}

class _InlineReplyComposerState extends State<InlineReplyComposer> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final String body = _controller.text.trim();
    if (body.isEmpty) return;
    await widget.onSubmit(body);
    if (!mounted) return;
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ForumComment? parent = widget.parent;
    final Key composerKey = parent == null
        ? InlineReplyComposer.rootKey
        : CommentThread.replyComposerKey(parent.id);
    return Container(
      key: composerKey,
      decoration: BoxDecoration(
        color: context.cb.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.cb.primarySoft.withValues(alpha: 0.4),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: parent == null
                ? const Key('reply-composer-root-field')
                : CommentThread.replyFieldKey(parent.id),
            controller: _controller,
            minLines: 1,
            maxLines: 5,
            enabled: !widget.isSending,
            decoration: InputDecoration(
              hintText: widget.hintText ??
                  (parent == null
                      ? 'Share something supportive…'
                      : 'Reply to this caregiver…'),
              border: InputBorder.none,
              isDense: true,
              hintStyle: textTheme.bodyMedium?.copyWith(
                color: context.cb.primarySoft,
              ),
            ),
            style: textTheme.bodyMedium?.copyWith(
              color: context.cb.text,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                key: parent == null
                    ? const Key('reply-composer-root-cancel')
                    : CommentThread.replyCancelKey(parent.id),
                onPressed: widget.isSending ? null : widget.onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: context.cb.primarySoft,
                ),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                key: parent == null
                    ? const Key('reply-composer-root-send')
                    : CommentThread.replySendKey(parent.id),
                onPressed: widget.isSending ? null : _handleSubmit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.cb.cta,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                ),
                child: widget.isSending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
