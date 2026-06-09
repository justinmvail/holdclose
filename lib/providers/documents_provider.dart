import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/document.dart';
import '../services/document_blob_service.dart';
import '../services/sync_sink.dart';

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
class DocumentsRepository with SyncSinkHost {
  DocumentsRepository(this._db, {DocumentBlobService? blobService})
      : blobService = blobService ?? const NoopDocumentBlobService();

  final CareblazersDatabase _db;

  /// Moves document-scan image BYTES to/from R2 so a scan survives a
  /// reinstall + syncs across the circle (the row metadata already syncs).
  /// Defaults to the no-op service so a repository used in isolation
  /// (tests / local-only / demo) behaves exactly as before — local path
  /// only. The [syncController] provider swaps in the real HTTP service.
  DocumentBlobService blobService;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  // ---- Emergency card ---------------------------------------------------

  /// Insert-or-replace [card] by id, JSON-encoding its list / structured
  /// fields into their TEXT columns.
  ///
  /// Before persisting, the attachment image's bytes are uploaded to R2
  /// (best-effort) and the returned storage key folded onto the row so the
  /// scan — not just its path — syncs across the circle. A failed upload
  /// leaves the key null and the local path intact.
  Future<void> upsertEmergencyCard(EmergencyCard card) async {
    final EmergencyCard enriched = card.copyWith(
      attachmentKey: await blobService.uploadIfNeeded(
        docId: card.id,
        field: 'attachment',
        localPath: card.attachmentPath,
        existingKey: card.attachmentKey,
      ),
    );
    await _db.into(_db.emergencyCardsTable).insertOnConflictUpdate(
          EmergencyCardsTableCompanion.insert(
            id: enriched.id,
            patientId: enriched.patientId,
            updatedAtMs: enriched.updatedAt.millisecondsSinceEpoch,
            attachmentPath: Value<String?>(enriched.attachmentPath),
            attachmentKey: Value<String?>(enriched.attachmentKey),
            conditions: jsonEncode(enriched.conditions),
            medications: jsonEncode(enriched.medications),
            allergies: jsonEncode(enriched.allergies),
            emergencyContacts: jsonEncode(
              enriched.emergencyContacts
                  .map((EmergencyContact c) => c.toJson())
                  .toList(),
            ),
            insurance: jsonEncode(enriched.insurance.toJson()),
            donorStatus: enriched.donorStatus.name,
          ),
        );
    // The image blob now rides along via [attachmentKey] (part of toJson),
    // so another device can GET it; the on-device [attachmentPath] stays a
    // local pointer and a missing file degrades gracefully in the UI.
    emitUpsert('emergency_cards', enriched.id, enriched.toJson());
  }

