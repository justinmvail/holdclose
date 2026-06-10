import 'package:careblazers/providers/voice_capture_provider.dart';
import 'package:careblazers/routing/router.dart';
import 'package:careblazers/widgets/home/add_action_sheet.dart';
import 'package:careblazers/widgets/voice_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// A [VoiceCapture] that always yields the same transcript so the row's
/// capture→forward wiring is exercised without a live microphone.
class _FakeVoiceCapture implements VoiceCapture {
  const _FakeVoiceCapture(this.transcript);

  final String? transcript;

  @override
  Future<String?> capture({void Function(String partial)? onPartial}) async => transcript;
}

/// Renders the destination route name + the kind/text of any
/// [AddSheetTranscript] passed as `extra`, plus the `kind` query param,
/// so a test can assert exactly what each row pushed.
Widget _dest(String name, GoRouterState state) {
  final Object? extra = state.extra;
  final String parcel = extra is AddSheetTranscript
      ? '${extra.kind.name}:${extra.text}'
      : 'none';
  final String kindQuery = state.uri.queryParameters['kind'] ?? '';
  return Scaffold(body: Text('DEST $name q=$kindQuery extra=$parcel'));
}

GoRouter _harnessRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) => const Scaffold(
          floatingActionButton: AddActionFab(),
          body: Center(child: Text('HOME')),
        ),
      ),
      GoRoute(
        path: '/journal/new',
        name: CareblazersRoutes.journalNew,
        builder: (BuildContext context, GoRouterState state) =>
            _dest('journalNew', state),
      ),
      GoRoute(
        path: '/medications/today',
        name: CareblazersRoutes.medicationDoseLog,
        builder: (BuildContext context, GoRouterState state) =>
            _dest('doseLog', state),
      ),
      GoRoute(
        path: '/appointments/new',
        name: CareblazersRoutes.appointmentForm,
        builder: (BuildContext context, GoRouterState state) =>
            _dest('apptForm', state),
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  VoiceCapture? capture,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        if (capture != null) voiceCaptureProvider.overrideWithValue(capture),
      ],
      child: MaterialApp.router(routerConfig: _harnessRouter()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(AddActionFab.fabKey));
  await tester.pumpAndSettle();
}

void main() {
  group('AddActionFab', () {
    testWidgets('is a 58px teal circle with a white plus glyph',
        (WidgetTester tester) async {
      await _pump(tester);

      final SizedBox box = tester.widget<SizedBox>(
        find.ancestor(
          of: find.byKey(AddActionFab.fabKey),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(box.width, 58);
      expect(box.height, 58);

      final FloatingActionButton fab =
          tester.widget<FloatingActionButton>(find.byKey(AddActionFab.fabKey));
      expect(fab.backgroundColor, addSheetTeal);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('tapping the FAB opens the Add sheet with all four rows',
        (WidgetTester tester) async {
      await _pump(tester);
      expect(find.byKey(AddActionSheet.sheetKey), findsNothing);

      await _openSheet(tester);

      expect(find.byKey(AddActionSheet.sheetKey), findsOneWidget);
      expect(find.text('Journal entry'), findsOneWidget);
      expect(find.text('Med dose'), findsOneWidget);
      expect(find.text('Appointment'), findsOneWidget);
      expect(find.text('Quick note'), findsOneWidget);
      // One voice button per row.
      expect(find.byType(VoiceButton), findsNWidgets(4));
    });
  });

  group('AddActionSheet — row taps push the right route', () {
    testWidgets('Journal entry → /journal/new (no transcript)',
        (WidgetTester tester) async {
      await _pump(tester);
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('add-row-journalEntry')));
      await tester.pumpAndSettle();

      expect(find.byKey(AddActionSheet.sheetKey), findsNothing);
      expect(find.text('DEST journalNew q= extra=none'), findsOneWidget);
    });

    testWidgets('Med dose → /medications/today', (WidgetTester tester) async {
      await _pump(tester);
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('add-row-medDose')));
      await tester.pumpAndSettle();

      expect(find.text('DEST doseLog q= extra=none'), findsOneWidget);
    });

    testWidgets('Appointment → /appointments/new',
        (WidgetTester tester) async {
      await _pump(tester);
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('add-row-appointment')));
      await tester.pumpAndSettle();

      expect(find.text('DEST apptForm q= extra=none'), findsOneWidget);
    });

    testWidgets('Quick note → /journal/new?kind=note',
        (WidgetTester tester) async {
      await _pump(tester);
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('add-row-quickNote')));
      await tester.pumpAndSettle();

      expect(find.text('DEST journalNew q=note extra=none'), findsOneWidget);
    });
  });

  group('AddActionSheet — voice button forwards the transcript per row', () {
    testWidgets('voice on Med dose forwards an AddSheetTranscript(medDose)',
        (WidgetTester tester) async {
      await _pump(tester, capture: const _FakeVoiceCapture('gave the 8pm pill'));
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('add-row-voice-medDose')));
      await tester.pumpAndSettle();

      expect(
        find.text('DEST doseLog q= extra=medDose:gave the 8pm pill'),
        findsOneWidget,
      );
    });

    testWidgets('voice on Quick note carries both the kind query and the '
        'transcript', (WidgetTester tester) async {
      await _pump(tester, capture: const _FakeVoiceCapture('remember the keys'));
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('add-row-voice-quickNote')));
      await tester.pumpAndSettle();

      expect(
        find.text(
            'DEST journalNew q=note extra=quickNote:remember the keys'),
        findsOneWidget,
      );
    });

    testWidgets('a blank capture does not navigate — the sheet stays open',
        (WidgetTester tester) async {
      await _pump(tester, capture: const _FakeVoiceCapture('   '));
      await _openSheet(tester);

      await tester.tap(find.byKey(const Key('add-row-voice-journalEntry')));
      await tester.pumpAndSettle();

      expect(find.byKey(AddActionSheet.sheetKey), findsOneWidget);
      expect(find.textContaining('DEST'), findsNothing);
    });
  });

  group('AddActionSheet — dismiss', () {
    testWidgets('tapping the scrim dismisses the sheet and restores Home',
        (WidgetTester tester) async {
      await _pump(tester);
      await _openSheet(tester);
      expect(find.byKey(AddActionSheet.sheetKey), findsOneWidget);

      // Tap the barrier above the sheet to dismiss it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.byKey(AddActionSheet.sheetKey), findsNothing);
      expect(find.text('HOME'), findsOneWidget);
      expect(find.byKey(AddActionFab.fabKey), findsOneWidget);
    });
  });
}
