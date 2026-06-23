import 'dart:convert';

import 'package:alchemist/alchemist.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart' as model;
import 'package:holdclose/screens/appointment/appointment_form_screen.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/services/provider_repository.dart';
import 'package:holdclose/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime(2026, 5, 30, 9, 0);

/// Build an isolated DB seeded with a single provider so the empty
/// add-form's dropdown isn't blank.
Future<({
  HoldcloseDatabase db,
  AppointmentRepository apptRepo,
  ProviderRepository providerRepo,
})> _scaffold() async {
  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  final AppointmentRepository apptRepo =
      AppointmentRepository(db, clock: _fixedNow);
  final ProviderRepository providerRepo = ProviderRepository(db);

  const model.Provider p = model.Provider(
    id: 'prov-ortega',
    name: 'Dr. Ortega',
    role: model.ProviderRole.neurologist,
    phone: '(415) 555-0188',
    address: '250 Bon Air Rd, Greenbrae CA',
  );
  await db.into(db.providersTable).insertOnConflictUpdate(
        ProvidersTableCompanion.insert(
          id: p.id,
          name: p.name,
          payload: jsonEncode(p.toJson()),
        ),
      );

  return (db: db, apptRepo: apptRepo, providerRepo: providerRepo);
}

void main() {
  group('AppointmentFormScreen golden', () {
    goldenTest(
      'empty add-appointment form',
      fileName: 'appointment_form_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty add form (Phase 12.7)',
            child: FutureBuilder<
                ({
                  HoldcloseDatabase db,
                  AppointmentRepository apptRepo,
                  ProviderRepository providerRepo,
                })>(
              future: _scaffold(),
              builder: (BuildContext context, AsyncSnapshot<dynamic> snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                final ({
                  HoldcloseDatabase db,
                  AppointmentRepository apptRepo,
                  ProviderRepository providerRepo,
                }) bundle = snap.data!;
                return ProviderScope(
                  overrides: <Override>[
                    appointmentRepositoryBackendProvider
                        .overrideWithValue(bundle.apptRepo),
                    providerRepositoryBackendProvider
                        .overrideWithValue(bundle.providerRepo),
                    appointmentFormClockProvider.overrideWithValue(_fixedNow),
                    appointmentFormIdFactoryProvider
                        .overrideWithValue(() => 'golden-id'),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 1400,
                    child: MaterialApp.router(
                      routerConfig: _goldenRouter(),
                      builder: (BuildContext context, Widget? child) {
                        return ColoredBox(
                          color: holdcloseColors.background,
                          child: child ?? const SizedBox.shrink(),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  });
}

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/appointments/new',
    routes: <RouteBase>[
      GoRoute(
        path: '/appointments',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: SizedBox.shrink()),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            builder: (BuildContext context, GoRouterState state) =>
                const AppointmentFormScreen(),
          ),
        ],
      ),
    ],
  );
}