  /// Drop the emergency card with this id. No-op if absent.
  Future<void> deleteEmergencyCard(String id) async {
    await (_db.delete(_db.emergencyCardsTable)..where((t) => t.id.equals(id)))
        .go();
    emitDelete('emergency_cards', id);
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

  /// Insert-or-replace [doc] by id. Uploads the attachment + scan image
  /// bytes to R2 (best-effort) and folds the storage keys onto the row so
  /// the images sync across the circle.
  Future<void> upsertPoa(PowerOfAttorneyDoc doc) async {
    final PowerOfAttorneyDoc enriched = doc.copyWith(
      attachmentKey: await blobService.uploadIfNeeded(
        docId: doc.id,
        field: 'attachment',
        localPath: doc.attachmentPath,
        existingKey: doc.attachmentKey,
      ),
      scanKey: await blobService.uploadIfNeeded(
        docId: doc.id,
        field: 'scan',
        localPath: doc.scanPath,
        existingKey: doc.scanKey,
      ),
    );
    await _db.into(_db.powerOfAttorneyDocsTable).insertOnConflictUpdate(
          PowerOfAttorneyDocsTableCompanion.insert(
            id: enriched.id,
            patientId: enriched.patientId,
            updatedAtMs: enriched.updatedAt.millisecondsSinceEpoch,
            attachmentPath: Value<String?>(enriched.attachmentPath),
            attachmentKey: Value<String?>(enriched.attachmentKey),
            agentName: enriched.agentName,
            alternateName: Value<String?>(enriched.alternateName),
            scope: enriched.scope.name,
            effectiveDateMs: enriched.effectiveDate.millisecondsSinceEpoch,
            scanPath: Value<String?>(enriched.scanPath),
            scanKey: Value<String?>(enriched.scanKey),
          ),
        );
    emitUpsert('power_of_attorney_docs', enriched.id, enriched.toJson());
  }

  /// Drop the POA doc with this id. No-op if absent.
  Future<void> deletePoa(String id) async {
    await (_db.delete(_db.powerOfAttorneyDocsTable)
          ..where((t) => t.id.equals(id)))
        .go();
    emitDelete('power_of_attorney_docs', id);
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

  /// Insert-or-replace [doc] by id. Uploads the attachment + front/back
  /// photo bytes to R2 (best-effort) and folds the storage keys onto the
  /// row so the images sync across the circle.
  Future<void> upsertId(IdentificationDoc doc) async {
    final IdentificationDoc enriched = doc.copyWith(
      attachmentKey: await blobService.uploadIfNeeded(
        docId: doc.id,
        field: 'attachment',
        localPath: doc.attachmentPath,
        existingKey: doc.attachmentKey,
      ),
      photoFrontKey: await blobService.uploadIfNeeded(
        docId: doc.id,
        field: 'photoFront',
        localPath: doc.photoFrontPath,
        existingKey: doc.photoFrontKey,
      ),
      photoBackKey: await blobService.uploadIfNeeded(
        docId: doc.id,
        field: 'photoBack',
        localPath: doc.photoBackPath,
        existingKey: doc.photoBackKey,
      ),
    );
    await _db.into(_db.identificationDocsTable).insertOnConflictUpdate(
          IdentificationDocsTableCompanion.insert(
            id: enriched.id,
            patientId: enriched.patientId,
            updatedAtMs: enriched.updatedAt.millisecondsSinceEpoch,
            attachmentPath: Value<String?>(enriched.attachmentPath),
            attachmentKey: Value<String?>(enriched.attachmentKey),
            kind: enriched.kind.name,
            idNumber: enriched.idNumber,
            expiresOnMs: Value<int?>(
              enriched.expiresOn?.millisecondsSinceEpoch,
            ),
            photoFrontPath: Value<String?>(enriched.photoFrontPath),
            photoBackPath: Value<String?>(enriched.photoBackPath),
            photoFrontKey: Value<String?>(enriched.photoFrontKey),
            photoBackKey: Value<String?>(enriched.photoBackKey),
          ),
        );
    emitUpsert('identification_docs', enriched.id, enriched.toJson());
  }

  /// Drop the ID doc with this id. No-op if absent.
  Future<void> deleteId(String id) async {
    await (_db.delete(_db.identificationDocsTable)
          ..where((t) => t.id.equals(id)))
        .go();
    emitDelete('identification_docs', id);
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

  // ---- Blob hydration (sync apply) --------------------------------------

  /// After a pulled emergency card lands, download its attachment blob (if
  /// the row carries a key but the local file is missing — i.e. the doc came
  /// from another device) and persist the resulting local path. Runs inside
  /// [applyingRemote] so re-saving the path doesn't re-enqueue the doc.
  /// Best-effort: a download failure leaves the row's path as-is.
  Future<void> hydrateEmergencyCardBlobs(EmergencyCard card) async {
    final String? path = await blobService.downloadIfMissing(
      docId: card.id,
      field: 'attachment',
      key: card.attachmentKey,
      localPath: card.attachmentPath,
    );
    if (path == null) return;
    await applyingRemote(
      () => upsertEmergencyCard(card.copyWith(attachmentPath: path)),
    );
  }

  /// Download a pulled POA doc's attachment + scan blobs into local files
  /// when missing, then persist the paths. See [hydrateEmergencyCardBlobs].
  Future<void> hydratePoaBlobs(PowerOfAttorneyDoc doc) async {
    final String? attachment = await blobService.downloadIfMissing(
      docId: doc.id,
      field: 'attachment',
      key: doc.attachmentKey,
      localPath: doc.attachmentPath,
    );
    final String? scan = await blobService.downloadIfMissing(
      docId: doc.id,
      field: 'scan',
      key: doc.scanKey,
      localPath: doc.scanPath,
    );
    if (attachment == null && scan == null) return;
    await applyingRemote(
      () => upsertPoa(doc.copyWith(
        attachmentPath: attachment ?? doc.attachmentPath,
        scanPath: scan ?? doc.scanPath,
      )),
    );
  }

  /// Download a pulled ID doc's attachment + front/back photo blobs into
  /// local files when missing, then persist the paths. See
  /// [hydrateEmergencyCardBlobs].
  Future<void> hydrateIdBlobs(IdentificationDoc doc) async {
    final String? attachment = await blobService.downloadIfMissing(
      docId: doc.id,
      field: 'attachment',
      key: doc.attachmentKey,
      localPath: doc.attachmentPath,
    );
    final String? front = await blobService.downloadIfMissing(
      docId: doc.id,
      field: 'photoFront',
      key: doc.photoFrontKey,
      localPath: doc.photoFrontPath,
    );
    final String? back = await blobService.downloadIfMissing(
      docId: doc.id,
      field: 'photoBack',
      key: doc.photoBackKey,
      localPath: doc.photoBackPath,
    );
    if (attachment == null && front == null && back == null) return;
    await applyingRemote(
      () => upsertId(doc.copyWith(
        attachmentPath: attachment ?? doc.attachmentPath,
        photoFrontPath: front ?? doc.photoFrontPath,
        photoBackPath: back ?? doc.photoBackPath,
      )),
    );
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
        attachmentKey: row.attachmentKey,
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
        attachmentKey: row.attachmentKey,
        agentName: row.agentName,
        alternateName: row.alternateName,
        scope: PoaScope.values.byName(row.scope),
        effectiveDate:
            DateTime.fromMillisecondsSinceEpoch(row.effectiveDateMs, isUtc: true),
        scanPath: row.scanPath,
        scanKey: row.scanKey,
      );

  IdentificationDoc _decodeId(IdentificationDocsTableData row) =>
      IdentificationDoc(
        id: row.id,
        patientId: row.patientId,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAtMs, isUtc: true),
        attachmentPath: row.attachmentPath,
        attachmentKey: row.attachmentKey,
        kind: IdKind.values.byName(row.kind),
        idNumber: row.idNumber,
        expiresOn: row.expiresOnMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row.expiresOnMs!, isUtc: true),
        photoFrontPath: row.photoFrontPath,
        photoBackPath: row.photoBackPath,
        photoFrontKey: row.photoFrontKey,
        photoBackKey: row.photoBackKey,
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
  return DocumentsRepository(
    db,
    // Moves scan image bytes to/from R2 on save / sync-apply. Resolves to
    // the no-op service in local-only / demo / test builds, so the document
    // flows behave exactly as before unless a backend is configured.
    blobService: ref.watch(documentBlobServiceProvider),
  );
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
