import 'dart:io';

import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/document.dart';
import 'package:holdclose/providers/documents_provider.dart';
import 'package:holdclose/services/document_blob_service.dart';
import 'package:holdclose/services/fake_forum_api_client.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

EmergencyCard _card({
  required String id,
  String patientId = 'mary',
  DateTime? updatedAt,
  List<String> conditions = const <String>['Alzheimer\'s'],
  List<EmergencyContact> contacts = const <EmergencyContact>[
    EmergencyContact(name: 'Sarah', relation: 'Daughter', phone: '555-0100'),
  ],
  String? attachmentPath,
}) =>
    EmergencyCard(
      id: id,
      patientId: patientId,
      updatedAt: updatedAt ?? DateTime.utc(2026, 6, 1, 9),
      conditions: conditions,
      medications: const <String>['Donepezil 10 mg'],
      allergies: const <String>['Penicillin'],
      emergencyContacts: contacts,
      insurance: const Insurance(
        carrier: 'Medicare',
        policyNumber: '1EG4-TE5-MK72',
        groupNumber: 'GRP-001',
      ),
      donorStatus: DonorStatus.donor,
      attachmentPath: attachmentPath,
    );

PowerOfAttorneyDoc _poa({
  required String id,
  String patientId = 'mary',
  DateTime? updatedAt,
}) =>
    PowerOfAttorneyDoc(
      id: id,
      patientId: patientId,
      updatedAt: updatedAt ?? DateTime.utc(2026, 6, 1, 9),
      agentName: 'Sarah Henderson',
      alternateName: 'Mark Henderson',
      scope: PoaScope.medical,
      effectiveDate: DateTime.utc(2024, 1, 15),
      scanPath: '/docs/poa.pdf',
    );

