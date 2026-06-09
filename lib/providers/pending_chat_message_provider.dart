import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pending_chat_message_provider.g.dart';

/// A one-shot hand-off slot for a chat message that should be sent the
/// moment its conversation's [ChatScreen] first builds.
///
/// The center voice button in [TabScaffold] captures one spoken phrase,
/// mints a fresh conversation, parks the transcript here keyed by the new
/// conversation id, then navigates to `/chat/<id>`. The chat screen reads
/// this on first build; if a pending message is waiting for ITS
/// conversation it dispatches it as the first user turn and clears the
/// slot so a later rebuild (or a different thread) never re-sends it.
///
/// Keyed by conversation id so a stale entry can never leak into the
/// wrong thread: a screen only consumes a pending message whose key
/// matches its own [conversationId]. `keepAlive` so the value survives
/// the rebuilds the navigation triggers between the tap and the chat
/// screen's first build.
@Riverpod(keepAlive: true)
class PendingChatMessage extends _$PendingChatMessage {
  @override
  ({String conversationId, String text})? build() => null;

  /// Park [text] to be auto-sent as the first turn of [conversationId].
  void set(String conversationId, String text) =>
      state = (conversationId: conversationId, text: text);

  /// Take and clear the pending message for [conversationId], or null
  /// when nothing is waiting for that thread. Idempotent — a second call
  /// returns null, so the auto-send fires exactly once.
  String? take(String conversationId) {
    final ({String conversationId, String text})? pending = state;
    if (pending == null || pending.conversationId != conversationId) {
      return null;
    }
    state = null;
    return pending.text;
  }
}
