import 'dart:convert';

import 'package:alchemist/alchemist.dart';
import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/screens/appointment/appointment_list_screen.dart'
    show appointmentListClockProvider;
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/next_appointment_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// 9 AM Mon Jun 1 2026 — a visit later this day reads "Today" (coral
/// dot); the future-dated visit reads "Jun 4" (navy dot).
DateTime _fixedNow() => DateTime(2026, 6, 1, 9, 0);

AppointmentRepository _emptyRepo() =>
    AppointmentRepository(CareblazersDatabase(NativeDatabase.memory()),
        clock: _fixedNow);

Future<void> _seedProvider(CareblazersDatabase db, Provider p) async {
  await db.into(db.providersTable).insertOnConflictUpdate(
        ProvidersTableCompanion.insert(
          id: p.id,
          name: p.name,
          payload: jsonEncode(p.toJson()),
        ),
      );
}

/// A future neurology visit with a named driver — the populated steady
/// state showing the navy future-dot, specialty, and the driver line.
Future<AppointmentRepository> _populatedRepo() async {
  final CareblazersDatabase db = CareblazersDatabase(NativeDatabase.memory());
  final AppointmentRepository repo = AppointmentRepository(db, clock: _fixedNow);
  await _seedProvider(
    db,
    const Provider(
      id: 'prov-1',
      name: 'Dr. Ortega',
      role: ProviderRole.neurologist,
      phone: '(415) 555-0188',
      address: '250 Bon Air Rd, Greenbrae CA',
    ),
  );
  await repo.upsertAppointment(Appointment(
    id: 'appt-1',
    providerId: 'prov-1',
    startsAt: DateTime(2026, 6, 4, 14, 30),
    durationMinutes: 45,
    location: 'Marin General — Neurology',
    agenda: const <String>[],
    status: AppointmentStatus.upcoming,
    driverName: 'Maria',
  ));
  return repo;
}

GoRouter _goldenRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) => const Scaffold(
          backgroundColor: Color(0xFFFFFFFF),
          body: Padding(
            padding: EdgeInsets.all(16),
            child: NextAppointmentCard(),
          ),
        ),
      ),
    ],
  );
}

/// Hosts the card at a phone width on a synchronously-ready repo. No
/// `theme:` is passed — per `flutter_test_config.dart` goldens avoid
/// dragging google_fonts through the framework; the card pulls its brand
/// colors directly off `careblazersColors`.
Widget _host(AppointmentRepository repo, double height) => ProviderScope(
      overrides: <Override>[
        appointmentRepositoryBackendProvider.overrideWithValue(repo),
        appointmentListClockProvider.overrideWithValue(_fixedNow),
      ],
      child: SizedBox(
        width: 390,
        height: height,
        child: MaterialApp.router(
          routerConfig: _goldenRouter(),
          builder: (BuildContext context, Widget? child) => ColoredBox(
            color: careblazersColors.background,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );

/// Builds the host once [future] resolves the populated repo.
Widget _asyncHost(Future<AppointmentRepository> future, double height) =>
    FutureBuilder<AppointmentRepository>(
      future: future,
      builder: (BuildContext context,
          AsyncSnapshot<AppointmentRepository> snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        return _host(snapshot.data!, height);
      },
    );

void main() {
  group('NextAppointmentCard golden', () {
    goldenTest(
      'empty — no upcoming appointments',
      fileName: 'next_appointment_card_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.10)',
            child: _host(_emptyRepo(), 180),
          ),
        ],
      ),
    );

    goldenTest(
      'populated — soonest upcoming visit with a driver',
      fileName: 'next_appointment_card_populated',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'populated (Phase 14.10)',
            child: _asyncHost(_populatedRepo(), 220),
          ),
        ],
      ),
    );
  });
}
