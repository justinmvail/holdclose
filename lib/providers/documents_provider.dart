import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/document.dart';

part 'documents_provider.g.dart';

/// Persistence for the loved one's documents — emergency card, power of
/// attorney, and identification (TASKS.md Phase 14.21).
///
/// Backs Medical → Cards & Documents (BUILD_SPEC.md §5.17). Unlike the
/// other repositories (which blob each freezed model into a single
/// `payload` column), the three documents tables use typed columns, so
/// this repository maps each model field onto its column explicitly. The
/// list / structured fields ([EmergencyCard.conditions] /
/// [EmergencyCard.emergencyContacts] / [EmergencyCard.insurance]) have no
/// native column type, so they cross the SQLite boundary as JSON-encoded
/// TEXT — encoded here on write, decoded here on read. Enums persist as
/// `.name`; `DateTime`s persist as epoch-ms in the lifted `…Ms` columns.
///
/// One DB handle backs all three kinds. There's no FK cascade to worry
/// about — every table stands alone, with [patientId] a logical link to
/// the single-row patients table (see `lib/db/tables.dart`).
class DocumentsRepository {
  DocumentsRepository(this._db);

  final CareblazersDatabase _db;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  // ---- Emergency card ---------------------------------------------------

  /// Insert-or-replace [card] by id, JSON-encoding its list / structured
  /// fields into their TEXT columns.
  Future<void> upsertEmergencyCard(EmergencyCard card) async {
    await _db.into(_db.emergencyCardsTable).insertOnConflictUpdate(
          EmergencyCardsTableCompanion.insert(
            id: card.id,
            patientId: card.patientId,
            updatedAtMs: card.updatedAt.millisecondsSinceEpoch,
            attachmentPath: Value<String?>(card.attachmentPath),
            conditions: jsonEncode(card.conditions),
            medications: jsonEncode(card.medications),
            allergies: jsonEncode(card.allergies),
            emergencyContacts: jsonEncode(
              card.emergencyContacts
                  .map((EmergencyContact c) => c.toJson())
                  .toList(),
            ),
            insurance: jsonEncode(card.insurance.toJson()),
            donorStatus: card.donorStatus.name,
          ),
        );
  }

  /// Drop the emergency card with this id. No-op if absent.
  Future<void> deleteEmergencyCard(String id) async {
    await (_db.delete(_db.emergencyCardsTable)..where((t) => t.id.equals(id)))
        .go();
  }