IdentificationDoc _id({
  required String id,
  String patientId = 'mary',
  DateTime? updatedAt,
  DateTime? expiresOn,
}) =>
    IdentificationDoc(
      id: id,
      patientId: patientId,
      updatedAt: updatedAt ?? DateTime.utc(2026, 6, 1, 9),
      kind: IdKind.driverLicense,
      idNumber: 'D1234567',
      expiresOn: expiresOn,
      photoFrontPath: '/docs/front.jpg',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---- Repository CRUD via the in-memory ("fake") database --------------

  group('DocumentsRepository — Phase 14.21 (in-memory DB)', () {
    late HoldcloseDatabase db;
    late DocumentsRepository repo;

    setUp(() {
      db = HoldcloseDatabase(NativeDatabase.memory());
      repo = DocumentsRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('emergency card upsert + getById round-trips through SQLite',
        () async {
      final EmergencyCard card =
          _card(id: 'ec-1', attachmentPath: '/docs/ec.pdf');
      await repo.upsertEmergencyCard(card);
      expect(await repo.getEmergencyCard('ec-1'), equals(card));
    });

    test('JSON list + nested structures survive the column boundary',
        () async {
      final EmergencyCard card = _card(
        id: 'ec-json',
        conditions: const <String>['A', 'B', 'C'],
        contacts: const <EmergencyContact>[
          EmergencyContact(name: 'X', relation: 'Son', phone: '1'),
          EmergencyContact(name: 'Y', relation: 'Nurse', phone: '2'),
        ],
      );
      await repo.upsertEmergencyCard(card);

      final EmergencyCard restored = (await repo.getEmergencyCard('ec-json'))!;
      // The three string lists survive verbatim.
      expect(restored.conditions, <String>['A', 'B', 'C']);
      expect(restored.medications, <String>['Donepezil 10 mg']);
      expect(restored.allergies, <String>['Penicillin']);
      // The nested objects survive verbatim.
      expect(restored.emergencyContacts.map((EmergencyContact c) => c.name),
          <String>['X', 'Y']);
      expect(restored.insurance.carrier, 'Medicare');
      expect(restored, equals(card));
    });

    test('empty string lists survive the boundary', () async {
      final EmergencyCard card = _card(id: 'ec-empty', conditions: const []);
      await repo.upsertEmergencyCard(card);
      expect((await repo.getEmergencyCard('ec-empty'))!.conditions, isEmpty);
    });

    test('getEmergencyCard returns null for an unknown id', () async {
      expect(await repo.getEmergencyCard('nope'), isNull);
    });

    test('upsert replaces an existing card by id (update path)', () async {
      await repo.upsertEmergencyCard(_card(id: 'ec-1'));
      final EmergencyCard edited =
          _card(id: 'ec-1').copyWith(donorStatus: DonorStatus.notDonor);
      await repo.upsertEmergencyCard(edited);

      expect((await repo.getEmergencyCard('ec-1'))!.donorStatus,
          DonorStatus.notDonor);
      expect(await repo.listEmergencyCards(), hasLength(1));
    });

    test('deleteEmergencyCard removes the row; no-op for a missing id',
        () async {
      await repo.upsertEmergencyCard(_card(id: 'ec-1'));
      await repo.deleteEmergencyCard('ec-1');
      expect(await repo.getEmergencyCard('ec-1'), isNull);
      // Harmless second delete.
      await repo.deleteEmergencyCard('ec-1');
      expect(await repo.listEmergencyCards(), isEmpty);
    });

    test('listEmergencyCards is newest-first; byPatient filters', () async {
      await repo
          .upsertEmergencyCard(_card(id: 'old', updatedAt: DateTime.utc(2026, 6, 1, 8)));
      await repo.upsertEmergencyCard(
          _card(id: 'new', updatedAt: DateTime.utc(2026, 6, 1, 20)));
      await repo.upsertEmergencyCard(_card(
          id: 'john', patientId: 'john', updatedAt: DateTime.utc(2026, 6, 1, 12)));

      expect((await repo.listEmergencyCards()).map((EmergencyCard c) => c.id),
          <String>['new', 'john', 'old']);
      expect((await repo.emergencyCardsByPatient('mary'))
              .map((EmergencyCard c) => c.id),
          <String>['new', 'old']);
      expect(await repo.emergencyCardsByPatient('nobody'), isEmpty);
    });

    test('POA CRUD + optional expiresOn-free round-trip', () async {
      final PowerOfAttorneyDoc doc = _poa(id: 'poa-1');
      await repo.upsertPoa(doc);
      expect(await repo.getPoa('poa-1'), equals(doc));

      await repo.upsertPoa(_poa(id: 'poa-2', patientId: 'john'));
      expect((await repo.listPoa()).map((PowerOfAttorneyDoc d) => d.id),
          containsAll(<String>['poa-1', 'poa-2']));
      expect((await repo.poaByPatient('mary')).single.id, 'poa-1');

      await repo.deletePoa('poa-1');
      expect(await repo.getPoa('poa-1'), isNull);
    });

    test('ID doc CRUD; nullable expiresOn round-trips both ways', () async {
      final IdentificationDoc withExpiry =
          _id(id: 'id-1', expiresOn: DateTime.utc(2028, 3, 1));
      final IdentificationDoc noExpiry = _id(id: 'id-2');
      await repo.upsertId(withExpiry);
      await repo.upsertId(noExpiry);

      expect((await repo.getId('id-1'))!.expiresOn, DateTime.utc(2028, 3, 1));
      expect((await repo.getId('id-2'))!.expiresOn, isNull);
      expect(await repo.getId('id-1'), equals(withExpiry));

      await repo.upsertId(_id(id: 'id-3', patientId: 'john'));
      expect((await repo.idsByPatient('mary')).map((IdentificationDoc d) => d.id),
          containsAll(<String>['id-1', 'id-2']));
      expect((await repo.idsByPatient('john')).single.id, 'id-3');
    });
  });

  // ---- Notifiers: CRUD + selectors --------------------------------------

  group('Documents notifiers — Phase 14.21', () {
    late HoldcloseDatabase db;

    ProviderContainer makeContainer() {
      db = HoldcloseDatabase(NativeDatabase.memory());
      final DocumentsRepository repo = DocumentsRepository(db);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          documentsRepositoryProvider.overrideWithValue(repo),
        ],
      );
      container
        ..listen(emergencyCardsProvider, (_, __) {}, fireImmediately: true)
        ..listen(powerOfAttorneyDocsProvider, (_, __) {}, fireImmediately: true)
        ..listen(identificationDocsProvider, (_, __) {}, fireImmediately: true);
      return container;
    }

    tearDown(() async {
      await db.close();
    });

    test('EmergencyCards build/add/updateCard/delete + byPatient', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      expect(await container.read(emergencyCardsProvider.future), isEmpty);

      final EmergencyCards notifier =
          container.read(emergencyCardsProvider.notifier);
      await notifier.add(_card(id: 'ec-1'));
      await notifier.add(_card(id: 'ec-john', patientId: 'john'));
      expect(container.read(emergencyCardsProvider).requireValue, hasLength(2));

      await notifier
          .updateCard(_card(id: 'ec-1').copyWith(donorStatus: DonorStatus.unknown));
      expect(
        container
            .read(emergencyCardsProvider)
            .requireValue
            .firstWhere((EmergencyCard c) => c.id == 'ec-1')
            .donorStatus,
        DonorStatus.unknown,
      );

      expect(notifier.byPatient('mary').map((EmergencyCard c) => c.id),
          <String>['ec-1']);
      expect(notifier.byPatient('john').map((EmergencyCard c) => c.id),
          <String>['ec-john']);

      await notifier.delete('ec-1');
      expect(container.read(emergencyCardsProvider).requireValue
              .map((EmergencyCard c) => c.id),
          <String>['ec-john']);
    });

    test('PowerOfAttorneyDocs build/add/updateDoc/delete + byPatient',
        () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final PowerOfAttorneyDocs notifier =
          container.read(powerOfAttorneyDocsProvider.notifier);
      await notifier.add(_poa(id: 'poa-1'));
      expect(container.read(powerOfAttorneyDocsProvider).requireValue.single,
          equals(_poa(id: 'poa-1')));

      await notifier
          .updateDoc(_poa(id: 'poa-1').copyWith(scope: PoaScope.financial));
      expect(
          container.read(powerOfAttorneyDocsProvider).requireValue.single.scope,
          PoaScope.financial);

      expect(notifier.byPatient('mary'), hasLength(1));
      expect(notifier.byPatient('nobody'), isEmpty);

      await notifier.delete('poa-1');
      expect(container.read(powerOfAttorneyDocsProvider).requireValue, isEmpty);
    });

    test('IdentificationDocs build/add/updateDoc/delete + byPatient', () async {
      final ProviderContainer container = makeContainer();
      addTearDown(container.dispose);

      final IdentificationDocs notifier =
          container.read(identificationDocsProvider.notifier);
      await notifier.add(_id(id: 'id-1'));
      expect(container.read(identificationDocsProvider).requireValue.single,
          equals(_id(id: 'id-1')));

      await notifier
          .updateDoc(_id(id: 'id-1').copyWith(idNumber: 'CHANGED'));
      expect(
          container.read(identificationDocsProvider).requireValue.single.idNumber,
          'CHANGED');

      expect(notifier.byPatient('mary'), hasLength(1));

      await notifier.delete('id-1');
      expect(container.read(identificationDocsProvider).requireValue, isEmpty);
    });
  });

  // ---- Document scan blobs (R2) via the blob service ---------------------

  group('DocumentsRepository blob upload on save + hydrate on sync-apply', () {
    late HoldcloseDatabase db;
    late Directory tmp;
    late FakeForumBackend backend;
    late FakeForumApiClient client;
    late DocumentsRepository repo;

    setUp(() {
      db = HoldcloseDatabase(NativeDatabase.memory());
      tmp = Directory.systemTemp.createTempSync('doc_repo_blob_');
      backend = FakeForumBackend();
      client = FakeForumApiClient(backend: backend);
      repo = DocumentsRepository(
        db,
        blobService: HttpDocumentBlobService(
          client: client,
          circleId: () async => 'circle-1',
          cacheDir: () async => tmp,
        ),
      );
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('upsert uploads the scan bytes and stores the returned key',
        () async {
      final File scan = File('${tmp.path}/front.jpg')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await repo.upsertId(_id(id: 'id-1').copyWith(photoFrontPath: scan.path));

      final IdentificationDoc stored = (await repo.getId('id-1'))!;
      expect(stored.photoFrontKey, 'documents/circle-1/id-1.photoFront');
      // The bytes actually landed in the (fake) bucket.
      expect(backend.docBlobs[stored.photoFrontKey], <int>[1, 2, 3]);
    });

    test('hydrate downloads a blob the row has a key for but no local file',
        () async {
      // Simulate the doc arriving from another device: a key is set, the
      // referenced local file does not exist on THIS device.
      backend.docBlobs['documents/circle-1/id-2.photoFront'] = <int>[7, 8, 9];
      final IdentificationDoc pulled = _id(id: 'id-2').copyWith(
        photoFrontPath: '/some/other/device/front.jpg',
        photoFrontKey: 'documents/circle-1/id-2.photoFront',
      );
      await repo.applyingRemote(() => repo.upsertId(pulled));

      await repo.hydrateIdBlobs(pulled);

      final IdentificationDoc hydrated = (await repo.getId('id-2'))!;
      expect(hydrated.photoFrontPath, isNot('/some/other/device/front.jpg'));
      expect(File(hydrated.photoFrontPath!).readAsBytesSync(),
          <int>[7, 8, 9]);
    });

    test('save → key stored, then a second device hydrates the same bytes',
        () async {
      final File scan = File('${tmp.path}/scan.pdf')
        ..writeAsBytesSync(<int>[42]);
      await repo.upsertPoa(_poa(id: 'poa-1').copyWith(scanPath: scan.path));
      final PowerOfAttorneyDoc saved = (await repo.getPoa('poa-1'))!;
      expect(saved.scanKey, isNotNull);

      // A second device: separate DB + cache dir, SAME backend.
      final HoldcloseDatabase db2 =
          HoldcloseDatabase(NativeDatabase.memory());
      addTearDown(() => db2.close());
      final Directory tmp2 = Directory.systemTemp.createTempSync('doc_b_');
      addTearDown(() => tmp2.deleteSync(recursive: true));
      final DocumentsRepository repo2 = DocumentsRepository(
        db2,
        blobService: HttpDocumentBlobService(
          client: FakeForumApiClient(backend: backend),
          circleId: () async => 'circle-1',
          cacheDir: () async => tmp2,
        ),
      );
      // The pulled doc carries the key but the path points at device A.
      final PowerOfAttorneyDoc pulled = saved.copyWith(
        scanPath: '/device-a/scan.pdf',
      );
      await repo2.applyingRemote(() => repo2.upsertPoa(pulled));
      await repo2.hydratePoaBlobs(pulled);

      final PowerOfAttorneyDoc hydrated = (await repo2.getPoa('poa-1'))!;
      expect(File(hydrated.scanPath!).readAsBytesSync(), <int>[42]);
    });
  });
}
