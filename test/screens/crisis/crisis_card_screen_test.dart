import 'dart:typed_data';

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

/// Records every call to [PdfExporter.crisisCard] + [PdfExporter.sharePdf]
/// without spinning up the `printing` platform channel. The crisis card
/// screen's print action chains the two so the test asserts both.
class _RecordingPdfExporter extends PdfExporter {
  _RecordingPdfExporter() : super(compress: false);

  final List<Patient> crisisCalls = <Patient>[];
  final List<({Uint8List bytes, String filename})> shareCalls =
      <({Uint8List bytes, String filename})>[];

  @override
  Future<Uint8List> crisisCard(Patient patient) async {
    crisisCalls.add(patient);
    return Uint8List(0);
  }

  @override
  Future<bool> sharePdf(
    Uint8List bytes, {
    String filename = 'careblazers.pdf',
  }) async {
    shareCalls.add((bytes: bytes, filename: filename));
    return true;
  }
}

Future<({
  InMemoryStorageProvider storage,
  _RecordingPdfExporter exporter,
})> _pumpCrisis(
  WidgetTester tester, {
  Patient? existing,
  Patient? demoSeed,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final InMemoryStorageProvider storage = InMemoryStorageProvider();
  if (existing != null) {
    await storage.upsertPatient(existing);
  }
  final _RecordingPdfExporter exporter = _RecordingPdfExporter();

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        storageBackendProvider.overrideWithValue(storage),
        pdfExporterProvider.overrideWithValue(exporter),
        crisisCardDemoSeedProvider.overrideWithValue(demoSeed),
        crisisCardClockProvider.overrideWithValue(
          () => DateTime.utc(2026, 5, 29),
        ),
      ],
      child: MaterialApp(
        theme: careblazersLightTheme,
        home: const CrisisCardScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (storage: storage, exporter: exporter);
}

void main() {
  group('CrisisCardScreen — BUILD_SPEC.md §5.9', () {
    testWidgets(
      'demo mode seeds Mary Henderson when storage is empty on first launch',
      (WidgetTester tester) async {
        final ({
          InMemoryStorageProvider storage,
          _RecordingPdfExporter exporter,
        }) p = await _pumpCrisis(tester, demoSeed: maryHenderson());

        // The card renders with Mary's name + age + diagnosis.
        expect(find.byKey(CrisisCardScreen.cardKey), findsOneWidget);
        expect(find.text('Mary Henderson'), findsOneWidget);
        expect(find.text('78'), findsOneWidget);
        expect(
          find.text("Alzheimer's disease, stage 5 (moderately severe)"),
          findsOneWidget,
        );

        // And the seed actually persisted — re-reading storage returns
        // the same patient, so a real-mode restart wouldn't ask the
        // user to re-fill the card.
        final Patient? persisted = await p.storage.getPatient();
        expect(persisted, isNotNull);
        expect(persisted!.id, 'demo-patient-mary');
      },
    );

    testWidgets(
      'real-mode shows the empty placeholder when storage is empty and there is no seed',
      (WidgetTester tester) async {
        await _pumpCrisis(tester);

        expect(find.byKey(CrisisCardScreen.emptyPlaceholderKey), findsOneWidget);
        expect(find.byKey(CrisisCardScreen.cardKey), findsNothing);
      },
    );

    testWidgets(
      'an existing patient in storage renders without re-seeding',
      (WidgetTester tester) async {
        final Patient existing = maryHenderson().copyWith(name: 'Ada Lovelace');
        // Even though demoSeed is non-null, the existing row wins.
        await _pumpCrisis(
          tester,
          existing: existing,
          demoSeed: maryHenderson(),
        );

        expect(find.text('Ada Lovelace'), findsOneWidget);
        expect(find.text('Mary Henderson'), findsNothing);
      },
    );

    testWidgets(
      'editing the name field persists through StorageProvider.upsertPatient',
      (WidgetTester tester) async {
        final ({
          InMemoryStorageProvider storage,
          _RecordingPdfExporter exporter,
        }) p = await _pumpCrisis(tester, demoSeed: maryHenderson());

        // Tap the name row to enter edit mode → TextField appears.
        await tester.tap(find.byKey(CrisisCardScreen.nameFieldKey));
        await tester.pumpAndSettle();

        // Replace the text and commit by submitting (blur path is
        // exercised by `onTapOutside`, which a widget-test tap somewhere
        // outside the field also fires — the submit path is simpler to
        // assert deterministically).
        await tester.enterText(
          find.byKey(CrisisCardScreen.nameFieldKey),
          'Mary H.',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        // Storage round-trip confirms the upsert landed.
        final Patient? persisted = await p.storage.getPatient();
        expect(persisted, isNotNull);
        expect(persisted!.name, 'Mary H.');

        // And the screen re-renders with the new name.
        expect(find.text('Mary H.'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping print invokes PdfExporter.crisisCard with the current patient',
      (WidgetTester tester) async {
        final ({
          InMemoryStorageProvider storage,
          _RecordingPdfExporter exporter,
        }) p = await _pumpCrisis(tester, demoSeed: maryHenderson());

        await tester.tap(find.byKey(CrisisCardScreen.printButtonKey));
        await tester.pumpAndSettle();

        expect(p.exporter.crisisCalls, hasLength(1));
        expect(p.exporter.crisisCalls.single.id, 'demo-patient-mary');
        // The screen chains crisisCard → sharePdf so the OS sheet
        // actually opens — verify the second leg too.
        expect(p.exporter.shareCalls, hasLength(1));
        expect(
          p.exporter.shareCalls.single.filename,
          'crisis-card-demo-patient-mary.pdf',
        );
      },
    );

    testWidgets(
      'print and QR actions are disabled while the patient is null',
      (WidgetTester tester) async {
        await _pumpCrisis(tester);

        final IconButton printBtn = tester.widget<IconButton>(
          find.byKey(CrisisCardScreen.printButtonKey),
        );
        final IconButton qrBtn = tester.widget<IconButton>(
          find.byKey(CrisisCardScreen.qrButtonKey),
        );
        expect(printBtn.onPressed, isNull);
        expect(qrBtn.onPressed, isNull);
      },
    );

    testWidgets(
      'tapping QR opens a dialog containing the placeholder patient URL',
      (WidgetTester tester) async {
        await _pumpCrisis(tester, demoSeed: maryHenderson());

        await tester.tap(find.byKey(CrisisCardScreen.qrButtonKey));
        await tester.pumpAndSettle();

        expect(find.byKey(CrisisCardScreen.qrDialogKey), findsOneWidget);
        expect(
          find.text('https://careblazers.app/patient/demo-patient-mary'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'editing the DNR toggle persists the new value',
      (WidgetTester tester) async {
        final ({
          InMemoryStorageProvider storage,
          _RecordingPdfExporter exporter,
        }) p = await _pumpCrisis(tester, demoSeed: maryHenderson());

        // Scroll until the directive switch is visible — the card is
        // taller than the test viewport.
        await tester.scrollUntilVisible(
          find.byKey(CrisisCardScreen.directiveDnrKey),
          200,
          scrollable: find.byType(Scrollable).first,
        );

        await tester.tap(find.byKey(CrisisCardScreen.directiveDnrKey));
        await tester.pumpAndSettle();

        final Patient? persisted = await p.storage.getPatient();
        expect(persisted, isNotNull);
        expect(persisted!.advanceDirective.dnr, isTrue);
      },
    );

    testWidgets(
      'updated footer shows the clock-provided date',
      (WidgetTester tester) async {
        await _pumpCrisis(tester, demoSeed: maryHenderson());

        await tester.scrollUntilVisible(
          find.byKey(CrisisCardScreen.updatedFooterKey),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Updated May 29, 2026'), findsOneWidget);
      },
    );
  });
}
