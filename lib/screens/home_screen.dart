import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/chat.dart';
import '../providers/home_conversation_provider.dart';
import '../routing/router.dart';
import '../theme.dart';
import 'chat/chat_screen.dart';

/// Home tab root — the primary chat thread with the coach.
///
/// Resolves the freshest conversation (or creates one) via
/// [homeConversationProvider] and mounts [ChatScreen] against it with
/// a tab-root AppBar: title "Today", settings gear (push `/settings`),
/// history button (push `/chat`), new-thread button (creates a fresh
/// conversation + invalidates the resolver).
///
/// The "Log a journal entry" quick action sits above the input
/// composer via [ChatScreen.composerPrefix] — caregivers who want to
/// log a moment without going through the coach's natural-language
/// path get a direct button.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const Key settingsGearKey = Key('home-settings-gear');
  static const Key historyButtonKey = Key('home-history');
  static const Key newConversationKey = Key('home-new-conversation');
  static const Key journalQuickActionKey = Key('home-journal-quick-action');
  static const Key loadingKey = Key('home-loading');
  static const Key errorKey = Key('home-error');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Conversation> conv = ref.watch(homeConversationProvider);
    return conv.when(
      loading: () => Scaffold(
        backgroundColor: careblazersColors.background,
        appBar: _homeAppBar(context, ref),
        body: const Center(
          key: loadingKey,
          child: CircularProgressIndicator(),
        ),
      ),
      error: (Object e, _) => Scaffold(
        backgroundColor: careblazersColors.background,
        appBar: _homeAppBar(context, ref),
        body: Center(
          key: errorKey,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              "Couldn't open the chat. Pull to retry — $e",
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
      data: (Conversation conversation) => ChatScreen(
        // ValueKey re-mounts ChatScreen when the underlying
        // conversation flips — the "new conversation" AppBar action
        // invalidates [homeConversationProvider], a new id lands here,
        // and the chat state (messages, scroll, composer) resets to
        // empty without us threading a reset signal through ChatScreen.
        key: ValueKey<String>('home-chat-${conversation.id}'),
        conversationId: conversation.id,
        appBarOverride: _homeAppBar(context, ref),
        composerPrefix: _JournalQuickAction(
          onTap: () => GoRouter.of(context)
              .pushNamed(CareblazersRoutes.journalNew),
        ),
      ),
    );
  }

  PreferredSizeWidget _homeAppBar(BuildContext context, WidgetRef ref) {
    return AppBar(
      title: const Text('Today'),
      automaticallyImplyLeading: false,
      actions: <Widget>[
        IconButton(
          key: historyButtonKey,
          icon: const Icon(Icons.history),
          tooltip: 'Past chats',
          onPressed: () => GoRouter.of(context).push('/chat'),
        ),
        IconButton(
          key: newConversationKey,
          icon: const Icon(Icons.add_comment_outlined),
          tooltip: 'Start a new chat',
          onPressed: () => ref.invalidate(homeConversationProvider),
        ),
        IconButton(
          key: settingsGearKey,
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Settings',
          onPressed: () => GoRouter.of(context).push('/settings'),
        ),
      ],
    );
  }
}

class _JournalQuickAction extends StatelessWidget {
  const _JournalQuickAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          key: HomeScreen.journalQuickActionKey,
          color: careblazersColors.surfaceWarm,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.bookmark_add_outlined,
                    size: 18,
                    color: careblazersColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Log a journal entry',
                      style: textTheme.labelLarge?.copyWith(
                        color: careblazersColors.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
