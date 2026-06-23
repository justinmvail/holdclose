import 'package:alchemist/alchemist.dart';
import 'package:holdclose/models/forum.dart';
import 'package:holdclose/providers/my_forum_profile_provider.dart';
import 'package:holdclose/screens/team/care_circle_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

CircleMemberDto _member({
  required String profileId,
  required String username,
  required String displayName,
  String role = 'member',
}) =>
    CircleMemberDto(
      profileId: profileId,
      username: username,
      displayName: displayName,
      role: role,
    );

List<CircleMemberDto> _members() => <CircleMemberDto>[
      _member(
        profileId: 'p1',
        username: 'sarah_h',
        displayName: 'Sarah Henderson',
        role: 'owner',
      ),
      _member(
        profileId: 'p2',
        username: 'james_h',
        displayName: 'James Henderson',
      ),
      _member(
        profileId: 'p3',
        username: 'maria_l',
        displayName: 'Maria Lopez',
      ),
    ];

Widget _host(List<CircleMemberDto> members, double height) {
  return ProviderScope(
    overrides: <Override>[
      syncedCircleMembersProvider.overrideWith(
          (Ref ref) => Stream<List<CircleMemberDto>>.value(members)),
      myForumProfileIdProvider.overrideWithValue('p1'),
    ],
    child: SizedBox(
      width: 440,
      height: height,
      child: MaterialApp(
        home: const CareCircleScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('CareCircleScreen golden', () {
    goldenTest(
      'renders the populated care circle',
      fileName: 'care_circle_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (backend members)',
            child: _host(_members(), 720),
          ),
        ],
      ),
    );

    goldenTest(
      'renders the empty care circle',
      fileName: 'care_circle_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (no one else yet)',
            child: _host(const <CircleMemberDto>[], 620),
          ),
        ],
      ),
    );
  });
}
