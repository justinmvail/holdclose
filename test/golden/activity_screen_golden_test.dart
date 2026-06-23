import 'package:alchemist/alchemist.dart';
import 'package:holdclose/models/medication.dart' show DoseStatus;
import 'package:holdclose/screens/team/activity_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// 9 AM Mon Jun 1 2026 — the relative-time stamps are computed against this
/// fixed clock so the golden render stays deterministic.
DateTime _fixedNow() => DateTime(2026, 6, 1, 9, 0);

/// One row per category so the golden captures every dot hue (teal=dose,
/// plum=note, coral=appointment, blue=task, green=shift, navy=expense) and
/// the relative stamps, newest first.
List<ActivityFeedItem> _populated() => <ActivityFeedItem>[
      ActivityFeedItem(
        id: 'appt-1',
        category: ActivityCategory.appointment,
        summary: 'Appointment with Dr. Ortega',
        createdAt: _fixedNow().subtract(const Duration(minutes: 10)),
        route: '/appointments/1',
      ),
      ActivityFeedItem(
        id: 'note-1',
        category: ActivityCategory.note,
        summary: 'Sundowning',
        createdAt: _fixedNow().subtract(const Duration(minutes: 25)),
        route: '/journal/1',
      ),
      ActivityFeedItem(
        id: 'dose-window-morning',
        category: ActivityCategory.dose,
        summary: 'Morning medications',
        createdAt: _fixedNow().subtract(const Duration(hours: 2)),
        route: '/medications/today',
        doseWindow: const ActivityDoseWindow(
          windowLabel: 'Morning',
          meds: <ActivityDoseEntry>[
            ActivityDoseEntry(name: 'Donepezil 10 mg', status: DoseStatus.taken),
            ActivityDoseEntry(
                name: 'Metformin 500 mg', status: DoseStatus.skipped),
          ],
        ),
      ),
      ActivityFeedItem(
        id: 'task-1',
        category: ActivityCategory.task,
        summary: 'Completed Refill meds',
        createdAt: _fixedNow().subtract(const Duration(hours: 3)),
        route: '/team/tasks',
      ),
      ActivityFeedItem(
        id: 'shift-1',
        category: ActivityCategory.shift,
        summary: 'Maria took the morning shift',
        createdAt: _fixedNow().subtract(const Duration(hours: 5)),
        route: '/team/shifts',
      ),
      ActivityFeedItem(
        id: 'expense-1',
        category: ActivityCategory.expense,
        summary: 'Pharmacy \$24.00',
        createdAt: _fixedNow().subtract(const Duration(days: 1)),
        route: '/team/expenses',
      ),
    ];

Widget _host(List<ActivityFeedItem> items) {
  return ProviderScope(
    overrides: <Override>[
      teamActivityProvider.overrideWith((Ref ref) async => items),
      activityClockProvider.overrideWithValue(_fixedNow),
    ],
    child: SizedBox(
      width: 420,
      height: 940,
      child: MaterialApp(
        home: const ActivityScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('ActivityScreen golden', () {
    goldenTest(
      'renders a populated, multi-source feed',
      fileName: 'activity_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated feed (Phase 14.32)',
            child: _host(_populated()),
          ),
        ],
      ),
    );
  });
}
