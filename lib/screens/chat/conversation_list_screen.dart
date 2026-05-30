import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/chat.dart';
import '../../services/chat_repository.dart';
import '../../theme.dart';

part 'conversation_list_screen.g.dart';

/// One tile in the conversation list (BUILD_SPEC.md / TASKS.md Phase
/// 11.4). Joins a [Conversation] row with the first user-authored
/// message's body so the list-screen tile can show the spec-mandated
/// "first user message's first 60 chars" title without forcing every
/// caller to re-walk the messages table.
@immutable
class ConversationListItem {
  const ConversationListItem({
    required this.conversation,
    required this.firstUserMessage,
    required this.lastMessage,
  });

  final Conversation conversation;

  /// Body of the first user-authored [Message] in the thread, or null
  /// when the conversation has no user turns yet (a freshly-minted
  /// thread the caregiver hasn't typed into).
  final String? firstUserMessage;

  /// Body of the most-recent message in the thread (either role), or
  /// null when the thread is still empty. The tile renders this as a
  /// dim secondary line under the title so the list reads like a
  /// messaging app's recent-activity view.
  final String? lastMessage;

  /// Title to display in the tile — first user message's first 60
  /// chars per spec, or a soft fallback when the thread is empty.
  String get displayTitle {
    final String? body = firstUserMessage;
    if (body == null || body.trim().isEmpty) return 'New chat';
    final String trimmed = body.trim();
    if (trimmed.length <= 60) return trimmed;
    return '${trimmed.substring(0, 60)}…';
  }
}

/// Async list of conversations enriched with each thread's first user
/// message (for the spec-mandated title). One drift query per
/// conversation — the list is small (a caregiver builds up tens, not
/// thousands) so the N+1 stays well inside the latency budget for an
/// initial-screen render.
///
/// Watched by [ConversationListScreen]; tests override
/// [chatRepositoryProvider] with an in-memory drift database so the
/// FutureProvider resolves synchronously inside the test harness.
@Riverpod(keepAlive: false)
Future<List<ConversationListItem>> chatConversationList(Ref ref) async {
  final ChatRepository repo = ref.watch(chatRepositoryProvider);
  final List<Conversation> conversations = await repo.listConversations();
  final List<ConversationListItem> items = <ConversationListItem>[];
  for (final Conversation c in conversations) {
    final List<Message> msgs = await repo.loadMessages(c.id);
    final Message? firstUser = msgs.cast<Message?>().firstWhere(
          (Message? m) => m?.role == MessageRole.user,
          orElse: () => null,
        );
    items.add(ConversationListItem(
      conversation: c,
      firstUserMessage: firstUser?.body,
      lastMessage: msgs.isEmpty ? null : msgs.last.body,
    ));
  }
  return items;
}

/// Mint a conversation id. Overridable so widget tests get deterministic
/// ids to assert against without depending on wall-clock entropy.
typedef ConversationIdFactory = String Function();

String _defaultConversationIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  return 'convo-$ms';
}

/// Wall clock the conversation-list screen uses when stamping a freshly
/// created conversation's `createdAt` field. Overridable for tests.
@Riverpod(keepAlive: true)
DateTime Function() conversationListClock(Ref ref) => DateTime.now;

/// ID factory the conversation-list screen uses when minting a new
/// conversation row. Overridable for tests.
@Riverpod(keepAlive: true)
ConversationIdFactory conversationListIdFactory(Ref ref) =>
    _defaultConversationIdFactory;

/// Conversation list screen at `/chat` (TASKS.md Phase 11.4).
///
/// Two states:
///   - Empty: a soft welcome + a single "+ Quick Chat" salmon CTA.
///   - Populated: each conversation as a tile (title derived from the
///     first user message, dim subtitle showing the latest message),
///     with a salmon "+ Quick Chat" FAB anchored to the lower-right.
///
/// Tapping a tile pushes `/chat/<id>`. Tapping "+ Quick Chat" mints a
/// fresh conversation row in the repository (placeholder title) and
/// pushes `/chat/<new-id>` — the chat screen's first send then becomes
/// the implicit title via the [firstUserMessage]-derived display.
class ConversationListScreen extends ConsumerWidget {
  const ConversationListScreen({super.key});

  static const Key emptyQuickChatKey = Key('conversation-list-empty-quick-chat');
  static const Key fabQuickChatKey = Key('conversation-list-fab-quick-chat');
  static const Key listKey = Key('conversation-list-list');
  static const Key emptyStateKey = Key('conversation-list-empty');

  static Key tileKey(String conversationId) =>
      Key('conversation-list-tile-$conversationId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ConversationListItem>> async =
        ref.watch(chatConversationListProvider);

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Coach chat'),
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (List<ConversationListItem> items) {
            if (items.isEmpty) return _EmptyState(onStart: () => _start(context, ref));
            return _PopulatedList(items: items);
          },
        ),
      ),
      floatingActionButton: async.maybeWhen(
        data: (List<ConversationListItem> items) {
          if (items.isEmpty) return null;
          return _QuickChatFab(onPressed: () => _start(context, ref));
        },
        orElse: () => null,
      ),
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final ChatRepository repo = ref.read(chatRepositoryProvider);
    final String id = ref.read(conversationListIdFactoryProvider)();
    final DateTime now = ref.read(conversationListClockProvider)();
    await repo.createConversation(
      id: id,
      title: 'New chat',
      createdAt: now,
    );
    ref.invalidate(chatConversationListProvider);
    if (!context.mounted) return;
    unawaited(context.push('/chat/$id'));
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: ConversationListScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.chat_bubble_outline,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'Ask the coach.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "When something's confusing — a behavior you haven't seen "
            'before, a phrase that keeps coming up — start a chat and '
            "Dr. Natali's framework will meet you there.",
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.text,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'Quick chat. Start a new conversation with the coach.',
            child: ElevatedButton.icon(
              key: ConversationListScreen.emptyQuickChatKey,
              onPressed: onStart,
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                'Quick Chat',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: careblazersColors.cta,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PopulatedList extends StatelessWidget {
  const _PopulatedList({required this.items});

  final List<ConversationListItem> items;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: ConversationListScreen.listKey,
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final ConversationListItem item = items[index];
        return _ConversationTile(item: item);
      },
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.item});

  final ConversationListItem item;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String? sub = item.lastMessage;
    return Semantics(
      button: true,
      label: '${item.displayTitle}. Double-tap to open this chat.',
      child: Material(
        color: careblazersColors.background,
        child: InkWell(
          key: ConversationListScreen.tileKey(item.conversation.id),
          onTap: () => context.push('/chat/${item.conversation.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.displayTitle,
                        style: textTheme.bodyLarge?.copyWith(
                          color: careblazersColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (sub != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          sub,
                          style: textTheme.bodyMedium?.copyWith(
                            color: careblazersColors.primarySoft,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: careblazersColors.primarySoft,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickChatFab extends StatelessWidget {
  const _QuickChatFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Quick chat. Start a new conversation with the coach.',
      child: FloatingActionButton.extended(
        key: ConversationListScreen.fabQuickChatKey,
        onPressed: onPressed,
        backgroundColor: careblazersColors.cta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Quick Chat',
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          "We couldn't load your chats.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
