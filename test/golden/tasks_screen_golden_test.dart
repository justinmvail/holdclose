import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/screens/team/tasks_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';
const String _me = 'demo-caregiver-me';
final DateTime _clock = DateTime.utc(2026, 6, 1, 12);

const Caregiver _maria = Caregiver(
  id: 'maria',
  displayName: 'Maria Lopez',
  role: CaregiverRole.aide,
);

// One card per state so segment-cycling shows a representative board.
List<CareTaskCard> _cards() => <CareTaskCard>[
      CareTaskCard(
        task: CareTask(
          id: 'open1',
          title: 'Pick up the new prescription',
          body: 'Pharmacy on Oak St has it ready after 3 PM.',
          dueAt: DateTime(2026, 6, 2, 15),
          patientId: _patientId,
        ),
      ),
      CareTaskCard(
        task: CareTask(
          id: 'claimed1',
          title: 'Drive Mom to her neurology visit',
          dueAt: DateTime(2026, 6, 4, 8, 30),
          assigneeCaregiverId: _me,
          claimedAt: _clock,
          patientId: _patientId,
        ),
      ),
      CareTaskCard(
        task: CareTask(
          id: 'claimed2',
          title: 'Refill the weekly pill organizer',
          assigneeCaregiverId: 'maria',
          claimedAt: _clock,
          patientId: _patientId,
        ),
        assignee: _maria,
      ),
      CareTaskCard(
        task: CareTask(
          id: 'done1',
          title: 'Call the insurance company',
          assigneeCaregiverId: _me,
          claimedAt: _clock,
          completedAt: _clock,
          patientId: _patientId,
        ),
      ),
    ];

Widget _host() {
  return ProviderScope(
    overrides: <Override>[
      careTasksViewProvider.overrideWith((Ref ref) async => _cards()),
      currentCaregiverIdProvider.overrideWithValue(_me),
    ],
    child: SizedBox(
      width: 460,
      height: 820,
      child: MaterialApp(
        home: const TasksScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

/// Tap a segment pill once, settling so the filtered board renders before
/// the golden is captured.
PumpAction _selectSegment(CareTaskStatus status) {
  return (WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(TasksScreen.segmentKey(status)));
    await tester.pumpAndSettle();
  };
}

void main() {
  group('TasksScreen golden', () {
    goldenTest(
      'open board — Claim actions',
      fileName: 'tasks_screen_open',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'open (Phase 14.30)',
            child: _host(),
          ),
        ],
      ),
    );

    goldenTest(
      'claimed board — Complete + Unclaim on my task',
      fileName: 'tasks_screen_claimed',
      pumpBeforeTest: _selectSegment(CareTaskStatus.claimed),
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'claimed (Phase 14.30)',
            child: _host(),
          ),
        ],
      ),
    );

    goldenTest(
      'done board — no actions',
      fileName: 'tasks_screen_done',
      pumpBeforeTest: _selectSegment(CareTaskStatus.done),
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'done (Phase 14.30)',
            child: _host(),
          ),
        ],
      ),
    );
  });
}
