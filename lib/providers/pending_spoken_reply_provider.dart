import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pending_spoken_reply_provider.g.dart';

/// A one-shot hand-off slot for a coach reply the destination [ChatScreen]
/// should READ ALOUD the moment it first builds.
///
/// The hands-free center mic used to speak the reply itself and THEN navigate to
/// the thread. But the mic's voice engine and the chat screen's share one native
/// synthesizer, so navigating into the thread (which disposes whatever screen you
/// came from, and that dispose cancels the shared engine) cut the reply off
/// mid-sentence — reported 2026-07-14 ("navigated here automatically cutting off
/// the voice playback").
///
/// The fix is single ownership: the mic parks the reply here and navigates; the
/// destination chat screen picks it up on first build and speaks it. Now exactly
/// one screen owns the utterance — leaving that thread stops it (correct), and
/// arriving at it starts it (no cutoff).
///
/// Keyed by conversation id so a stale entry can't leak into the wrong thread,
/// and `keepAlive` so it survives the rebuilds between the tap and the chat
/// screen's first build. Mirrors [PendingChatMessage].
@Riverpod(keepAlive: true)
class PendingSpokenReply extends _$PendingSpokenReply {
  @override
  ({String conversationId, String text})? build() => null;

  /// Park [text] to be spoken when [conversationId]'s screen first builds.
  void set(String conversationId, String text) =>
      state = (conversationId: conversationId, text: text);

  /// Take and clear the pending reply for [conversationId], or null when
  /// nothing is waiting. Idempotent, so the read-aloud fires exactly once.
  String? take(String conversationId) {
    final ({String conversationId, String text})? pending = state;
    if (pending == null || pending.conversationId != conversationId) {
      return null;
    }
    state = null;
    return pending.text;
  }
}
