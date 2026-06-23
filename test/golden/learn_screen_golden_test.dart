import 'package:alchemist/alchemist.dart';
import 'package:holdclose/screens/community/learn_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(double height) {
  return ProviderScope(
    child: SizedBox(
      width: 420,
      height: height,
      child: MaterialApp(
        home: const Scaffold(body: SafeArea(child: LearnScreen())),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('LearnScreen golden', () {
    goldenTest(
      'renders the videos + playbooks library',
      fileName: 'learn_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'library (Phase 14.37)',
            child: _host(1500),
          ),
        ],
      ),
    );
  });
}
