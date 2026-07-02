import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart' show Provider;
import 'package:holdclose/providers/npi_provider_provider.dart';
import 'package:holdclose/screens/medical/find_provider_screen.dart';
import 'package:holdclose/services/npi_provider_service.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// The find-a-provider screen: search (via the fake NPI service) → results →
/// Save persists a Provider.
Future<void> _pump(WidgetTester tester,
    {required ProviderRepository repo}) async {
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
        npiProviderServiceProvider
            .overrideWithValue(const FakeNpiProviderService()),
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

    await tester.enterText(
        find.byKey(FindProviderScreen.specialtyKey), 'Neurology');
    await tester.tap(find.byKey(FindProviderScreen.searchButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('John Berger, MD'), findsOneWidget);

    await tester.tap(find.byKey(FindProviderScreen.saveKey('1234567890')));
    await tester.pumpAndSettle();

    final List<Provider> providers = await repo.listProviders();
    expect(providers.any((Provider p) => p.name == 'John Berger, MD'), isTrue);
  });
}
