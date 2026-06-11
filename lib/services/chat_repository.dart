import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/chat.dart';
import 'sync_sink.dart';

part 'chat_repository.g.dart';

/// Persistence for the dementia-care chatbot (TASKS.md Phase 11.2).
///
/// Wraps the two drift tables [ChatConversationsTable] and
/// [ChatMessagesTable] behind the five methods the chat screens
/// (Phase 11.4) and [ChatService] (Phase 11.3) consume:
///
///   - [createConversation] inserts an empty thread the next
///     [appendMessage] call will populate.
///   - [appendMessage] writes one turn and bumps the parent
///     conversation's `updatedAt` so the list screen can sort by
///     most-recent activity.
///   - [listConversations] returns every thread, freshest first.
///   - [loadMessages] returns one thread's messages in chronological
///     order.
///   - [deleteConversation] drops the row; the FK's `ON DELETE
///     CASCADE` removes its messages atomically so the repository
///     never leaves orphans behind (verified by the
///     `cascade-delete` test).
///
/// Each freezed model serialises to its `toJson` shape and parks in
/// the row's `payload` column — same blob-with-lifted-keys pattern
/// [DriftStorageProvider] uses for [JournalEntry], so new fields on
/// [Conversation] / [Message] persist without a schema bump.
class ChatRepository with SyncSinkHost {
  ChatRepository(this._db);

  final CareblazersDatabase _db;

