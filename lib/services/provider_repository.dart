import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/appointment.dart';
import 'sync_sink.dart';

part 'provider_repository.g.dart';

/// Persistence for the appointment tracker's [Provider] rows (TASKS.md
/// Phase 12.7).
///
/// Wraps the drift [ProvidersTable] behind plain CRUD. The companion
/// [AppointmentRepository] keeps its own [Provider] *read* helpers so
/// the appointment list + detail screens (Phase 12.6) don't need to
/// shuffle through two repositories per render; this repository owns
/// the *write* path the add/edit appointment form (Phase 12.7) reaches
/// for when the caregiver adds a new provider inline.
///
/// Each freezed [Provider] serialises through its `toJson` shape into
/// the row's `payload` column — same blob-with-lifted-keys pattern
/// [MedicationRepository] / [AppointmentRepository] use. Deleting a
/// [Provider] cascades to every appointment that FKs onto it via the
/// `ON DELETE CASCADE` declared in `lib/db/tables.dart`; the
/// `PRAGMA foreign_keys = ON` in [HoldcloseDatabase]'s `beforeOpen`
/// is what makes that cascade real.
class ProviderRepository with SyncSinkHost {
  ProviderRepository(this._db);

  final HoldcloseDatabase _db;

  /// Insert-or-replace [provider] by id. The lifted [name] column keeps
  /// the alphabetical sort in [listProviders] from having to decode
  /// every payload.
  Future<void> upsertProvider(Provider provider) async {
    await _db.into(_db.providersTable).insertOnConflictUpdate(
          ProvidersTableCompanion.insert(
            id: provider.id,
            name: provider.name,
            payload: jsonEncode(provider.toJson()),
          ),
        );
    emitUpsert('providers', provider.id, provider.toJson());
  }

  /// Drop the provider row. The FK's `ON DELETE CASCADE` removes every
  /// appointment that points at it in the same statement.
  Future<void> deleteProvider(String providerId) async {
    await (_db.delete(_db.providersTable)
          ..where((t) => t.id.equals(providerId)))
        .go();
    emitDelete('providers', providerId);
  }

  /// One provider by id, or null if absent. The appointment form
  /// (Phase 12.7) reads through this to hydrate the provider picker
  /// when the caregiver opens an edit flow on an existing appointment.
  Future<Provider?> getProvider(String id) async {
    final ProvidersTableData? row = await (_db.select(_db.providersTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return Provider.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  /// Every provider, alphabetical by name — the order the provider
  /// dropdown in the appointment form (Phase 12.7) renders rows in.
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
}

/// Riverpod-wired singleton (TASKS.md Phase 12.7). The add/edit
/// appointment form (Phase 12.7) reads through
/// [providerRepositoryProvider] when the caregiver creates a provider
/// inline, never seeing the concrete drift database — same indirection
/// [appointmentRepositoryProvider] and [medicationRepositoryProvider]
/// use.
///
/// In production the repo opens its own [HoldcloseDatabase] handle
/// onto the same SQLite file the rest of the app shares; SQLite's
/// per-connection serialization keeps that safe. Tests build a
/// [ProviderRepository] directly against `HoldcloseDatabase(
/// NativeDatabase.memory())` so each test gets an isolated DB.
///
/// Named `providerRepositoryBackend` so the generated class is
/// [ProviderRepositoryBackendProvider], leaving room for the
/// natural-language [providerRepositoryProvider] alias below.
@Riverpod(keepAlive: true)
ProviderRepository providerRepositoryBackend(Ref ref) {
  final HoldcloseDatabase db = HoldcloseDatabase.open();
  ref.onDispose(db.close);
  return ProviderRepository(db);
}

/// Alias for consumers — matches the `providerRepositoryProvider` name
/// the appointment form reaches for.
final ProviderRepositoryBackendProvider providerRepositoryProvider =
    providerRepositoryBackendProvider;
