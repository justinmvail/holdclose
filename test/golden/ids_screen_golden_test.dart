import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/screens/medical/ids_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 6, 1, 12);

IdentificationDoc _id({
  required String id,
  required IdKind kind,
  required String idNumber,
  DateTime? expiresOn,
}) =>
    IdentificationDoc(
      id: id,
      patientId: 'demo-patient-mary',
      updatedAt: DateTime.utc(2026, 5, 1),
      kind: kind,
      idNumber: idNumber,
      expiresOn: expiresOn,
    );

List<IdentificationDoc> _docs() => <IdentificationDoc>[
      _id(
        id: 'lic',
        kind: IdKind.driverLicense,
        idNumber: 'D1234567',
        // Within 60 days of the fixed now → coral.
        expiresOn: DateTime(2026, 6, 20),
      ),
      _id(
        id: 'mcr',
        kind: IdKind.medicare,
        idNumber: '1EG4TE5MK72',
        expiresOn: DateTime(2028, 1, 31),
      ),
      _id(
        id: 'ins',
        kind: IdKind.insuranceCard,
        idNumber: 'GRP0099AB',
        expiresOn: null,
      ),
    ];

Widget _host(List<IdentificationDoc> docs, double height) {
  return ProviderScope(
    overrides: <Override>[
      idsViewProvider.overrideWith(
        (Ref ref) async => IdsView(patient: null, docs: docs),
      ),
      idsClockProvider.overrideWithValue(_fixedNow),
    ],
    child: SizedBox(
      width: 420,
      height: height,
      child: MaterialApp(
        home: const IdsScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('IdsScreen golden', () {
    goldenTest(
      'renders the populated ID list',
      fileName: 'ids_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.24)',
            child: _host(_docs(), 760),
          ),
        ],
      ),
    );

    goldenTest(
      'renders the empty ID list',
      fileName: 'ids_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.24)',
            child: _host(const <IdentificationDoc>[], 620),
          ),
        ],
      ),
    );
  });
}
