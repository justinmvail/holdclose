import 'dart:convert';

import 'package:alchemist/alchemist.dart';
import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/appointment.dart' as model;
import 'package:holdclose/screens/appointment/appointment_list_screen.dart';
import 'package:holdclose/services/appointment_repository.dart';
import 'package:holdclose/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime.utc(2026, 6, 1, 12);

AppointmentRepository _emptyRepo() {
  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  return AppointmentRepository(db, clock: _fixedNow);
}

Future<AppointmentRepository> _populatedRepo() async {
  final HoldcloseDatabase db = HoldcloseDatabase(NativeDatabase.memory());
  final AppointmentRepository repo =
      AppointmentRepository(db, clock: _fixedNow);

  Future<void> seedProvider(String id, String name) async {
    final model.Provider p = model.Provider(
      id: id,
      name: name,
      role: model.ProviderRole.neurologist,
      phone: '(415) 555-0188',
      address: '250 Bon Air Rd, Greenbrae CA',
    );
    await db.into(db.providersTable).insertOnConflictUpdate(
          ProvidersTableCompanion.insert(
            id: id,
            name: name,
            payload: jsonEncode(p.toJson()),
          ),
        );
  }

  await seedProvider('prov-ortega', 'Dr. Ortega');
  await seedProvider('prov-lee', 'Sandra Lee, LCSW');

  await repo.upsertAppointment(model.Appointment(
    id: 'appt-1',
    providerId: 'prov-ortega',
    startsAt: DateTime.utc(2026, 6, 15, 14, 30),
    durationMinutes: 45,
    location: 'Marin General — Neurology',
    agenda: const <String>[
      'Ask about evening agitation',
      'Refill Donepezil',
      'Review Memantine side effects',
    ],
    status: model.AppointmentStatus.upcoming,
  ));
  await repo.upsertAppointment(model.Appointment(
    id: 'appt-2',
    providerId: 'prov-lee',
    startsAt: DateTime.utc(2026, 6, 2, 9),
    durationMinutes: 60,
    location: 'Home visit',
    agenda: const <String>['Caregiver respite resources'],
    status: model.AppointmentStatus.upcoming,
  ));
  await repo.upsertAppointment(model.Appointment(
    id: 'appt-3',
    providerId: 'prov-ortega',
    startsAt: DateTime.utc(2026, 5, 20, 10),
    durationMinutes: 30,
    location: 'Telehealth',
    agenda: const <String>['Discuss sundowning'],
    status: model.AppointmentStatus.completed,
    notes: 'Suggested evening routine adjustments.',
  ));

  return repo;
}

void main() {
  group('AppointmentListScreen golden', () {
    goldenTest(
      'empty state — Add appointment CTA inline',
      fileName: 'appointment_list_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 12.6)',
            child: ProviderScope(
              overrides: <Override>[
                appointmentRepositoryBackendProvider
                    .overrideWithValue(_emptyRepo()),
                appointmentListClockProvider.overrideWithValue(_fixedNow),
              ],
              child: SizedBox(
                width: 420,
                height: 900,
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
            ),
          ),
        ],
      ),
    );

    goldenTest(
      'populated — two upcoming + one completed',
      fileName: 'appointment_list_screen_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 12.6)',
            child: FutureBuilder<AppointmentRepository>(
              future: _populatedRepo(),
              builder: (BuildContext context,
                  AsyncSnapshot<AppointmentRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                return ProviderScope(
                  overrides: <Override>[
                    appointmentRepositoryBackendProvider
                        .overrideWithValue(snapshot.data!),
                    appointmentListClockProvider.overrideWithValue(_fixedNow),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 900,
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
    initialLocation: '/appointments',
    routes: <RouteBase>[
      GoRoute(
        path: '/appointments',
        builder: (BuildContext context, GoRouterState state) =>
            const AppointmentListScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'new',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
          GoRoute(
            path: ':id',
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      ),
    ],
  );
}
