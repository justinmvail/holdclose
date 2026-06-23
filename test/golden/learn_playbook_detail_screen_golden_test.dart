import 'package:alchemist/alchemist.dart';
import 'package:holdclose/screens/community/learn_playbook_detail_screen.dart';
import 'package:holdclose/seed/learn_content.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(String playbookId, double height) {
  return ProviderScope(
    child: SizedBox(
      width: 420,
      height: height,
      child: MaterialApp(
        home: LearnPlaybookDetailScreen(playbookId: playbookId),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('LearnPlaybookDetailScreen golden', () {
    goldenTest(
      'renders the ordered step cards',
      fileName: 'learn_playbook_detail_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'steps (Phase 14.37)',
            child: _host(learnPlaybooks.first.id, 900),
          ),
        ],
      ),
    );
  });
}
