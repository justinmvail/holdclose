import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/document.dart';
import 'package:careblazers/screens/medical/poa_screen.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

PoaView _populated() => PoaView(
      patient: maryHenderson(),
      doc: PowerOfAttorneyDoc(
        id: 'poa-1',
        patientId: maryHenderson().id,
        updatedAt: DateTime.utc(2026, 5, 20),
        agentName: 'Jane Doe',
        scope: PoaScope.medical,
        effectiveDate: DateTime.utc(2024, 3, 14),
        alternateName: 'Tom Henderson',
      ),
    );

PoaView _empty() => PoaView(patient: maryHenderson(), doc: null);

Widget _host(PoaView view, double height) {
  return ProviderScope(
    overrides: <Override>[
      poaViewProvider.overrideWith((Ref ref) async => view),
    ],
    child: SizedBox(
      width: 420,
      height: height,
      child: MaterialApp(
        home: const PoaScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('PoaScreen golden', () {
    goldenTest(
      'renders the populated POA card',
      fileName: 'poa_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.24)',
            child: _host(_populated(), 760),
          ),
        ],
      ),
    );

    goldenTest(
      'renders the empty POA placeholder',
      fileName: 'poa_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.24)',
            child: _host(_empty(), 620),
          ),
        ],
      ),
    );
  });
}
