import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/chat.dart';
import '../../services/chat_repository.dart';
import '../../services/chat_service.dart' show ChatService;
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'conversation_list_screen.g.dart';

/// Derive a conversation's display name from the first user-authored
/// message body — the spec-mandated "first user message's first 60
/// chars" title (TASKS.md Phase 11.4), with a soft "New chat" fallback
/// for a thread the caregiver hasn't typed into yet.
///
/// Shared by [ConversationListItem.displayTitle] (the list tile) and the
/// chat thread's [PathHeader] crumb (Phase 14.34) so a tile and the
/// thread it opens read the same name.
String conversationDisplayTitle(String? firstUserMessage) {
  final String body = firstUserMessage?.trim() ?? '';
  if (body.isEmpty) return 'New chat';
  // Succinct (fb_1781115614890041 — "auto title is too long"): first line,
  // capped near ~36 chars at a WORD boundary so it never ends mid-word
  // ("…loo"). The full message still lives in the thread.
  return _succinctLabel(body.split('\n').first.trim());
}

/// Cap [text] near ~36 chars on a word boundary, appending an ellipsis
/// when it had to be cut. Shared by the derived title and the
/// custom/coach-set title so both read the same length in the list.
String _succinctLabel(String text) {
  final String t = text.trim();
  if (t.length <= 36) return t;
  final String cut = t.substring(0, 36);
  final int lastSpace = cut.lastIndexOf(' ');
  final String base = lastSpace > 18 ? cut.substring(0, lastSpace) : cut;
  return '$base…';
}

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

  /// Title to display in the tile. A coach-generated or caregiver-edited
  /// name ([Conversation.customTitle]) wins verbatim (capped to one tile
  /// line); otherwise it's the succinct derivation from the first user
  /// message, or a soft fallback when the thread is empty
  /// (fb_1781115614890041).
  String get displayTitle {
    final String stored = conversation.title.trim();
    if (conversation.customTitle && stored.isNotEmpty) {
      return _succinctLabel(stored.split('\n').first.trim());
    }
    return conversationDisplayTitle(firstUserMessage);
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
    // The preview renders the last turn's body, so it MUST be sanitised
    // the same way the chat bubble is — strip `[action:…]` tool tags and
    // swap any raw `[chat error: …]` trailer for the friendly line — or
    // the internal marker leaks into the list (alpha bug). An all-marker
    // body sanitises to empty; collapse that back to null so the tile
    // skips the secondary line instead of showing a blank one.
    final String? rawLast = msgs.isEmpty ? null : msgs.last.body;
    final String? cleanLast =
        rawLast == null ? null : ChatService.displayBody(rawLast);
    items.add(ConversationListItem(
      conversation: c,
      firstUserMessage: firstUser?.body,
      lastMessage:
          (cleanLast == null || cleanLast.isEmpty) ? null : cleanLast,
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

  /// The delete-confirmation dialog (a long-press or trash tap on a tile).
  static const Key deleteDialogKey = Key('conversation-list-delete-dialog');
  static const Key deleteConfirmKey = Key('conversation-list-delete-confirm');
  static const Key deleteCancelKey = Key('conversation-list-delete-cancel');

  /// The rename dialog + its field/buttons (per-tile pencil affordance).
  static const Key renameDialogKey = Key('conversation-list-rename-dialog');
  static const Key renameFieldKey = Key('conversation-list-rename-field');
  static const Key renameSaveKey = Key('conversation-list-rename-save');
  static const Key renameCancelKey = Key('conversation-list-rename-cancel');

  static Key tileKey(String conversationId) =>
      Key('conversation-list-tile-$conversationId');
  static Key deleteIconKey(String conversationId) =>
      Key('conversation-list-delete-$conversationId');
  static Key renameIconKey(String conversationId) =>
      Key('conversation-list-rename-$conversationId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ConversationListItem>> async =
        ref.watch(chatConversationListProvider);

    return Scaffold(
      backgroundColor: context.cb.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Tab landing → a single-crumb [PathHeader] renders the title
            // row only (no breadcrumb trail, no Back control). You reach
            // the list by tapping the Chat tab; re-tapping it pops the
            // branch back here (Phase 14.34).
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Chat'),
                ],
                title: 'Chat',
                backLabel: 'Back to Home',
                leadingIcon: Icons.chat_bubble_outline,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (List<ConversationListItem> items) {
                  if (items.isEmpty) {
                    return _EmptyState(onStart: () => _start(context, ref));
                  }
                  return _PopulatedList(items: items);
                },
              ),
            ),
          ],
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
            color: context.cb.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'Ask the coach.',
            style: textTheme.headlineMedium?.copyWith(
              color: context.cb.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "When something's confusing — a behavior you haven't seen "
            'before, a phrase that keeps coming up — start a chat and '
            "Dr. Natali's framework will meet you there.",
            style: textTheme.bodyLarge?.copyWith(
              color: context.cb.text,
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
                backgroundColor: context.cb.cta,
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

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({required this.item});

  final ConversationListItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String? sub = item.lastMessage;
    return Semantics(
      button: true,
      label: '${item.displayTitle}. Double-tap to open this chat.',
      child: Material(
        color: context.cb.background,
        child: InkWell(
          key: ConversationListScreen.tileKey(item.conversation.id),
          onTap: () => context.push('/chat/${item.conversation.id}'),
          // Long-press to delete — mirrors the medication list's tile
          // gesture so the two "list of things you can remove" surfaces
          // behave the same.
          onLongPress: () => _confirmAndDelete(context, ref),
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
                          color: context.cb.primary,
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
                            color: context.cb.primarySoft,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                // Rename affordance — opens a small dialog prefilled with the
                // current name so the caregiver can correct the coach's
                // auto-title or set their own (fb_1781115614890041 — "the
                // user should be able to update it").
                Semantics(
                  button: true,
                  label: 'Rename this chat.',
                  child: IconButton(
                    key: ConversationListScreen.renameIconKey(
                      item.conversation.id,
                    ),
                    tooltip: 'Rename chat',
                    icon: const Icon(Icons.edit_outlined),
                    color: context.cb.primarySoft,
                    onPressed: () => _rename(context, ref),
                  ),
                ),
                // Trailing trash affordance — same confirm-then-delete flow
                // as the long-press, for caregivers who'd rather tap a clear
                // target than discover the gesture (mirrors the medication
                // list's per-card trash icon).
                Semantics(
                  button: true,
                  label: 'Delete this chat.',
                  child: IconButton(
                    key: ConversationListScreen.deleteIconKey(
                      item.conversation.id,
                    ),
                    tooltip: 'Delete chat',
                    icon: const Icon(Icons.delete_outline),
                    color: context.cb.primarySoft,
                    onPressed: () => _confirmAndDelete(context, ref),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Prompt for a new thread name (prefilled with the current display
  /// title), then persist it as a custom title and refresh the list so the
  /// tile shows it immediately. Blank input or Cancel is a no-op — the
  /// existing name stays. The edited title is marked custom so a later
  /// auto-title pass never clobbers the caregiver's choice
  /// (fb_1781115614890041).
  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final String? next = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _RenameDialog(initial: item.displayTitle),
    );
    if (next == null || next.isEmpty) return;
    final ChatRepository repo = ref.read(chatRepositoryProvider);
    await repo.renameConversation(item.conversation.id, next);
    ref.invalidate(chatConversationListProvider);
  }

  /// Confirm, then hard-delete the conversation (its messages cascade via
  /// the FK). On confirm the list provider is invalidated so the tile drops
  /// immediately. Cancelling is a no-op — the thread stays put.
  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: ConversationListScreen.deleteDialogKey,
        title: const Text('Delete this chat?'),
        content: const Text(
          'This conversation and its messages will be removed. '
          'This can\'t be undone.',
        ),
        actions: <Widget>[
          TextButton(
            key: ConversationListScreen.deleteCancelKey,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: ConversationListScreen.deleteConfirmKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final ChatRepository repo = ref.read(chatRepositoryProvider);
    await repo.deleteConversation(item.conversation.id);
    ref.invalidate(chatConversationListProvider);
  }
}

/// Rename dialog for a chat thread (fb_1781115614890041). A
/// [StatefulWidget] so it owns the [TextEditingController]'s lifecycle —
/// disposing it in [dispose] (after the close animation) rather than in the
/// caller, which would tear it down mid-animation and crash the field.
/// Pops the trimmed new name on Save / submit, or null on Cancel.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: ConversationListScreen.renameDialogKey,
      title: const Text('Rename this chat'),
      content: TextField(
        key: ConversationListScreen.renameFieldKey,
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        maxLength: 60,
        decoration: const InputDecoration(
          labelText: 'Chat name',
          counterText: '',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          key: ConversationListScreen.renameCancelKey,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: ConversationListScreen.renameSaveKey,
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
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
        heroTag: 'conversations-quick-chat-fab',
        onPressed: onPressed,
        backgroundColor: context.cb.cta,
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
          style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
