import 'package:alchemist/alchemist.dart';
import 'package:holdclose/models/care_shift.dart';
import 'package:holdclose/models/caregiver.dart';
import 'package:holdclose/providers/care_shifts_provider.dart';
import 'package:holdclose/screens/team/shifts_screen.dart';
import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

const List<Caregiver> _roster = <Caregiver>[
  Caregiver(id: 'maria', displayName: 'Maria Lopez', role: CaregiverRole.aide),
  Caregiver(id: 'james', displayName: 'James Park', role: CaregiverRole.child),
  Caregiver(id: 'ana', displayName: 'Ana Reyes', role: CaregiverRole.spouse),
];

CareShift _shift({
  required String id,
  required String caregiverId,
  required DateTime start,
  required DateTime end,
}) =>
    CareShift(
      id: id,
      caregiverId: caregiverId,
      start: start,
      end: end,
      patientId: _patientId,
    );

DateTime _at(int dayOffset, int hour) =>
    DateTime(2026, 6, 1 + dayOffset, hour);

/// One day's coverage built from [shifts] via the real folding helper, so
/// the golden exercises the same math the screen ships with.
DayCoverage _day(int dayOffset, List<CareShift> shifts) =>
    coverageFor(shifts, _at(dayOffset, 0));

/// A fully-covered lead day (three caregivers handing off cleanly) followed
/// by lighter days.
List<DayCoverage> _coveredWeek() => <DayCoverage>[
      _day(0, <CareShift>[
        _shift(id: 'a', caregiverId: 'ana', start: _at(0, 0), end: _at(0, 8)),
        _shift(
            id: 'b', caregiverId: 'maria', start: _at(0, 8), end: _at(0, 16)),
        _shift(
            id: 'c', caregiverId: 'james', start: _at(0, 16), end: _at(1, 0)),
      ]),
      _day(1, <CareShift>[
        _shift(
            id: 'd', caregiverId: 'maria', start: _at(1, 9), end: _at(1, 17)),
      ]),
      for (int i = 2; i < 7; i++) _day(i, const <CareShift>[]),
    ];

/// A lead day with a visible mid-morning gap + an overlap later on.
List<DayCoverage> _gappyWeek() => <DayCoverage>[
      _day(0, <CareShift>[
        _shift(id: 'a', caregiverId: 'ana', start: _at(0, 0), end: _at(0, 6)),
        // Gap 6am–8am.
        _shift(
            id: 'b', caregiverId: 'maria', start: _at(0, 8), end: _at(0, 14)),
        // Overlap 12pm–2pm with the band above.
        _shift(
            id: 'c', caregiverId: 'james', start: _at(0, 12), end: _at(0, 20)),
        // Gap 8pm–12am.
      ]),
      _day(1, <CareShift>[
        _shift(id: 'd', caregiverId: 'ana', start: _at(1, 6), end: _at(1, 12)),
      ]),
      for (int i = 2; i < 7; i++) _day(i, const <CareShift>[]),
    ];

Widget _host(List<DayCoverage> week) {
  return ProviderScope(
    overrides: <Override>[
      shiftWeekProvider.overrideWith((Ref ref) async => week),
      schedulableCaregiversProvider
          .overrideWith((Ref ref) async => _roster),
    ],
    child: SizedBox(
      width: 460,
      height: 820,
      child: MaterialApp(
        home: const ShiftsScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: holdcloseColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('ShiftsScreen golden', () {
    goldenTest(
      'fully-covered lead day',
      fileName: 'shifts_screen_covered',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'covered (Phase 14.31)',
            child: _host(_coveredWeek()),
          ),
        ],
      ),
    );

    goldenTest(
      'lead day with gaps',
      fileName: 'shifts_screen_gaps',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'gaps (Phase 14.31)',
            child: _host(_gappyWeek()),
          ),
        ],
      ),
    );
  });
}
