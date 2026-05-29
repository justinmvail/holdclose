import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatRepository — TASKS.md Phase 11.2', () {
    late CareblazersDatabase db;
    late ChatRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = ChatRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    // ---- Conversation create + list ---------------------------------------

    test('createConversation persists the row and listConversations returns it',
        () async {
      final DateTime createdAt = DateTime.utc(2026, 5, 29, 19);
      final Conversation convo = await repo.createConversation(
        id: 'convo-001',
        title: 'What is sundowning?',
        createdAt: createdAt,
      );

      expect(convo.id, 'convo-001');
      expect(convo.createdAt, createdAt);
      expect(convo.updatedAt, createdAt);

      final List<Conversation> rows = await repo.listConversations();
      expect(rows, hasLength(1));
      expect(rows.single, equals(convo));
    });

    test('listConversations orders by updatedAt desc (freshest first)',
        () async {
      final DateTime base = DateTime.utc(2026, 5, 29, 19);
      await repo.createConversation(
        id: 'older',
        title: 'older convo',
        createdAt: base.subtract(const Duration(hours: 2)),
      );
      await repo.createConversation(
        id: 'newer',
        title: 'newer convo',
        createdAt: base,
      );

      final List<Conversation> rows = await repo.listConversations();
      expect(rows.map((Conversation c) => c.id).toList(),
          <String>['newer', 'older']);
    });

    // ---- Round-trip a 5-message conversation (task acceptance) ------------

    test('round-trips a 5-message conversation through append + load',
        () async {
      final DateTime base = DateTime.utc(2026, 5, 29, 19);
      await repo.createConversation(
        id: 'convo-roundtrip',
        title: 'sundowning chat',
        createdAt: base,
      );

      final List<Message> authored = <Message>[
        Message(
          id: 'msg-1',
          conversationId: 'convo-roundtrip',
          role: MessageRole.user,
          body: 'What is sundowning?',
          citations: const <String>[],
          createdAt: base.add(const Duration(seconds: 1)),
          streamingDone: true,
        ),
        Message(
          id: 'msg-2',
          conversationId: 'convo-roundtrip',
          role: MessageRole.assistant,
          body: "It's the late-afternoon shift many caregivers notice. "
              '[card:sundowning_basics]',
          citations: const <String>['sundowning_basics'],
          createdAt: base.add(const Duration(seconds: 2)),
          streamingDone: true,
        ),
        Message(
          id: 'msg-3',
          conversationId: 'convo-roundtrip',
          role: MessageRole.user,
          body: 'What can I do about it?',
          citations: const <String>[],
          createdAt: base.add(const Duration(seconds: 3)),
          streamingDone: true,
        ),
        Message(
          id: 'msg-4',
          conversationId: 'convo-roundtrip',
          role: MessageRole.assistant,
          body: 'Try dimming the lights an hour earlier. '
              '[card:respond_to_emotion]',
          citations: const <String>['respond_to_emotion'],
          createdAt: base.add(const Duration(seconds: 4)),
          streamingDone: true,
        ),
        Message(
          id: 'msg-5',
          conversationId: 'convo-roundtrip',
          role: MessageRole.user,
          body: 'Thank you.',
          citations: const <String>[],
          createdAt: base.add(const Duration(seconds: 5)),
          streamingDone: true,
        ),
      ];

      for (final Message m in authored) {
        await repo.appendMessage(m);
      }

      final List<Message> loaded =
          await repo.loadMessages('convo-roundtrip');
      expect(loaded, hasLength(5));
      // Chronological order — same shape we authored in.
      expect(loaded, equals(authored));
      // Roles + citations round-tripped.
      expect(loaded[1].role, MessageRole.assistant);
      expect(loaded[1].citations, <String>['sundowning_basics']);
      expect(loaded[3].citations, <String>['respond_to_emotion']);
      expect(loaded.where((Message m) => m.role == MessageRole.user).length,
          3);
    });

    test('appendMessage bumps the parent conversation updatedAt', () async {
      final DateTime createdAt = DateTime.utc(2026, 5, 29, 19);
      await repo.createConversation(
        id: 'convo-bump',
        title: 'bump test',
        createdAt: createdAt,
      );

      final DateTime msgAt = createdAt.add(const Duration(minutes: 5));
      await repo.appendMessage(Message(
        id: 'bump-msg',
        conversationId: 'convo-bump',
        role: MessageRole.user,
        body: 'hello',
        citations: const <String>[],
        createdAt: msgAt,
        streamingDone: true,
      ));

      final Conversation reloaded =
          (await repo.listConversations()).single;
      expect(reloaded.updatedAt, msgAt);
      // createdAt is unchanged.
      expect(reloaded.createdAt, createdAt);
    });

    test('appendMessage is idempotent — same id overwrites in place',
        () async {
      // Streaming the assistant's reply hits this code path many times
      // for the same message id as the body accumulates.
      final DateTime base = DateTime.utc(2026, 5, 29, 19);
      await repo.createConversation(
        id: 'stream-convo',
        title: 'stream test',
        createdAt: base,
      );

      Message buildStream({
        required String body,
        required bool done,
      }) =>
          Message(
            id: 'streaming-msg',
            conversationId: 'stream-convo',
            role: MessageRole.assistant,
            body: body,
            citations: const <String>[],
            createdAt: base.add(const Duration(seconds: 1)),
            streamingDone: done,
          );

      await repo.appendMessage(buildStream(body: 'Hello', done: false));
      await repo.appendMessage(buildStream(body: 'Hello there', done: false));
      await repo.appendMessage(buildStream(
        body: 'Hello there, Careblazer.',
        done: true,
      ));

      final List<Message> loaded = await repo.loadMessages('stream-convo');
      expect(loaded, hasLength(1));
      expect(loaded.single.body, 'Hello there, Careblazer.');
      expect(loaded.single.streamingDone, isTrue);
    });

    // ---- Cascade delete (task acceptance) ---------------------------------

    test('deleteConversation cascades — zero orphan messages survive',
        () async {
      final DateTime base = DateTime.utc(2026, 5, 29, 19);
      await repo.createConversation(
        id: 'will-die',
        title: 'doomed',
        createdAt: base,
      );
      await repo.createConversation(
        id: 'will-live',
        title: 'survivor',
        createdAt: base,
      );

      // Five messages on the doomed conversation, one on the survivor.
      for (int i = 0; i < 5; i++) {
        await repo.appendMessage(Message(
          id: 'doomed-$i',
          conversationId: 'will-die',
          role: i.isEven ? MessageRole.user : MessageRole.assistant,
          body: 'doomed message $i',
          citations: const <String>[],
          createdAt: base.add(Duration(seconds: i)),
          streamingDone: true,
        ));
      }
      await repo.appendMessage(Message(
        id: 'survivor-msg',
        conversationId: 'will-live',
        role: MessageRole.user,
        body: 'still here',
        citations: const <String>[],
        createdAt: base.add(const Duration(seconds: 99)),
        streamingDone: true,
      ));

      // Sanity: messages are wired to their conversations.
      expect(await repo.loadMessages('will-die'), hasLength(5));
      expect(await repo.loadMessages('will-live'), hasLength(1));

      await repo.deleteConversation('will-die');

      // The conversation is gone.
      final List<Conversation> remaining = await repo.listConversations();
      expect(remaining.map((Conversation c) => c.id).toList(),
          <String>['will-live']);

      // Its messages cascaded — zero orphans.
      expect(await repo.loadMessages('will-die'), isEmpty);
      // The query above is filtered; verify against the raw table too so
      // a stale ORDER BY doesn't hide orphans.
      final int orphanRowCount =
          (await db.select(db.chatMessagesTable).get())
              .where((ChatMessagesTableData r) =>
                  r.conversationId == 'will-die')
              .length;
      expect(orphanRowCount, 0,
          reason: 'ON DELETE CASCADE must remove every message row');

      // And the survivor is untouched.
      expect(await repo.loadMessages('will-live'), hasLength(1));
    });

    test('deleteConversation on an unknown id is a silent no-op', () async {
      await repo.deleteConversation('never-existed');
      expect(await repo.listConversations(), isEmpty);
    });

    // ---- loadMessages scoping --------------------------------------------

    test('loadMessages returns only the requested thread', () async {
      final DateTime base = DateTime.utc(2026, 5, 29, 19);
      await repo.createConversation(
        id: 'a',
        title: 'thread A',
        createdAt: base,
      );
      await repo.createConversation(
        id: 'b',
        title: 'thread B',
        createdAt: base,
      );

      await repo.appendMessage(Message(
        id: 'a-1',
        conversationId: 'a',
        role: MessageRole.user,
        body: 'belongs to A',
        citations: const <String>[],
        createdAt: base.add(const Duration(seconds: 1)),
        streamingDone: true,
      ));
      await repo.appendMessage(Message(
        id: 'b-1',
        conversationId: 'b',
        role: MessageRole.user,
        body: 'belongs to B',
        citations: const <String>[],
        createdAt: base.add(const Duration(seconds: 2)),
        streamingDone: true,
      ));

      final List<Message> a = await repo.loadMessages('a');
      expect(a.map((Message m) => m.id).toList(), <String>['a-1']);

      final List<Message> b = await repo.loadMessages('b');
      expect(b.map((Message m) => m.id).toList(), <String>['b-1']);
    });
  });
}
