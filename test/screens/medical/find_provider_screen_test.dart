import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart' show Provider;
import 'package:holdclose/models/provider_search_result.dart';
import 'package:holdclose/providers/npi_provider_provider.dart';
import 'package:holdclose/screens/medical/find_provider_screen.dart';
import 'package:holdclose/services/npi_provider_service.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Records the args of the last [search] call so tests can assert the City /
/// State fields flow through (and State is normalised to a 2-letter code).
class _RecordingNpiService implements NpiProviderService {
  String? lastName;
  String? lastSpecialty;
  String? lastCity;
  String? lastState;

  @override
  Future<List<ProviderSearchResult>?> search({
    String? name,
    String? specialty,
    String? city,
    String? state,
    String? postalCode,
  }) async {
    lastName = name;
    lastSpecialty = specialty;
    lastCity = city;
    lastState = state;
    return const <ProviderSearchResult>[
      ProviderSearchResult(
        name: 'John Berger',
        credential: 'MD',
        specialty: 'Neurology',
        city: 'Charleston',
        state: 'SC',
        npi: '1234567890',
      ),
    ];
  }
}

/// The find-a-provider screen: search (via the fake NPI service) → results →
/// Save persists a Provider.
Future<void> _pump(
  WidgetTester tester, {
  required ProviderRepository repo,
  NpiProviderService service = const FakeNpiProviderService(),
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/find-provider',
    routes: <RouteBase>[
      GoRoute(
        path: '/find-provider',
        builder: (BuildContext context, GoRouterState state) =>
            const FindProviderScreen(),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        providerRepositoryBackendProvider.overrideWithValue(repo),
        npiProviderServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('search shows results and Save persists a provider',
      (WidgetTester tester) async {
    final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final ProviderRepository repo = ProviderRepository(db);

    await _pump(tester, repo: repo);

    // Drive via Last name (a plain field) so no type-ahead overlay sits over
    // the Search button.
    await tester.enterText(
        find.byKey(FindProviderScreen.lastNameKey), 'Berger');
    await tester.tap(find.byKey(FindProviderScreen.searchButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('John Berger, MD'), findsOneWidget);
    // The card surfaces the full doctor + practice details (fb_1783039822948375
    // — "we want all the information about the doctor and business"), not just
    // city/state: street, city/state+ZIP, tap-to-call phone, and NPI.
    expect(find.text('2135 Ashley Phosphate Rd'), findsOneWidget);
    expect(find.text('North Charleston, SC 29456'), findsOneWidget);
    expect(find.text('843-767-4500'), findsOneWidget);
    expect(find.text('NPI 1234567890'), findsOneWidget);

    await tester.tap(find.byKey(FindProviderScreen.saveKey('1234567890')));
    await tester.pumpAndSettle();

    final List<Provider> providers = await repo.listProviders();
    expect(providers.any((Provider p) => p.name == 'John Berger, MD'), isTrue);
  });

  testWidgets('City field exists and City + State flow to the NPI service',
      (WidgetTester tester) async {
    final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final ProviderRepository repo = ProviderRepository(db);
    final _RecordingNpiService service = _RecordingNpiService();

    await _pump(tester, repo: repo, service: service);

    // City is a real field on the form.
    expect(find.byKey(FindProviderScreen.cityKey), findsOneWidget);

    await tester.enterText(find.byKey(FindProviderScreen.cityKey), 'Charleston');
    // Full state name typed free-hand normalises to the 2-letter code.
    await tester.enterText(
        find.byKey(FindProviderScreen.stateKey), 'South Carolina');
    // Close the type-ahead overlay so it isn't sitting over the button.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(FindProviderScreen.searchButtonKey));
    await tester.pumpAndSettle();

    expect(service.lastCity, 'Charleston');
    expect(service.lastState, 'SC');
  });
}
