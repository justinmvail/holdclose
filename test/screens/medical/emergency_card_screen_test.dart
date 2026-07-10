import 'package:holdclose/models/document.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/providers/link_launcher_provider.dart';
import 'package:holdclose/screens/medical/emergency_card_screen.dart';
import 'package:holdclose/seed/mary_henderson.dart';
import 'package:holdclose/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The read-only Emergency Card screen. Its only back affordance is the
/// PathHeader breadcrumb (no AppBar), so the breadcrumb must be present on
/// EVERY branch — including the loading and error states — or the screen is
/// swipe-only (alpha bug fb_1780932762335231).
EmergencyCardView _view() => EmergencyCardView(
      patient: maryHenderson(),
      card: null,
      medications: const <Medication>[],
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/medical/cards/emergency',
    routes: <RouteBase>[
      GoRoute(
        path: '/medical/cards/emergency',
        builder: (BuildContext context, GoRouterState state) =>
            const EmergencyCardScreen(),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EmergencyCardScreen — PathHeader back affordance', () {
    testWidgets('renders the PathHeader breadcrumb on the data branch',
        (WidgetTester tester) async {
      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith((Ref ref) async => _view()),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
      expect(find.text('Emergency Card'), findsWidgets);
      // The Edit affordance lives in the header's trailing slot.
      expect(find.byKey(EmergencyCardScreen.editActionKey), findsOneWidget);
    });

    testWidgets('keeps the PathHeader breadcrumb on the error branch',
        (WidgetTester tester) async {
      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith(
            (Ref ref) async => throw Exception('boom'),
          ),
        ],
      );
      await tester.pumpAndSettle();

      // Even when the card fails to load, the breadcrumb back affordance
      // is on screen — the screen is never a swipe-only dead-end.
      expect(find.byType(PathHeader), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Care'), findsOneWidget);
    });
  });

  group('EmergencyCardScreen — identity line (DOB)', () {
    testWidgets(
        'shows DOB + derived age when a date of birth is on file '
        '(what EMS/clinicians expect)', (WidgetTester tester) async {
      // Mary's seed carries dateOfBirth 1948-03-04; pin the clock so the
      // derived age is deterministic.
      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith((Ref ref) async => _view()),
          emergencyCardClockProvider
              .overrideWithValue(() => DateTime(2026, 7, 8)),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('DOB Mar 4, 1948 · 78'), findsOneWidget);
      expect(find.text('Age 78'), findsNothing);
    });

    testWidgets('falls back to the age-only line without a date of birth',
        (WidgetTester tester) async {
      final EmergencyCardView view = EmergencyCardView(
        patient: maryHenderson().copyWith(dateOfBirth: null),
        card: null,
        medications: const <Medication>[],
      );
      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith((Ref ref) async => view),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('Age 78'), findsOneWidget);
      expect(find.textContaining('DOB'), findsNothing);
    });
  });

  group('EmergencyCardScreen — blood type', () {
    testWidgets('renders the blood-type section with the value on file',
        (WidgetTester tester) async {
      // Mary's seed carries bloodType 'O+' — a triage-critical field that
      // sits beside allergies for EMS.
      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith((Ref ref) async => _view()),
        ],
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(EmergencyCardScreen.bloodTypeSectionKey),
        findsOneWidget,
      );
      expect(find.text('Blood type'), findsOneWidget);
      expect(find.text('O+'), findsOneWidget);
    });

    testWidgets('shows "Unknown" when no blood type is on file (optional)',
        (WidgetTester tester) async {
      final EmergencyCardView view = EmergencyCardView(
        patient: maryHenderson().copyWith(bloodType: null),
        card: null,
        medications: const <Medication>[],
      );
      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith((Ref ref) async => view),
        ],
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(EmergencyCardScreen.bloodTypeSectionKey),
        findsOneWidget,
      );
      expect(find.text('O+'), findsNothing);
      // "Unknown" also renders in the Organ Donor section, so scope the
      // assertion to the blood-type section's subtree.
      expect(
        find.descendant(
          of: find.byKey(EmergencyCardScreen.bloodTypeSectionKey),
          matching: find.text('Unknown'),
        ),
        findsOneWidget,
      );
    });
  });

  group('EmergencyCardScreen — insurance call', () {
    testWidgets('shows the member-services phone + Call, and dials it',
        (WidgetTester tester) async {
      final RecordingLinkLauncher launcher = RecordingLinkLauncher();
      final EmergencyCardView view = EmergencyCardView(
        patient: maryHenderson(),
        card: EmergencyCard(
          id: 'card-1',
          patientId: 'demo-patient-mary',
          updatedAt: DateTime(2026, 6, 1),
          conditions: const <String>[],
          medications: const <String>[],
          allergies: const <String>[],
          emergencyContacts: const <EmergencyContact>[],
          insurance: const Insurance(
            carrier: 'BlueCross',
            policyNumber: 'P1',
            groupNumber: 'G1',
            phone: '800-555-1212',
          ),
          donorStatus: DonorStatus.unknown,
        ),
        medications: const <Medication>[],
      );

      await _pump(
        tester,
        overrides: <Override>[
          emergencyCardViewProvider.overrideWith((Ref ref) async => view),
          linkLauncherProvider.overrideWithValue(launcher),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('800-555-1212'), findsOneWidget);

      await tester.tap(find.byKey(EmergencyCardScreen.insuranceCallKey));
      await tester.pumpAndSettle();

      expect(launcher.launched, hasLength(1));
      expect(launcher.launched.single, Uri(scheme: 'tel', path: '8005551212'));
    });
  });
}
