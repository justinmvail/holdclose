import 'package:careblazers/models/document.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/screens/medical/emergency_card_screen.dart';
import 'package:careblazers/screens/medication/medication_list_screen.dart'
    show MedicationListItem;
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

EmergencyCard _populatedCard() => EmergencyCard(
      id: 'ec-1',
      patientId: maryHenderson().id,
      updatedAt: DateTime.utc(2026, 5, 29),
      conditions: const <String>["Alzheimer's, stage 5", 'Hypertension'],
      // Display mirrors the medication tracker, not this list — left empty
      // on purpose to prove the screen reads the live provider instead.
      medications: const <String>[],
      allergies: const <String>['Penicillin', 'Sulfa drugs'],
      emergencyContacts: const <EmergencyContact>[
        EmergencyContact(
          name: 'Sarah Henderson',
          relation: 'Daughter',
          phone: '(415) 555-0142',
        ),
      ],
      insurance: const Insurance(
        carrier: 'Medicare',
        policyNumber: '1EG4-TE5-MK72',
        groupNumber: 'GRP-0099',
      ),
      donorStatus: DonorStatus.donor,
    );

List<MedicationListItem> _meds() => <MedicationListItem>[
      const MedicationListItem(
        medication: Medication(
          id: 'm-donepezil',
          name: 'Donepezil',
          dosage: '10 mg',
          route: MedicationRoute.oral,
        ),
        nextDose: null,
        adherenceLast7Days: 1.0,
        hasScoreableHistory: false,
      ),
    ];

EmergencyCardView _populatedView() => EmergencyCardView(
      patient: maryHenderson(),
      card: _populatedCard(),
      medications: _meds(),
    );

GoRouter _router() {
  return GoRouter(
    initialLocation: '/medical/cards/emergency',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /'))),
      ),
      GoRoute(
        path: '/medical',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /medical'))),
      ),
      GoRoute(
        path: '/medical/cards',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /medical/cards'))),
      ),
      GoRoute(
        path: '/medical/cards/emergency',
        builder: (BuildContext c, GoRouterState s) =>
            const EmergencyCardScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'edit',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Center(child: Text('DEST edit'))),
          ),
        ],
      ),
    ],
  );
}

Future<(GoRouter, RecordingLinkLauncher)> _pump(
  WidgetTester tester, {
  required EmergencyCardView view,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final RecordingLinkLauncher launcher = RecordingLinkLauncher();
  final GoRouter router = _router();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        emergencyCardViewProvider.overrideWith((Ref ref) async => view),
        linkLauncherProvider.overrideWithValue(launcher),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router, launcher);
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.last.matchedLocation;

void main() {
  group('EmergencyCardScreen — populated', () {
    testWidgets('renders the ICE headline + every section', (tester) async {
      await _pump(tester, view: _populatedView());

      expect(
        find.text('ICE CARD — Show to First Responders'),
        findsOneWidget,
      );

      // Patient identity (name + age line stands in for DOB — see screen).
      expect(find.byKey(EmergencyCardScreen.patientSectionKey), findsOneWidget);
      expect(find.text('Mary Henderson'), findsOneWidget);
      expect(find.text('Age 78'), findsOneWidget);

      // Conditions + allergies render as chips.
      expect(find.text('Hypertension'), findsOneWidget);
      expect(find.text('Penicillin'), findsOneWidget);
      expect(find.text('Sulfa drugs'), findsOneWidget);

      // Medications mirror the live tracker.
      expect(find.textContaining('Donepezil'), findsOneWidget);

      // Emergency contact row + insurance + donor.
      expect(find.textContaining('Sarah Henderson'), findsOneWidget);
      expect(find.text('Medicare'), findsOneWidget);
      expect(find.text('1EG4-TE5-MK72'), findsOneWidget);
      expect(find.text('Registered organ donor'), findsOneWidget);
    });

    testWidgets('shows the Cards & Documents trail + Back control',
        (tester) async {
      final (GoRouter router, _) = await _pump(tester, view: _populatedView());

      // Title + terminal crumb both read "Emergency Card".
      expect(find.text('Emergency Card'), findsNWidgets(2));
      expect(find.text('Cards & Documents'), findsOneWidget);
      expect(find.text('Back to Cards & Documents'), findsOneWidget);

      await tester.tap(find.text('Back to Cards & Documents'));
      await tester.pumpAndSettle();
      expect(_path(router), '/medical/cards');
    });

    testWidgets('edit action pushes the edit route', (tester) async {
      final (GoRouter router, _) = await _pump(tester, view: _populatedView());

      await tester.tap(find.byKey(EmergencyCardScreen.editActionKey));
      await tester.pumpAndSettle();

      expect(_path(router), '/medical/cards/emergency/edit');
      expect(find.text('DEST edit'), findsOneWidget);
    });

    testWidgets('call button launches a sanitised tel: URI', (tester) async {
      final (_, RecordingLinkLauncher launcher) =
          await _pump(tester, view: _populatedView());

      await tester.tap(find.byKey(EmergencyCardScreen.callButtonKey(0)));
      await tester.pumpAndSettle();

      expect(launcher.launched, hasLength(1));
      expect(launcher.launched.single, Uri(scheme: 'tel', path: '4155550142'));
    });
  });

  group('EmergencyCardScreen — empty card', () {
    testWidgets('blank sections read "None / Not on file" + Unknown donor',
        (tester) async {
      await _pump(
        tester,
        view: EmergencyCardView(
          patient: maryHenderson(),
          card: null,
          medications: const <MedicationListItem>[],
        ),
      );

      // Patient identity still renders from the loved one's profile.
      expect(find.text('Mary Henderson'), findsOneWidget);
      // Conditions, medications, allergies, contacts each fall back.
      expect(find.text('None on file'), findsNWidgets(4));
      expect(find.text('Not on file'), findsOneWidget);
      expect(find.text('Unknown'), findsOneWidget);
    });
  });

  group('EmergencyCardScreen — variants', () {
    testWidgets('not-a-donor + blank insurance fields render their fallbacks',
        (tester) async {
      await _pump(
        tester,
        view: EmergencyCardView(
          patient: maryHenderson(),
          card: _populatedCard().copyWith(
            donorStatus: DonorStatus.notDonor,
            insurance: const Insurance(
              carrier: '',
              policyNumber: '',
              groupNumber: '',
            ),
          ),
          medications: _meds(),
        ),
      );

      expect(find.text('Not an organ donor'), findsOneWidget);
      // Carrier / Policy / Group each fall back to an em dash.
      expect(find.text('—'), findsNWidgets(3));
    });
  });

  group('EmergencyCardScreen — no profile', () {
    testWidgets('shows the empty placeholder when no patient exists',
        (tester) async {
      await _pump(
        tester,
        view: const EmergencyCardView(
          patient: null,
          card: null,
          medications: <MedicationListItem>[],
        ),
      );

      expect(
        find.byKey(EmergencyCardScreen.emptyPlaceholderKey),
        findsOneWidget,
      );
      expect(find.byKey(EmergencyCardScreen.patientSectionKey), findsNothing);
    });
  });
}
