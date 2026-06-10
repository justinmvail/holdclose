import 'package:freezed_annotation/freezed_annotation.dart';

part 'chat.freezed.dart';
part 'chat.g.dart';

/// Who authored a [Message] in a chat [Conversation]
/// (BUILD_SPEC.md / TASKS.md Phase 11.1).
///
/// Two values: caregiver-typed input ([user]) and the streamed
/// Dr. Natali-voiced coach reply ([assistant]). The string names match
/// the Anthropic / Claude CLI role vocabulary so the
/// [ChatService] (TASKS.md Phase 11.3) can pass them through to the
/// LLM without translation.
enum MessageRole {
  user,
  assistant,
}

/// A single dementia-care chat thread persisted in drift
/// (TASKS.md Phase 11.1 + 11.2).
///
/// [title] is the thread's display name. By default the list screen
/// DERIVES a succinct name from the first user message; once the coach
/// generates a real title after the first exchange, or the caregiver
/// renames the thread, that text is stored in [title] and [customTitle]
/// flips true so the derived name no longer wins (fb_1781115614890041 —
/// "make a succinct title with ai … the user should be able to update it").
/// [createdAt] is set at insert; [updatedAt] is bumped each time a
/// new [Message] is appended so the conversation list can sort by
/// recency.
@freezed
abstract class Conversation with _$Conversation {
  const factory Conversation({
    required String id,
    required String title,
    required DateTime createdAt,
    required DateTime updatedAt,
    // True once [title] holds an explicit name — coach-generated after the
    // first exchange OR caregiver-edited — so the list tile shows it
    // verbatim instead of re-deriving from the first message. Defaults
    // false (older rows + freshly-created threads) so the derived succinct
    // title remains the fallback. JSON-optional → no schema bump.
    @Default(false) bool customTitle,
  }) = _Conversation;

  factory Conversation.fromJson(Map<String, dynamic> json) =>
      _$ConversationFromJson(json);
}

/// One turn in a [Conversation] — either a caregiver question or the
/// assistant's streamed reply (TASKS.md Phase 11.1 + 11.3).
///
/// [body] accumulates token-by-token while the LLM streams; once the
/// final chunk arrives [streamingDone] flips to true and
/// [ChatService] parses `[card:<id>]` markers in [body] into
/// [citations] (a list of library card IDs the assistant cited per
/// Phase 11.5). User-authored messages always have [streamingDone]
/// true and an empty [citations] list.
@freezed
abstract class Message with _$Message {
  const factory Message({
    required String id,
    required String conversationId,
    required MessageRole role,
    required String body,
    required List<String> citations,
    required DateTime createdAt,
    required bool streamingDone,
  }) = _Message;

  factory Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);
}