  /// One emergency card by id, or null if absent.
  Future<EmergencyCard?> getEmergencyCard(String id) async {
    final EmergencyCardsTableData? row =
        await (_db.select(_db.emergencyCardsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    return row == null ? null : _decodeEmergencyCard(row);
  }

  /// Every emergency card, newest first.
  Future<List<EmergencyCard>> listEmergencyCards() async {
    final List<EmergencyCardsTableData> rows =
        await (_db.select(_db.emergencyCardsTable)..orderBy(_byUpdatedDesc()))
            .get();
    return rows.map(_decodeEmergencyCard).toList();
  }

  /// Every emergency card for [patientId], newest first.
  Future<List<EmergencyCard>> emergencyCardsByPatient(String patientId) async {
    final List<EmergencyCardsTableData> rows =
        await (_db.select(_db.emergencyCardsTable)
              ..where((t) => t.patientId.equals(patientId))
              ..orderBy(_byUpdatedDesc()))
            .get();
    return rows.map(_decodeEmergencyCard).toList();
  }

  // ---- Power of attorney ------------------------------------------------

  /// Insert-or-replace [doc] by id.
  Future<void> upsertPoa(PowerOfAttorneyDoc doc) async {
    await _db.into(_db.powerOfAttorneyDocsTable).insertOnConflictUpdate(
          PowerOfAttorneyDocsTableCompanion.insert(
            id: doc.id,
            patientId: doc.patientId,
            updatedAtMs: doc.updatedAt.millisecondsSinceEpoch,
            attachmentPath: Value<String?>(doc.attachmentPath),
            agentName: doc.agentName,
            alternateName: Value<String?>(doc.alternateName),
            scope: doc.scope.name,
            effectiveDateMs: doc.effectiveDate.millisecondsSinceEpoch,
            scanPath: Value<String?>(doc.scanPath),
          ),
        );
  }

  /// Drop the POA doc with this id. No-op if absent.
  Future<void> deletePoa(String id) async {
    await (_db.delete(_db.powerOfAttorneyDocsTable)
          ..where((t) => t.id.equals(id)))
        .go();
  }

  /// One POA doc by id, or null if absent.
  Future<PowerOfAttorneyDoc?> getPoa(String id) async {
    final PowerOfAttorneyDocsTableData? row =
        await (_db.select(_db.powerOfAttorneyDocsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    return row == null ? null : _decodePoa(row);
  }

  /// Every POA doc, newest first.
  Future<List<PowerOfAttorneyDoc>> listPoa() async {
    final List<PowerOfAttorneyDocsTableData> rows = await (_db
            .select(_db.powerOfAttorneyDocsTable)
          ..orderBy(_byUpdatedDescPoa()))
        .get();
    return rows.map(_decodePoa).toList();
  }

  /// Every POA doc for [patientId], newest first.
  Future<List<PowerOfAttorneyDoc>> poaByPatient(String patientId) async {
    final List<PowerOfAttorneyDocsTableData> rows = await (_db
            .select(_db.powerOfAttorneyDocsTable)
          ..where((t) => t.patientId.equals(patientId))
          ..orderBy(_byUpdatedDescPoa()))
        .get();
    return rows.map(_decodePoa).toList();
  }

  // ---- Identification ---------------------------------------------------

  /// Insert-or-replace [doc] by id.
  Future<void> upsertId(IdentificationDoc doc) async {
    await _db.into(_db.identificationDocsTable).insertOnConflictUpdate(
          IdentificationDocsTableCompanion.insert(
            id: doc.id,
            patientId: doc.patientId,
            updatedAtMs: doc.updatedAt.millisecondsSinceEpoch,
            attachmentPath: Value<String?>(doc.attachmentPath),
            kind: doc.kind.name,
            idNumber: doc.idNumber,
            expiresOnMs: Value<int?>(
              doc.expiresOn?.millisecondsSinceEpoch,
            ),
            photoFrontPath: Value<String?>(doc.photoFrontPath),
            photoBackPath: Value<String?>(doc.photoBackPath),
          ),
        );
  }

  /// Drop the ID doc with this id. No-op if absent.
  Future<void> deleteId(String id) async {
    await (_db.delete(_db.identificationDocsTable)
          ..where((t) => t.id.equals(id)))
        .go();
  }

  /// One ID doc by id, or null if absent.
  Future<IdentificationDoc?> getId(String id) async {
    final IdentificationDocsTableData? row =
        await (_db.select(_db.identificationDocsTable)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    return row == null ? null : _decodeId(row);
  }

  /// Every ID doc, newest first.
  Future<List<IdentificationDoc>> listIds() async {
    final List<IdentificationDocsTableData> rows = await (_db
            .select(_db.identificationDocsTable)
          ..orderBy(_byUpdatedDescId()))
        .get();
    return rows.map(_decodeId).toList();
  }

  /// Every ID doc for [patientId], newest first.
  Future<List<IdentificationDoc>> idsByPatient(String patientId) async {
    final List<IdentificationDocsTableData> rows = await (_db
            .select(_db.identificationDocsTable)
          ..where((t) => t.patientId.equals(patientId))
          ..orderBy(_byUpdatedDescId()))
        .get();
    return rows.map(_decodeId).toList();
  }

  // ---- Decoders ---------------------------------------------------------

  List<OrderClauseGenerator<$EmergencyCardsTableTable>> _byUpdatedDesc() =>
      <OrderClauseGenerator<$EmergencyCardsTableTable>>[
        (t) => OrderingTerm(expression: t.updatedAtMs, mode: OrderingMode.desc),
      ];

  List<OrderClauseGenerator<$PowerOfAttorneyDocsTableTable>>
      _byUpdatedDescPoa() =>
          <OrderClauseGenerator<$PowerOfAttorneyDocsTableTable>>[
            (t) => OrderingTerm(
                expression: t.updatedAtMs, mode: OrderingMode.desc),
          ];

  List<OrderClauseGenerator<$IdentificationDocsTableTable>>
      _byUpdatedDescId() =>
          <OrderClauseGenerator<$IdentificationDocsTableTable>>[
            (t) => OrderingTerm(
                expression: t.updatedAtMs, mode: OrderingMode.desc),
          ];

  EmergencyCard _decodeEmergencyCard(EmergencyCardsTableData row) =>
      EmergencyCard(
        id: row.id,
        patientId: row.patientId,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAtMs, isUtc: true),
        attachmentPath: row.attachmentPath,
        conditions: _decodeStringList(row.conditions),
        medications: _decodeStringList(row.medications),
        allergies: _decodeStringList(row.allergies),
        emergencyContacts: (jsonDecode(row.emergencyContacts) as List<dynamic>)
            .map((dynamic e) =>
                EmergencyContact.fromJson(e as Map<String, dynamic>))
            .toList(),
        insurance: Insurance.fromJson(
            jsonDecode(row.insurance) as Map<String, dynamic>),
        donorStatus: DonorStatus.values.byName(row.donorStatus),
      );

  PowerOfAttorneyDoc _decodePoa(PowerOfAttorneyDocsTableData row) =>
      PowerOfAttorneyDoc(
        id: row.id,
        patientId: row.patientId,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAtMs, isUtc: true),
        attachmentPath: row.attachmentPath,
        agentName: row.agentName,
        alternateName: row.alternateName,
        scope: PoaScope.values.byName(row.scope),
        effectiveDate:
            DateTime.fromMillisecondsSinceEpoch(row.effectiveDateMs, isUtc: true),
        scanPath: row.scanPath,
      );

  IdentificationDoc _decodeId(IdentificationDocsTableData row) =>
      IdentificationDoc(
        id: row.id,
        patientId: row.patientId,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAtMs, isUtc: true),
        attachmentPath: row.attachmentPath,
        kind: IdKind.values.byName(row.kind),
        idNumber: row.idNumber,
        expiresOn: row.expiresOnMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row.expiresOnMs!, isUtc: true),
        photoFrontPath: row.photoFrontPath,
        photoBackPath: row.photoBackPath,
      );

  List<String> _decodeStringList(String json) =>
      (jsonDecode(json) as List<dynamic>).cast<String>();
}

/// Riverpod-wired singleton (TASKS.md Phase 14.21). The Cards & Documents
/// screens (later Phase 14 tasks) reach for [documentsRepositoryProvider]
/// and never see the concrete drift database — same indirection
/// [healthLogRepositoryProvider] / [carePlanRepositoryProvider] use.
///
/// In production the repo opens its own [CareblazersDatabase] handle onto
/// the shared SQLite file; SQLite's per-connection serialization keeps
/// that safe. Tests build a [DocumentsRepository] directly against
/// `CareblazersDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
///
/// Named `documentsRepositoryBackend` so the generated class is
/// [DocumentsRepositoryBackendProvider], leaving room for the
/// natural-language [documentsRepositoryProvider] alias below.
@Riverpod(keepAlive: true)
DocumentsRepository documentsRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return DocumentsRepository(db);
}

