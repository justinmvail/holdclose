import 'dart:typed_data';

import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/patient.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/crisis/crisis_card_screen.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:careblazers/services/pdf_exporter.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

class _NoopExporter extends PdfExporter {
  _NoopExporter() : super(compress: false);

  @override
  Future<Uint8List> crisisCard(Patient patient) async => Uint8List(0);

  @override
  Future<bool> sharePdf(
    Uint8List bytes, {
    String filename = 'careblazers.pdf',
  }) async =>
      true;
}

InMemoryStorageProvider _seededStorage() {
  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  storage.upsertPatient(maryHenderson());
  return storage;
}

void main() {
  group('CrisisCardScreen golden', () {
    goldenTest(
      'renders the populated handoff card for Mary Henderson',
      fileName: 'crisis_card_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (§5.9 full layout)',
            child: ProviderScope(
              overrides: <Override>[
                storageBackendProvider.overrideWithValue(_seededStorage()),
                pdfExporterProvider.overrideWithValue(_NoopExporter()),
                crisisCardDemoSeedProvider.overrideWithValue(null),
                crisisCardClockProvider.overrideWithValue(
                  () => DateTime.utc(2026, 5, 29),
                ),
              ],
              child: SizedBox(
                width: 420,
                height: 1600,
                child: MaterialApp(
                  home: const CrisisCardScreen(),
                  builder: (BuildContext context, Widget? child) {
                    return ColoredBox(
                      color: careblazersColors.background,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  });
}
