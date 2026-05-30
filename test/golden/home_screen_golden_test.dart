import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/chat.dart';
import 'package:careblazers/providers/home_conversation_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/services/chat_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// CI-only golden of [HomeScreen] in its default state — Home tab
/// root, no decoder push in flight. Wrapped in the real router so the
/// AppBar gear and secondary rows render in the same shell they ship
/// in.
///
/// We deliberately pump via the router rather than dropping a bare
/// `HomeScreen` widget so the golden catches regressions in the
/// shell-level layout (back-button suppression on the tab root, gear
/// placement in actions).
void main() {
  group('HomeScreen golden', () {
    goldenTest(
      'renders the primary tap target + secondary rows',
      fileName: 'home_screen_default',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'default (Home tab root)',
            // TabScaffold (Phase 12.8) watches settingsProvider to
            // pick which tabs to show — settingsProvider hydrates
            // off storageProvider, which would otherwise reach for
            // the on-device sqlite file. The in-memory override
            // keeps the golden hermetic.
            child: ProviderScope(
              overrides: <Override>[
                storageBackendProvider.overrideWithValue(
                  InMemoryStorageProvider(),
                ),
                // Home tab resolves the chat conversation off this
                // provider; stub it so the golden never blocks on
                // drift.
                homeConversationProvider.overrideWith((_) async =>
                    Conversation(
                      id: 'golden-conv',
                      title: 'Today',
                      createdAt: DateTime.utc(2026, 5, 30, 12),
                      updatedAt: DateTime.utc(2026, 5, 30, 12),
                    )),
                chatRepositoryProvider.overrideWith((Ref _) {
                  final CareblazersDatabase db =
                      CareblazersDatabase(NativeDatabase.memory());
                  return ChatRepository(db);
                }),
              ],
              child: SizedBox(
                width: 390,
                height: 780,
                child: MaterialApp.router(
                  routerConfig: buildRouter(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.surfaceWarm,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}