  /// Insert a fresh empty conversation. [title] is the first user
  /// message's first 60 chars in production (per Phase 11.4 spec) but
  /// the repository doesn't enforce that — callers pass whatever
  /// label belongs on the list-screen tile.
  Future<Conversation> createConversation({
    required String id,
    required String title,
    required DateTime createdAt,
  }) async {
    final Conversation convo = Conversation(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await _db.into(_db.chatConversationsTable).insertOnConflictUpdate(
          ChatConversationsTableCompanion.insert(
            id: convo.id,
            createdAtMs: convo.createdAt.millisecondsSinceEpoch,
            updatedAtMs: convo.updatedAt.millisecondsSinceEpoch,
            payload: jsonEncode(convo.toJson()),
          ),
        );
    emitUpsert('chat_conversations', convo.id, convo.toJson());
    return convo;
  }

  /// Insert-or-replace [message] and bump the parent conversation's
  /// `updatedAt` to [message.createdAt] in the same transaction.
  ///
  /// Streaming assistant replies hit this method many times for the
  /// same `message.id` as the body accumulates — `insertOnConflictUpdate`
  /// keeps that path cheap (one row, repeatedly overwritten) without
  /// the caller having to track insert-vs-update state.
  Future<void> appendMessage(Message message) async {
    Conversation? bumpedConvo;
    await _db.transaction(() async {
      await _db.into(_db.chatMessagesTable).insertOnConflictUpdate(
            ChatMessagesTableCompanion.insert(
              id: message.id,
              conversationId: message.conversationId,
              createdAtMs: message.createdAt.millisecondsSinceEpoch,
              payload: jsonEncode(message.toJson()),
            ),
          );
      final ChatConversationsTableData? row =
          await (_db.select(_db.chatConversationsTable)
                ..where((t) => t.id.equals(message.conversationId)))
              .getSingleOrNull();
      if (row != null) {
        final Conversation convo = Conversation.fromJson(
          jsonDecode(row.payload) as Map<String, dynamic>,
        );
        final Conversation bumped =
            convo.copyWith(updatedAt: message.createdAt);
        await (_db.update(_db.chatConversationsTable)
              ..where((t) => t.id.equals(bumped.id)))
            .write(
          ChatConversationsTableCompanion(
            updatedAtMs:
                Value<int>(bumped.updatedAt.millisecondsSinceEpoch),
            payload: Value<String>(jsonEncode(bumped.toJson())),
          ),
        );
        bumpedConvo = bumped;
      }
    });
    // Emit after the transaction commits so a sync push can never observe
    // a half-applied write. Both the message and the bumped parent
    // conversation are synced so the other device sees the same thread
    // ordering.
    emitUpsert('chat_messages', message.id, message.toJson());
    if (bumpedConvo != null) {
      emitUpsert(
          'chat_conversations', bumpedConvo!.id, bumpedConvo!.toJson());
    }
  }

  /// Every conversation, freshest activity first. Tiles in the
  /// conversation-list screen (Phase 11.4) render in this order.
  Future<List<Conversation>> listConversations() async {
    final List<ChatConversationsTableData> rows =
        await (_db.select(_db.chatConversationsTable)
              ..orderBy(<OrderClauseGenerator<$ChatConversationsTableTable>>[
                (t) => OrderingTerm(
                      expression: t.updatedAtMs,
                      mode: OrderingMode.desc,
                    ),
              ]))
            .get();
    return rows
        .map((ChatConversationsTableData r) => Conversation.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  /// Load a single conversation row by id, or null when it's gone.
  /// Used by [ChatService] to check whether a thread already carries a
  /// caregiver-set title before it auto-generates one, and by the rename
  /// flow to read the current name into the edit field.
  Future<Conversation?> getConversation(String conversationId) async {
    final ChatConversationsTableData? row =
        await (_db.select(_db.chatConversationsTable)
              ..where((t) => t.id.equals(conversationId)))
            .getSingleOrNull();
    if (row == null) return null;
    return Conversation.fromJson(
      jsonDecode(row.payload) as Map<String, dynamic>,
    );
  }

  /// Set a thread's display [title] and mark it [customTitle] so the list
  /// screen renders it verbatim instead of re-deriving from the first
  /// message. Used both by the coach's post-first-exchange auto-title and
  /// the caregiver's manual rename (fb_1781115614890041). A no-op when the
  /// thread is gone. `updatedAt` is left untouched — a rename is not new
  /// activity and must not jump the thread to the top of the list.
  Future<void> renameConversation(
    String conversationId,
    String title, {
    bool custom = true,
  }) async {
    // Read-modify-write wrapped in ONE transaction so it's atomic on the
    // shared connection — a concurrent sync-apply (or another local write)
    // can't land between the read and the write and get clobbered (lost
    // update). Emit only AFTER the commit, like appendMessage.
    Conversation? renamed;
    await _db.transaction(() async {
      final Conversation? existing = await getConversation(conversationId);
      if (existing == null) return;
      renamed = existing.copyWith(title: title, customTitle: custom);
      await (_db.update(_db.chatConversationsTable)
            ..where((t) => t.id.equals(conversationId)))
          .write(
        ChatConversationsTableCompanion(
          payload: Value<String>(jsonEncode(renamed!.toJson())),
        ),
      );
    });
    final Conversation? committed = renamed;
    if (committed != null) {
      emitUpsert('chat_conversations', committed.id, committed.toJson());
    }
  }

  /// Messages for [conversationId], oldest first — the order the
  /// chat screen renders them top-to-bottom.
  Future<List<Message>> loadMessages(String conversationId) async {
    final List<ChatMessagesTableData> rows =
        await (_db.select(_db.chatMessagesTable)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy(<OrderClauseGenerator<$ChatMessagesTableTable>>[
                (t) => OrderingTerm(
                      expression: t.createdAtMs,
                      mode: OrderingMode.asc,
                    ),
              ]))
            .get();
    return rows
        .map((ChatMessagesTableData r) => Message.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  /// Insert-or-replace a whole [convo] by id, preserving its timestamps.
  /// Used by the sync apply dispatcher to land a *pulled* conversation
  /// (the public [createConversation] resets `updatedAt` to `createdAt`,
  /// which would clobber the remote's activity ordering). Emits an upsert
  /// like any other write — suppressed under [applyingRemote] so it
  /// doesn't bounce back to the server.
  Future<void> applyConversation(Conversation convo) async {
    await _db.into(_db.chatConversationsTable).insertOnConflictUpdate(
          ChatConversationsTableCompanion.insert(
            id: convo.id,
            createdAtMs: convo.createdAt.millisecondsSinceEpoch,
            updatedAtMs: convo.updatedAt.millisecondsSinceEpoch,
            payload: jsonEncode(convo.toJson()),
          ),
        );
    emitUpsert('chat_conversations', convo.id, convo.toJson());
  }

  /// Drop a single message row by id (no cascade). Used by the sync apply
  /// dispatcher for a pulled message tombstone.
  Future<void> deleteMessage(String messageId) async {
    await (_db.delete(_db.chatMessagesTable)
          ..where((t) => t.id.equals(messageId)))
        .go();
    emitDelete('chat_messages', messageId);
  }

  /// Drop the thread row. The FK's `ON DELETE CASCADE` removes the
  /// thread's messages in the same statement, so the repository
  /// never has to chase them down explicitly — and a partial failure
  /// can't leave orphan rows behind.
  Future<void> deleteConversation(String conversationId) async {
    await (_db.delete(_db.chatConversationsTable)
          ..where((t) => t.id.equals(conversationId)))
        .go();
    // Tombstone the conversation. Its messages cascade-delete locally;
    // the remote conversation tombstone hides the thread on every device.
    emitDelete('chat_conversations', conversationId);
  }
}

/// Riverpod-wired singleton (Phase 11.2). The chat screens + service
/// reach for [chatRepositoryProvider] and never see the concrete
/// drift database, mirroring how every other service in the app
/// reads through its provider alias.
///
/// In production the repo opens its own [CareblazersDatabase] handle
/// onto the same SQLite file [DriftStorageProvider] uses — SQLite's
/// per-connection serialization keeps that safe — and disposes the
/// handle when the provider is torn down. Tests build a
/// [ChatRepository] directly against `CareblazersDatabase(NativeDatabase
/// .memory())` so each test gets an isolated DB.
///
/// Named `chatRepositoryBackend` so the generated class is
/// [ChatRepositoryBackendProvider], leaving room for the
/// natural-language [chatRepositoryProvider] alias below — same
/// pattern [seedRepositoryProvider] uses.
@Riverpod(keepAlive: true)
ChatRepository chatRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return ChatRepository(db);
}

/// Alias for consumers — matches the `chatRepositoryProvider` name
/// the chat screens and [ChatService] reach for.
final ChatRepositoryBackendProvider chatRepositoryProvider =
    chatRepositoryBackendProvider;
