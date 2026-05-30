import 'package:careblazers/models/forum.dart';
import 'package:careblazers/widgets/community/comment_thread.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime _fixedNow = DateTime.utc(2026, 5, 30, 12);

ForumComment _c(
  String id, {
  String? parent,
  int depth = 0,
  int voteCount = 0,
  bool hidden = false,
  String body = 'hello',
}) =>
    ForumComment(
      id: id,
      postId: 'p',
      parentCommentId: parent,
      authorId: hidden ? null : 'profile-$id',
      body: hidden ? null : body,
      createdAt: _fixedNow,
      voteCount: voteCount,
      depth: depth,
      hidden: hidden,
    );

/// Default no-op handler bundle so each test only customizes the
/// callback under test instead of restating the eight-field record.
CommentThreadHandlers _handlers({
  void Function(ForumComment, int)? onVote,
  void Function(ForumComment)? onReplyTap,
  Future<void> Function(ForumComment)? onReport,
  Future<void> Function(ForumComment?, String)? onSubmitReply,
  void Function(ForumComment?)? onCancelReply,
  int Function(ForumComment)? replyValueFor,
}) =>
    CommentThreadHandlers(
      onVote: onVote ?? (ForumComment _, int __) {},
      onReplyTap: onReplyTap ?? (ForumComment _) {},
      onReport: onReport ?? (ForumComment _) async {},
      onSubmitReply:
          onSubmitReply ?? (ForumComment? _, String __) async {},
      onCancelReply: onCancelReply ?? (ForumComment? _) {},
      replyValueFor: replyValueFor ?? (ForumComment _) => 0,
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<CommentTreeNode> nodes,
  String? activeReplyParentId,
  Set<String> replyingParentKeys = const <String>{},
  CommentThreadHandlers? handlers,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CommentThread(
            nodes: nodes,
            handlers: handlers ?? _handlers(),
            activeReplyParentId: activeReplyParentId,
            replyingParentKeys: replyingParentKeys,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('buildCommentTree — Phase 13.11', () {
    test('roots stay roots, children attach to their parents', () {
      final List<ForumComment> flat = <ForumComment>[
        _c('root-a'),
        _c('root-b'),
        _c('child-a1', parent: 'root-a', depth: 1),
        _c('child-a2', parent: 'root-a', depth: 1),
        _c('grand-a1', parent: 'child-a1', depth: 2),
      ];
      final List<CommentTreeNode> roots = buildCommentTree(flat);
      expect(roots.map((CommentTreeNode n) => n.comment.id).toList(),
          <String>['root-a', 'root-b']);
      expect(roots.first.children.map((CommentTreeNode n) => n.comment.id),
          <String>['child-a1', 'child-a2']);
      expect(roots.first.children.first.children.map((CommentTreeNode n) => n.comment.id),
          <String>['grand-a1']);
    });

    test('orphaned children promote to roots so nothing silently drops', () {
      final List<ForumComment> flat = <ForumComment>[
        _c('present-root'),
        _c('orphan', parent: 'missing-parent', depth: 1),
      ];
      final List<CommentTreeNode> roots = buildCommentTree(flat);
      expect(roots.map((CommentTreeNode n) => n.comment.id).toSet(),
          <String>{'present-root', 'orphan'});
    });
  });

  group('CommentThread render — Phase 13.11', () {
    testWidgets('renders a single root-level comment with vote arrows',
        (WidgetTester tester) async {
      final ForumComment c = _c('only', voteCount: 4);
      await _pump(
        tester,
        nodes: <CommentTreeNode>[
          CommentTreeNode(comment: c, children: const <CommentTreeNode>[]),
        ],
      );
      expect(find.byKey(CommentThread.rowKey('only')), findsOneWidget);
      expect(find.byKey(CommentThread.upvoteKey('only')), findsOneWidget);
      expect(find.byKey(CommentThread.downvoteKey('only')), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('renders a 3-level deep thread', (WidgetTester tester) async {
      final List<CommentTreeNode> nodes = buildCommentTree(<ForumComment>[
        _c('r', body: 'root'),
        _c('m', parent: 'r', depth: 1, body: 'middle'),
        _c('l', parent: 'm', depth: 2, body: 'leaf'),
      ]);
      await _pump(tester, nodes: nodes);
      expect(find.byKey(CommentThread.rowKey('r')), findsOneWidget);
      expect(find.byKey(CommentThread.rowKey('m')), findsOneWidget);
      expect(find.byKey(CommentThread.rowKey('l')), findsOneWidget);
      expect(find.text('root'), findsOneWidget);
      expect(find.text('middle'), findsOneWidget);
      expect(find.text('leaf'), findsOneWidget);
      // Reply still visible — depth 2 is well under the cap.
      expect(find.byKey(CommentThread.replyButtonKey('l')), findsOneWidget);
    });

    testWidgets(
      'reply button hidden once a comment reaches max depth',
      (WidgetTester tester) async {
        final ForumComment leaf = _c('leaf', depth: maxCommentDepth);
        await _pump(
          tester,
          nodes: <CommentTreeNode>[
            CommentTreeNode(
              comment: leaf,
              children: const <CommentTreeNode>[],
            ),
          ],
        );
        expect(find.byKey(CommentThread.rowKey('leaf')), findsOneWidget);
        // No "Reply" affordance at max depth — replying would be
        // rejected with `max_depth_exceeded`.
        expect(
          find.byKey(CommentThread.replyButtonKey('leaf')),
          findsNothing,
        );
        // Up / down vote arrows still render.
        expect(find.byKey(CommentThread.upvoteKey('leaf')), findsOneWidget);
      },
    );

    testWidgets('hidden comments render the [removed] placeholder',
        (WidgetTester tester) async {
      final ForumComment hidden = _c('h', hidden: true);
      await _pump(
        tester,
        nodes: <CommentTreeNode>[
          CommentTreeNode(comment: hidden, children: const <CommentTreeNode>[]),
        ],
      );
      expect(find.text(hiddenCommentPlaceholder), findsOneWidget);
      // No reply / vote affordance on hidden rows.
      final IconButton upvote = tester.widget<IconButton>(
        find.byKey(CommentThread.upvoteKey('h')),
      );
      expect(upvote.onPressed, isNull);
      expect(find.byKey(CommentThread.replyButtonKey('h')), findsNothing);
    });

    testWidgets('tap on upvote dispatches vote=+1', (WidgetTester tester) async {
      int? captured;
      await _pump(
        tester,
        nodes: <CommentTreeNode>[
          CommentTreeNode(
            comment: _c('c1'),
            children: const <CommentTreeNode>[],
          ),
        ],
        handlers: _handlers(
          onVote: (ForumComment _, int v) => captured = v,
        ),
      );
      await tester.tap(find.byKey(CommentThread.upvoteKey('c1')));
      expect(captured, 1);
    });

    testWidgets(
      'pending +1 toggles back to 0 when the upvote is tapped again',
      (WidgetTester tester) async {
        int? captured;
        await _pump(
          tester,
          nodes: <CommentTreeNode>[
            CommentTreeNode(
              comment: _c('c1'),
              children: const <CommentTreeNode>[],
            ),
          ],
          handlers: _handlers(
            onVote: (ForumComment _, int v) => captured = v,
            replyValueFor: (ForumComment _) => 1,
          ),
        );
        await tester.tap(find.byKey(CommentThread.upvoteKey('c1')));
        expect(captured, 0);
      },
    );

    testWidgets('long-press fires the report handler',
        (WidgetTester tester) async {
      ForumComment? reported;
      await _pump(
        tester,
        nodes: <CommentTreeNode>[
          CommentTreeNode(
            comment: _c('c1'),
            children: const <CommentTreeNode>[],
          ),
        ],
        handlers: _handlers(
          onReport: (ForumComment c) async => reported = c,
        ),
      );
      await tester.longPress(find.byKey(CommentThread.rowKey('c1')));
      await tester.pumpAndSettle();
      expect(reported?.id, 'c1');
    });

    testWidgets(
      'active reply composer renders below the parent comment',
      (WidgetTester tester) async {
        await _pump(
          tester,
          nodes: <CommentTreeNode>[
            CommentTreeNode(
              comment: _c('c1'),
              children: const <CommentTreeNode>[],
            ),
          ],
          activeReplyParentId: 'c1',
        );
        expect(
          find.byKey(CommentThread.replyComposerKey('c1')),
          findsOneWidget,
        );
        expect(
          find.byKey(CommentThread.replySendKey('c1')),
          findsOneWidget,
        );
      },
    );
  });

  group('InlineReplyComposer — Phase 13.11', () {
    testWidgets('Send button only fires on non-empty trimmed text',
        (WidgetTester tester) async {
      final List<String> sent = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineReplyComposer(
              parent: null,
              isSending: false,
              onCancel: () {},
              onSubmit: (String body) async => sent.add(body),
            ),
          ),
        ),
      );
      // Empty submit — no callback.
      await tester.tap(const Key('reply-composer-root-send').asFinder());
      await tester.pump();
      expect(sent, isEmpty);

      await tester.enterText(
        const Key('reply-composer-root-field').asFinder(),
        '   hi there  ',
      );
      await tester.tap(const Key('reply-composer-root-send').asFinder());
      await tester.pump();
      expect(sent, <String>['hi there']);
    });

    testWidgets('Cancel forwards to the parent handler',
        (WidgetTester tester) async {
      int cancels = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineReplyComposer(
              parent: null,
              isSending: false,
              onCancel: () => cancels++,
              onSubmit: (String _) async {},
            ),
          ),
        ),
      );
      await tester.tap(const Key('reply-composer-root-cancel').asFinder());
      expect(cancels, 1);
    });

    testWidgets('Send button shows a spinner while a submit is in flight',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineReplyComposer(
              parent: null,
              isSending: true,
              onCancel: () {},
              onSubmit: (String _) async {},
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}

/// `Key`-to-`Finder` shortcut so the inline-composer tests above stay
/// terse. Mirrors `find.byKey(k)` but reads as a property on the key
/// itself for readability inside `tester.tap(...)` / `tester.enterText`
/// call sites.
extension on Key {
  Finder asFinder() => find.byKey(this);
}