/// Alias for consumers — matches the `documentsRepositoryProvider` name
/// the Cards & Documents screens reach for.
final DocumentsRepositoryBackendProvider documentsRepositoryProvider =
    documentsRepositoryBackendProvider;

/// The loved one's emergency cards (TASKS.md Phase 14.21).
///
/// `build()` loads every card newest-first; [add] / [updateCard] /
/// [delete] mutate through [documentsRepositoryProvider] and re-read the
/// list so the screen reflects the write without a manual invalidate. The
/// [byPatient] selector filters the already-loaded state synchronously so
/// a `ConsumerWidget` can call it in `build` without awaiting.
@Riverpod(keepAlive: true)
class EmergencyCards extends _$EmergencyCards {
  @override
  Future<List<EmergencyCard>> build() async {
    final DocumentsRepository repo = ref.watch(documentsRepositoryProvider);
    return repo.listEmergencyCards();
  }

  /// Persist a new card, then refresh the cached list.
  Future<void> add(EmergencyCard card) =>
      _mutate((DocumentsRepository repo) => repo.upsertEmergencyCard(card));

  /// Persist an edit to an existing card (upsert by id), then refresh.
  ///
  /// Named `updateCard` rather than `update` because Riverpod's
  /// `AsyncNotifier` already defines an `update(...)` method with an
  /// incompatible signature — overriding it isn't allowed.
  Future<void> updateCard(EmergencyCard card) =>
      _mutate((DocumentsRepository repo) => repo.upsertEmergencyCard(card));

