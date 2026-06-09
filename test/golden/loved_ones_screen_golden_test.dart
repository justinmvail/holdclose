import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/screens/settings/loved_ones_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Golden coverage for the "Loved ones" manager (Issue #6) — the populated
/// roster with the active loved one flagged, and the empty state.

Patient _patient(String id, String name, int age, String diagnosis) => Patient(
      id: id,
      name: name,
      age: age,
      diagnosis: diagnosis,
      diagnosedAt: DateTime.utc(2022, 1, 1),
      medications: const <CrisisMedication>[],
      allergies: const <String>[],
      calms: const <String>[],
      escalates: const <String>[],
      primaryCaregiver: const Contact(name: 'Sarah', phone: '555-0100'),
      healthcarePOA: const Contact(name: 'Sarah', phone: '555-0100'),
      advanceDirective:
          const AdvanceDirectiveStatus(onFileAt: 'Not on file', dnr: false),
    );

Widget _host(LovedOnesView view, double height) {
  return ProviderScope(
    overrides: <Override>[
      lovedOnesViewProvider.overrideWith((Ref ref) async => view),
    ],
    child: SizedBox(
      width: 440,
      height: height,
      child: MaterialApp(
        home: const LovedOnesScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('LovedOnesScreen golden', () {
    goldenTest(
      'renders the populated loved-ones manager',
      fileName: 'loved_ones_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Issue #6)',
            child: _host(
              LovedOnesView(
                patients: <Patient>[
                  _patient('p-frank', 'Frank Albright', 81, 'Vascular dementia'),
                  _patient(
                      'p-mary', 'Mary Henderson', 78, "Alzheimer's disease"),
                ],
                activeId: 'p-mary',
              ),
              620,
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'renders the empty loved-ones manager',
      fileName: 'loved_ones_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Issue #6)',
            child: _host(
              const LovedOnesView(patients: <Patient>[], activeId: null),
              520,
            ),
          ),
        ],
      ),
    );
  });
}
