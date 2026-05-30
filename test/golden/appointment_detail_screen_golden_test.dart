import 'dart:convert';

import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart' as model;
import 'package:careblazers/providers/link_launcher_provider.dart';
import 'package:careblazers/screens/appointment/appointment_detail_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

DateTime _fixedNow() => DateTime.utc(2026, 6, 1, 12);

Future<AppointmentRepository> _repoWithUpcoming() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final AppointmentRepository repo =
      AppointmentRepository(db, clock: _fixedNow);

  const model.Provider provider = model.Provider(
    id: 'prov-ortega',
    name: 'Dr. Ortega',
    role: model.ProviderRole.neurologist,
    phone: '(415) 555-0188',
    address: '250 Bon Air Rd, Greenbrae CA',
  );
  await db.into(db.providersTable).insertOnConflictUpdate(
        ProvidersTableCompanion.insert(
          id: provider.id,
          name: provider.name,
          payload: jsonEncode(provider.toJson()),
        ),
      );
  await repo.upsertAppointment(model.Appointment(
    id: 'appt-1',
    providerId: provider.id,
    startsAt: DateTime.utc(2026, 6, 15, 14, 30),
    durationMinutes: 45,
    location: 'Marin General — Neurology, 2nd floor',
    agenda: const <String>[
      'Ask about evening agitation',
      'Refill Donepezil',
      'Review Memantine side effects',
    ],
    completedAgendaIndices: const <int>{0},
    status: model.AppointmentStatus.upcoming,
  ));
  return repo;
}

Future<AppointmentRepository> _repoWithCompleted() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final AppointmentRepository repo =
      AppointmentRepository(db, clock: _fixedNow);
  const model.Provider provider = model.Provider(
    id: 'prov-ortega',
    name: 'Dr. Ortega',
    role: model.ProviderRole.neurologist,
    phone: '(415) 555-0188',
    address: '250 Bon Air Rd, Greenbrae CA',
  );
  await db.into(db.providersTable).insertOnConflictUpdate(
        ProvidersTableCompanion.insert(
          id: provider.id,
          name: provider.name,
          payload: jsonEncode(provider.toJson()),
        ),
      );
  await repo.upsertAppointment(model.Appointment(
    id: 'appt-done',
    providerId: provider.id,
    startsAt: DateTime.utc(2026, 5, 20, 10),
    durationMinutes: 30,
    location: 'Telehealth',
    agenda: const <String>[
      'Discuss sundowning',
      'Decide on trazodone trial',
    ],
    completedAgendaIndices: const <int>{0, 1},
    status: model.AppointmentStatus.completed,
    notes:
        'Dr. suggested a low-dose trazodone trial for the evening agitation; '
        'pharmacy will call when ready.',
  ));
  return repo;
}

void main() {
  group('AppointmentDetailScreen golden', () {
    goldenTest(
      'upcoming appointment — agenda + call/directions + notes prompt',
      fileName: 'appointment_detail_screen_upcoming',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'upcoming (Phase 12.6)',
            child: FutureBuilder<AppointmentRepository>(
              future: _repoWithUpcoming(),
              builder: (BuildContext context,
                  AsyncSnapshot<AppointmentRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                return ProviderScope(
                  overrides: <Override>[
                    appointmentRepositoryBackendProvider
                        .overrideWithValue(snapshot.data!),
                    linkLauncherProvider
                        .overrideWithValue(RecordingLinkLauncher()),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 1100,
                    child: MaterialApp.router(
                      routerConfig: _goldenRouter('appt-1'),
                      builder: (BuildContext context, Widget? child) {
                        return ColoredBox(
                          color: careblazersColors.background,
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

    goldenTest(
      'completed appointment — checked agenda + saved notes',
      fileName: 'appointment_detail_screen_completed',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'completed (Phase 12.6)',
            child: FutureBuilder<AppointmentRepository>(
              future: _repoWithCompleted(),
              builder: (BuildContext context,
                  AsyncSnapshot<AppointmentRepository> snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                return ProviderScope(
                  overrides: <Override>[
                    appointmentRepositoryBackendProvider
                        .overrideWithValue(snapshot.data!),
                    linkLauncherProvider
                        .overrideWithValue(RecordingLinkLauncher()),
                  ],
                  child: SizedBox(
                    width: 420,
                    height: 1100,
                    child: MaterialApp.router(
                      routerConfig: _goldenRouter('appt-done'),
                      builder: (BuildContext context, Widget? child) {
                        return ColoredBox(
                          color: careblazersColors.background,
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

GoRouter _goldenRouter(String appointmentId) {
  return GoRouter(
    initialLocation: '/appointments/$appointmentId',
    routes: <RouteBase>[
      GoRoute(
        path: '/appointments/:id',
        builder: (BuildContext context, GoRouterState state) =>
            AppointmentDetailScreen(
          appointmentId: state.pathParameters['id'] ?? '',
        ),
      ),
    ],
  );
}
