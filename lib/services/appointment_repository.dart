import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/appointment.dart';

part 'appointment_repository.g.dart';

/// Persistence for the appointment tracker (TASKS.md Phase 12.6).
///
/// Wraps the two drift tables [ProvidersTable] and [AppointmentsTable]
/// behind plain CRUD plus the [upcoming] / [past] split the list screen
/// (Phase 12.6) groups its sections by:
///
///   - [upcoming] returns appointments at or after the clock sample with
///     [AppointmentStatus.upcoming], ordered chronologically — the next
///     visit is the first row.
///   - [past] returns everything else (completed, canceled, or upcoming
///     whose `startsAt` has already slipped by) most-recent-first so the
///     list-screen "Past" section reads top-down as a recency timeline.
///
/// The repository owns *reads* on both tables plus mutations on
/// [Appointment] — the add/edit appointment form (Phase 12.7) is the
/// surface that mutates [Provider] rows through the companion
/// [ProviderRepository]. Detail-screen mutations on the agenda
/// checkboxes and post-visit notes round-trip through [upsertAppointment]
/// so the row blob stays consistent with its lifted [AppointmentsTable.startsAtMs] column.
///
/// Each freezed model serialises through its `toJson` shape into the
/// row's `payload` column — same blob-with-lifted-keys pattern
/// [ChatRepository] / [MedicationRepository] use. Deleting a [Provider]
/// cascades to its appointments via the FK `ON DELETE CASCADE` declared
/// in `lib/db/tables.dart`; the `PRAGMA foreign_keys = ON` in
/// [CareblazersDatabase]'s `beforeOpen` is what makes that cascade real.
class AppointmentRepository {
  AppointmentRepository(this._db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final CareblazersDatabase _db;
  final DateTime Function() _clock;

  // ─────────────────────────────────────────── Appointment CRUD ──

  /// Insert-or-replace [appointment] by id. The lifted
  /// [AppointmentsTable.startsAtMs] column keeps the chronological
  /// queries in [upcoming] / [past] from having to decode every payload.
  Future<void> upsertAppointment(Appointment appointment) async {
    await _db.into(_db.appointmentsTable).insertOnConflictUpdate(
          AppointmentsTableCompanion.insert(
            id: appointment.id,
            providerId: appointment.providerId,
            startsAtMs: appointment.startsAt.millisecondsSinceEpoch,
            payload: jsonEncode(appointment.toJson()),
          ),
        );
  }

  /// Drop the appointment row. Providers are untouched.
  Future<void> deleteAppointment(String appointmentId) async {
    await (_db.delete(_db.appointmentsTable)
          ..where((t) => t.id.equals(appointmentId)))
        .go();
  }

  /// One appointment by id, or null if absent. The detail screen
  /// (Phase 12.6) reads through this to hydrate its agenda + notes UI.
  Future<Appointment?> getAppointment(String id) async {
    final AppointmentsTableData? row =
        await (_db.select(_db.appointmentsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    if (row == null) return null;
    return Appointment.fromJson(
        jsonDecode(row.payload) as Map<String, dynamic>);
  }

  /// Every appointment, chronological by `startsAt`. Surface for the
  /// doctor-visit PDF (Phase 12.8) which wants the full history.
  Future<List<Appointment>> listAppointments() async {
    final List<AppointmentsTableData> rows =
        await (_db.select(_db.appointmentsTable)
              ..orderBy(<OrderClauseGenerator<$AppointmentsTableTable>>[
                (t) => OrderingTerm(
                    expression: t.startsAtMs, mode: OrderingMode.asc),
              ]))
            .get();
    return rows
        .map((AppointmentsTableData r) => Appointment.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  // ─────────────────────────────────────────── Provider reads ──

  /// One provider by id, or null if absent. The detail screen
  /// (Phase 12.6) reads through this to resolve the provider name +
  /// phone + address its call/directions buttons reach for.
  Future<Provider?> getProvider(String id) async {
    final ProvidersTableData? row = await (_db.select(_db.providersTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return Provider.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  /// Every provider, alphabetical by name. The list screen (Phase 12.6)
  /// reads this in a single batch to denormalise provider names onto
  /// appointment cards without one query per row.
  Future<List<Provider>> listProviders() async {
    final List<ProvidersTableData> rows =
        await (_db.select(_db.providersTable)
              ..orderBy(<OrderClauseGenerator<$ProvidersTableTable>>[
                (t) => OrderingTerm(
                    expression: t.name, mode: OrderingMode.asc),
              ]))
            .get();
    return rows
        .map((ProvidersTableData r) => Provider.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }

  // ─────────────────────────────────────────── Grouped views ──

  /// Appointments still on the books — `status == upcoming` and
  /// `startsAt >= clock()`. Ordered ascending so the next visit is the
  /// first row. The list screen (Phase 12.6) renders this under its
  /// "Upcoming" header.
  Future<List<Appointment>> upcoming() async {
    final DateTime now = _clock();
    final int nowMs = now.millisecondsSinceEpoch;
    final List<AppointmentsTableData> rows =
        await (_db.select(_db.appointmentsTable)
              ..where((t) => t.startsAtMs.isBiggerOrEqualValue(nowMs))
              ..orderBy(<OrderClauseGenerator<$AppointmentsTableTable>>[
                (t) => OrderingTerm(
                    expression: t.startsAtMs, mode: OrderingMode.asc),
              ]))
            .get();
    return rows
        .map((AppointmentsTableData r) => Appointment.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>))
        .where((Appointment a) => a.status == AppointmentStatus.upcoming)
        .toList();
  }

  /// Appointments that have happened or fallen off the calendar —
  /// completed, canceled, or `upcoming` whose `startsAt` is now in the
  /// past (the caregiver never marked it completed but the day passed).
  /// Ordered most-recent-first so the list-screen "Past" section reads
  /// as a recency timeline.
  Future<List<Appointment>> past() async {
    final DateTime now = _clock();
    final int nowMs = now.millisecondsSinceEpoch;
    final List<AppointmentsTableData> rows =
        await (_db.select(_db.appointmentsTable)
              ..orderBy(<OrderClauseGenerator<$AppointmentsTableTable>>[
                (t) => OrderingTerm(
                    expression: t.startsAtMs, mode: OrderingMode.desc),
              ]))
            .get();
    return rows
        .map((AppointmentsTableData r) => Appointment.fromJson(
            jsonDecode(r.payload) as Map<String, dynamic>))
        .where((Appointment a) =>
            a.status == AppointmentStatus.completed ||
            a.status == AppointmentStatus.canceled ||
            (a.status == AppointmentStatus.upcoming &&
                a.startsAt.millisecondsSinceEpoch < nowMs))
        .toList();
  }
}

/// Riverpod-wired singleton (TASKS.md Phase 12.6). The appointment
/// screens (Phase 12.6 + 12.7) and the doctor-visit PDF exporter
/// (Phase 12.8) reach for [appointmentRepositoryProvider] and never see
/// the concrete drift database — same indirection
/// [medicationRepositoryProvider] and [chatRepositoryProvider] use.
///
/// In production the repo opens its own [CareblazersDatabase] handle
/// onto the same SQLite file the rest of the app shares; SQLite's
/// per-connection serialization keeps that safe. Tests build an
/// [AppointmentRepository] directly against `CareblazersDatabase(
/// NativeDatabase.memory())` so each test gets an isolated DB.
///
/// Named `appointmentRepositoryBackend` so the generated class is
/// [AppointmentRepositoryBackendProvider], leaving room for the
/// natural-language [appointmentRepositoryProvider] alias below.
@Riverpod(keepAlive: true)
AppointmentRepository appointmentRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return AppointmentRepository(db);
}

/// Alias for consumers — matches the `appointmentRepositoryProvider`
/// name the appointment screens and PDF exporter reach for.
final AppointmentRepositoryBackendProvider appointmentRepositoryProvider =
    appointmentRepositoryBackendProvider;
