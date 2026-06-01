import 'package:alchemist/alchemist.dart';
import 'package:careblazers/screens/community/learn_video_detail_screen.dart';
import 'package:careblazers/seed/learn_content.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(String videoId, double height) {
  return ProviderScope(
    child: SizedBox(
      width: 420,
      height: height,
      child: MaterialApp(
        home: LearnVideoDetailScreen(videoId: videoId),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('LearnVideoDetailScreen golden', () {
    goldenTest(
      'renders the soft video placeholder',
      fileName: 'learn_video_detail_screen',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'placeholder (Phase 14.37)',
            child: _host(learnVideos.first.id, 760),
          ),
        ],
      ),
    );
  });
}
