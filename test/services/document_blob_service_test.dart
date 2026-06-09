import 'dart:io';

import 'package:careblazers/services/document_blob_service.dart';
import 'package:careblazers/services/fake_forum_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late FakeForumBackend backend;
  late FakeForumApiClient client;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('doc_blob_test_');
    backend = FakeForumBackend();
    client = FakeForumApiClient(backend: backend);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  HttpDocumentBlobService service({
    String? circleId = 'circle-1',
    Directory? cacheDir,
  }) =>
      HttpDocumentBlobService(
        client: client,
        circleId: () async => circleId,
        cacheDir: () async => cacheDir ?? tmp,
      );

  File writeFile(String name, List<int> bytes) {
    final File f = File('${tmp.path}/$name')..writeAsBytesSync(bytes);
    return f;
  }

  group('uploadIfNeeded', () {
    test('uploads the file bytes and returns the full storage key', () async {
      final File f = writeFile('front.jpg', <int>[1, 2, 3, 4]);
      final String? key = await service().uploadIfNeeded(
        docId: 'id-1',
        field: 'photoFront',
        localPath: f.path,
        existingKey: null,
      );
      expect(key, 'documents/circle-1/id-1.photoFront');
      // The bytes actually landed in the (fake) bucket.
      expect(backend.docBlobs[key], <int>[1, 2, 3, 4]);
    });

    test('is a no-op when a key already exists (returns it unchanged)',
        () async {
      final File f = writeFile('front.jpg', <int>[9]);
      final String? key = await service().uploadIfNeeded(
        docId: 'id-1',
        field: 'photoFront',
        localPath: f.path,
        existingKey: 'documents/circle-1/already',
      );
      expect(key, 'documents/circle-1/already');
      expect(backend.docBlobs, isEmpty); // never uploaded
    });

    test('skips (keeps existing key) when there is no circle — local-only',
        () async {
      final File f = writeFile('front.jpg', <int>[1]);
      final String? key = await service(circleId: null).uploadIfNeeded(
        docId: 'id-1',
        field: 'photoFront',
        localPath: f.path,
        existingKey: null,
      );
      expect(key, isNull);
      expect(backend.docBlobs, isEmpty);
    });

    test('skips when the local path is null', () async {
      final String? key = await service().uploadIfNeeded(
        docId: 'id-1',
        field: 'photoFront',
        localPath: null,
        existingKey: null,
      );
      expect(key, isNull);
      expect(backend.docBlobs, isEmpty);
    });

    test('skips when the local file is missing on disk', () async {
      final String? key = await service().uploadIfNeeded(
        docId: 'id-1',
        field: 'photoFront',
        localPath: '${tmp.path}/does-not-exist.jpg',
        existingKey: null,
      );
      expect(key, isNull);
      expect(backend.docBlobs, isEmpty);
    });
  });

  group('downloadIfMissing', () {
    test('downloads the blob to the cache dir and returns the new path',
        () async {
      // Seed the fake bucket as if another device uploaded it.
      backend.docBlobs['documents/circle-1/id-1.photoFront'] =
          <int>[5, 6, 7];
      final String? path = await service().downloadIfMissing(
        docId: 'id-1',
        field: 'photoFront',
        key: 'documents/circle-1/id-1.photoFront',
        localPath: null,
      );
      expect(path, isNotNull);
      expect(File(path!).readAsBytesSync(), <int>[5, 6, 7]);
    });

    test('is a no-op when the local file already exists', () async {
      final File existing = writeFile('have.jpg', <int>[1]);
      backend.docBlobs['documents/circle-1/id-1.photoFront'] = <int>[2];
      final String? path = await service().downloadIfMissing(
        docId: 'id-1',
        field: 'photoFront',
        key: 'documents/circle-1/id-1.photoFront',
        localPath: existing.path,
      );
      expect(path, isNull); // already present, nothing fetched
    });

    test('returns null when the key is null', () async {
      final String? path = await service().downloadIfMissing(
        docId: 'id-1',
        field: 'photoFront',
        key: null,
        localPath: null,
      );
      expect(path, isNull);
    });

    test('returns null (fail-safe) when the blob is absent — 404', () async {
      final String? path = await service().downloadIfMissing(
        docId: 'id-1',
        field: 'photoFront',
        key: 'documents/circle-1/missing',
        localPath: null,
      );
      expect(path, isNull);
    });

    test('returns null when there is no circle', () async {
      backend.docBlobs['documents/circle-1/id-1.photoFront'] = <int>[5];
      final String? path = await service(circleId: null).downloadIfMissing(
        docId: 'id-1',
        field: 'photoFront',
        key: 'documents/circle-1/id-1.photoFront',
        localPath: null,
      );
      expect(path, isNull);
    });
  });

  group('round-trip across two devices (one shared backend)', () {
    test('device A uploads, device B downloads the same bytes', () async {
      // Device A: a fresh service over the same backend uploads a scan.
      final File f = writeFile('scan.pdf', <int>[10, 20, 30]);
      final String? key = await service().uploadIfNeeded(
        docId: 'poa-1',
        field: 'scan',
        localPath: f.path,
        existingKey: null,
      );
      // Device B: a different cache dir, same backend, file not on disk yet.
      final Directory deviceBCache =
          Directory.systemTemp.createTempSync('doc_blob_b_');
      addTearDown(() => deviceBCache.deleteSync(recursive: true));
      final String? path = await service(cacheDir: deviceBCache)
          .downloadIfMissing(
        docId: 'poa-1',
        field: 'scan',
        key: key,
        localPath: null,
      );
      expect(path, isNotNull);
      expect(File(path!).readAsBytesSync(), <int>[10, 20, 30]);
    });
  });
}
