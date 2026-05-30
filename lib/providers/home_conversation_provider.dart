import 'dart:math' as math;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/chat.dart';
import '../services/chat_repository.dart';

part 'home_conversation_provider.g.dart';

/// Resolves the conversation the Home tab renders into.
///
/// Behavior:
///   1. If at least one conversation exists, returns the freshest one
///      so the caregiver picks up where they left off.
///   2. Otherwise mints an empty "Today" conversation and returns it.
///
/// `keepAlive: true` because the Home tab re-watches this every time
/// it builds — without it the resolver would re-run on every tab
/// rebuild and risk creating a duplicate conversation under a Tab
/// switch race.
@Riverpod(keepAlive: true)
Future<Conversation> homeConversation(Ref ref) async {
  final ChatRepository repo = ref.watch(chatRepositoryProvider);
  final List<Conversation> existing = await repo.listConversations();
  if (existing.isNotEmpty) {
    return existing.first;
  }
  final DateTime now = DateTime.now();
  final String id =
      'conv-${now.millisecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}';
  return repo.createConversation(
    id: id,
    title: 'Today',
    createdAt: now,
  );
}
