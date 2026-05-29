import 'package:careblazers/models/chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageRole (TASKS.md Phase 11.1)', () {
    test('has the two values the spec names: user + assistant', () {
      expect(
        MessageRole.values,
        containsAll(<MessageRole>[
          MessageRole.user,
          MessageRole.assistant,
        ]),
      );
      expect(MessageRole.values, hasLength(2));
    });

    test('serializes to its Anthropic-compatible string name', () {
      final Message userMsg = Message(
        id: 'm-1',
        conversationId: 'c-1',
        role: MessageRole.user,
        body: 'hi',
        citations: const <String>[],
        createdAt: DateTime.utc(2026, 5, 29),
        streamingDone: true,
      );
      final Message asstMsg = userMsg.copyWith(role: MessageRole.assistant);
      expect(userMsg.toJson()['role'], 'user');
      expect(asstMsg.toJson()['role'], 'assistant');
    });
  });

  group('Conversation JSON round-trip', () {
    test('round-trips a freshly-created conversation', () {
      final Conversation original = Conversation(
        id: 'conv-001',
        title: 'what is sundowning?',
        createdAt: DateTime.utc(2026, 5, 29, 22, 13),
        updatedAt: DateTime.utc(2026, 5, 29, 22, 14),
      );
      expect(
        Conversation.fromJson(original.toJson()),
        equals(original),
      );
    });

    test('preserves a distinct updatedAt different from createdAt', () {
      final Conversation conv = Conversation(
        id: 'conv-002',
        title: 'asking for mom',
        createdAt: DateTime.utc(2026, 5, 28, 21, 0),
        updatedAt: DateTime.utc(2026, 5, 29, 8, 30),
      );
      final Conversation parsed = Conversation.fromJson(conv.toJson());
      expect(parsed.createdAt, DateTime.utc(2026, 5, 28, 21, 0));
      expect(parsed.updatedAt, DateTime.utc(2026, 5, 29, 8, 30));
    });
  });

  group('Message JSON round-trip', () {
    Message asstMsg({
      List<String> citations = const <String>[],
      bool streamingDone = true,
      String body = 'Sundowning is when the brain struggles in transition.',
    }) =>
        Message(
          id: 'msg-001',
          conversationId: 'conv-001',
          role: MessageRole.assistant,
          body: body,
          citations: citations,
          createdAt: DateTime.utc(2026, 5, 29, 22, 14),
          streamingDone: streamingDone,
        );

    test('round-trips a completed assistant message with no citations', () {
      final Message msg = asstMsg();
      expect(Message.fromJson(msg.toJson()), equals(msg));
    });

    test('round-trips a user-authored message', () {
      final Message msg = Message(
        id: 'msg-000',
        conversationId: 'conv-001',
        role: MessageRole.user,
        body: 'what is sundowning?',
        citations: const <String>[],
        createdAt: DateTime.utc(2026, 5, 29, 22, 13),
        streamingDone: true,
      );
      expect(Message.fromJson(msg.toJson()), equals(msg));
    });

    test('preserves a citations list with a single library card id', () {
      final Message msg = asstMsg(
        citations: const <String>['sundowning_basics'],
      );
      final Message parsed = Message.fromJson(msg.toJson());
      expect(parsed.citations, <String>['sundowning_basics']);
      expect(parsed, equals(msg));
    });

    test('preserves a citations list with multiple library card ids in order',
        () {
      final Message msg = asstMsg(
        citations: const <String>[
          'sundowning_basics',
          'respond_to_emotion',
          'five_causes',
        ],
      );
      final Message parsed = Message.fromJson(msg.toJson());
      expect(parsed.citations, <String>[
        'sundowning_basics',
        'respond_to_emotion',
        'five_causes',
      ]);
    });

    test('round-trips a streaming-in-flight assistant message', () {
      final Message msg = asstMsg(
        body: 'Sundowning is when',
        streamingDone: false,
      );
      final Message parsed = Message.fromJson(msg.toJson());
      expect(parsed.streamingDone, isFalse);
      expect(parsed.body, 'Sundowning is when');
    });

    test('streamingDone survives the round-trip as a real bool', () {
      final Message done = asstMsg();
      final Message inflight = asstMsg(streamingDone: false);
      expect(done.toJson()['streamingDone'], isTrue);
      expect(inflight.toJson()['streamingDone'], isFalse);
    });
  });
}