  /// Delete the card with this id, then refresh.
  Future<void> delete(String id) =>
      _mutate((DocumentsRepository repo) => repo.deleteEmergencyCard(id));

  /// Cards belonging to [patientId], newest first (the loaded list is
  /// already ordered). Empty while the first load is still in flight.
  List<EmergencyCard> byPatient(String patientId) =>
      (state.asData?.value ?? const <EmergencyCard>[])
          .where((EmergencyCard c) => c.patientId == patientId)
          .toList();

  Future<void> _mutate(
    Future<void> Function(DocumentsRepository repo) op,
  ) async {
    final DocumentsRepository repo = ref.read(documentsRepositoryProvider);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listEmergencyCards();
    });
  }
}

/// The loved one's power-of-attorney documents (TASKS.md Phase 14.21).
///
/// Same shape as [EmergencyCards] — newest-first load with CRUD mutators
/// and a synchronous [byPatient] selector.
@Riverpod(keepAlive: true)
class PowerOfAttorneyDocs extends _$PowerOfAttorneyDocs {
  @override
  Future<List<PowerOfAttorneyDoc>> build() async {
    final DocumentsRepository repo = ref.watch(documentsRepositoryProvider);
    return repo.listPoa();
  }

  /// Persist a new POA doc, then refresh the cached list.
  Future<void> add(PowerOfAttorneyDoc doc) =>
      _mutate((DocumentsRepository repo) => repo.upsertPoa(doc));

  /// Persist an edit to an existing POA doc (upsert by id), then refresh.
  Future<void> updateDoc(PowerOfAttorneyDoc doc) =>
      _mutate((DocumentsRepository repo) => repo.upsertPoa(doc));

  /// Delete the POA doc with this id, then refresh.
  Future<void> delete(String id) =>
      _mutate((DocumentsRepository repo) => repo.deletePoa(id));

  /// POA docs belonging to [patientId], newest first.
  List<PowerOfAttorneyDoc> byPatient(String patientId) =>
      (state.asData?.value ?? const <PowerOfAttorneyDoc>[])
          .where((PowerOfAttorneyDoc d) => d.patientId == patientId)
          .toList();

  Future<void> _mutate(
    Future<void> Function(DocumentsRepository repo) op,
  ) async {
    final DocumentsRepository repo = ref.read(documentsRepositoryProvider);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listPoa();
    });
  }
}

/// The loved one's identification documents (TASKS.md Phase 14.21).
///
/// Same shape as [EmergencyCards] — newest-first load with CRUD mutators
/// and a synchronous [byPatient] selector.
@Riverpod(keepAlive: true)
class IdentificationDocs extends _$IdentificationDocs {
  @override
  Future<List<IdentificationDoc>> build() async {
    final DocumentsRepository repo = ref.watch(documentsRepositoryProvider);
    return repo.listIds();
  }

  /// Persist a new ID doc, then refresh the cached list.
  Future<void> add(IdentificationDoc doc) =>
      _mutate((DocumentsRepository repo) => repo.upsertId(doc));

  /// Persist an edit to an existing ID doc (upsert by id), then refresh.
  Future<void> updateDoc(IdentificationDoc doc) =>
      _mutate((DocumentsRepository repo) => repo.upsertId(doc));

  /// Delete the ID doc with this id, then refresh.
  Future<void> delete(String id) =>
      _mutate((DocumentsRepository repo) => repo.deleteId(id));

  /// ID docs belonging to [patientId], newest first.
  List<IdentificationDoc> byPatient(String patientId) =>
      (state.asData?.value ?? const <IdentificationDoc>[])
          .where((IdentificationDoc d) => d.patientId == patientId)
          .toList();

  Future<void> _mutate(
    Future<void> Function(DocumentsRepository repo) op,
  ) async {
    final DocumentsRepository repo = ref.read(documentsRepositoryProvider);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listIds();
    });
  }
}
