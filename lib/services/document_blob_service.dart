import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/sync_state_provider.dart';
import 'forum_api_client.dart';

part 'document_blob_service.g.dart';

/// Moves document-scan IMAGE BYTES (not just the metadata row) between the
/// device and the circle's R2 bucket, so a scan survives a reinstall and
/// shows up on every caregiver's phone.
///
/// The three document models ([EmergencyCard] / [PowerOfAttorneyDoc] /
/// [IdentificationDoc]) store on-device file paths plus a nullable R2 key
/// paralleling each path. This service is the seam that keeps the two in
/// step:
///
///  - On SAVE: [uploadIfNeeded] reads the local file's bytes and PUTs them
///    to the backend, returning the storage key to persist on the row.
///  - On SYNC APPLY (a doc pulled from another device): [downloadIfMissing]
///    GETs the blob by key and writes it into a local cache dir, returning
///    the new local path so the row's path field points at a real file.
///
/// **Fail-safe.** Every method is best-effort and returns null (rather than
/// throwing) on any failure — no circle, no backend, a network error, a
/// missing file. A null result means "nothing changed; keep the existing
/// path/key". Callers must NEVER let a blob op block a save or break sync.
abstract class DocumentBlobService {
  /// Upload [localPath]'s bytes for the document field identified by
  /// [docId]/[field] and return the storage key to persist.
  ///
  /// Returns [existingKey] unchanged when there's nothing to do (already
  /// uploaded, no path, no circle, no backend) and null when an upload was
  /// attempted but failed. Callers persist the returned value AS the row's
  /// key only when it's non-null; a null return leaves the prior key as-is.
  Future<String?> uploadIfNeeded({
    required String docId,
    required String field,
    required String? localPath,
    required String? existingKey,
  });

  /// Download the blob at [key] into the local cache when [localPath] is
  /// missing or absent on disk (i.e. the doc arrived from another device).
  /// Returns the local file path that now holds the bytes, or null when
  /// there's nothing to do / the download failed.
  Future<String?> downloadIfMissing({
    required String docId,
    required String field,
    required String? key,
    required String? localPath,
  });
}

/// No-op blob service: every method returns null ("nothing changed"). Used
/// in tests + local-only/demo builds where there's no backend to talk to,
/// so the document save / sync-apply paths behave exactly as they do today
/// (local path only).
class NoopDocumentBlobService implements DocumentBlobService {
  const NoopDocumentBlobService();

  @override
  Future<String?> uploadIfNeeded({
    required String docId,
    required String field,
    required String? localPath,
    required String? existingKey,
  }) async =>
      existingKey;

  @override
  Future<String?> downloadIfMissing({
    required String docId,
    required String field,
    required String? key,
    required String? localPath,
  }) async =>
      null;
}

/// Resolves the active care-circle id (null = local-only). Injected so
/// tests supply a constant instead of reaching through shared_preferences.
typedef CircleIdResolver = Future<String?> Function();

/// Resolves + creates the on-device directory document-scan blobs are
/// cached into after a pull. Injected so tests point it at a temp dir
/// instead of the real app-support dir.
typedef BlobCacheDirResolver = Future<Directory> Function();

Future<Directory> _defaultBlobCacheDir() async {
  final Directory support = await getApplicationSupportDirectory();
  final Directory dir = Directory('${support.path}/document_blobs');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Real [DocumentBlobService] over the [ForumApiClient] blob endpoints +
/// the local filesystem (server-authoritative sync follow-up).
///
/// The R2 object key per field is derived deterministically from
/// [docId]/[field] so re-saving the same field overwrites in place rather
/// than orphaning a blob. Bound to the active circle via [SyncStateStore];
/// with no circle (local-only) or no backend, every op short-circuits to
/// the no-op result.
class HttpDocumentBlobService implements DocumentBlobService {
  HttpDocumentBlobService({
    required ForumApiClient client,
    required CircleIdResolver circleId,
    BlobCacheDirResolver? cacheDir,
  })  : _client = client,
        _circleId = circleId,
        _cacheDir = cacheDir ?? _defaultBlobCacheDir;

  /// Wire the active care-circle id from a [SyncStateStore]. The id binds
  /// every blob to its circle's R2 namespace; null = local-only, so blob
  /// ops short-circuit.
  factory HttpDocumentBlobService.fromStateStore({
    required ForumApiClient client,
    required SyncStateStore stateStore,
    BlobCacheDirResolver? cacheDir,
  }) =>
      HttpDocumentBlobService(
        client: client,
        circleId: stateStore.getCircleId,
        cacheDir: cacheDir,
      );

  final ForumApiClient _client;
  final CircleIdResolver _circleId;
  final BlobCacheDirResolver _cacheDir;

  /// The per-field object name (the server prefixes the circle id). A safe,
  /// stable charset so it slots straight into the URL path the endpoint
  /// validates (`^[A-Za-z0-9._-]+$`).
  static String objectKey(String docId, String field) {
    final String safeDoc =
        docId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$safeDoc.$field';
  }

  /// Extract the per-field object name the GET endpoint expects from a full
  /// `documents/<circleId>/<objectName>` storage key (the value persisted on
  /// the row). Returns the input unchanged when it isn't a full key.
  static String objectNameFromStorageKey(String storageKey) {
    final int slash = storageKey.lastIndexOf('/');
    return slash < 0 ? storageKey : storageKey.substring(slash + 1);
  }

  @override
  Future<String?> uploadIfNeeded({
    required String docId,
    required String field,
    required String? localPath,
    required String? existingKey,
  }) async {
    // Already uploaded, or nothing to upload → leave the key as-is.
    if (existingKey != null && existingKey.isNotEmpty) return existingKey;
    if (localPath == null || localPath.isEmpty) return existingKey;
    try {
      final String? circleId = await _circleId();
      if (circleId == null) return existingKey; // local-only, nothing to sync to
      final File file = File(localPath);
      if (!await file.exists()) return existingKey;
      final List<int> bytes = await file.readAsBytes();
      if (bytes.isEmpty) return existingKey;
      return await _client.uploadDocumentBlob(
        circleId: circleId,
        key: objectKey(docId, field),
        bytes: bytes,
        contentType: _contentTypeFor(localPath),
      );
    } catch (_) {
      // Offline / backend unreachable / oversize — keep the local path
      // working; the next save retries the upload.
      return existingKey;
    }
  }

  @override
  Future<String?> downloadIfMissing({
    required String docId,
    required String field,
    required String? key,
    required String? localPath,
  }) async {
    if (key == null || key.isEmpty) return null; // no blob to fetch
    // Local file already present → no download needed.
    if (localPath != null &&
        localPath.isNotEmpty &&
        await File(localPath).exists()) {
      return null;
    }
    try {
      final String? circleId = await _circleId();
      if (circleId == null) return null;
      final List<int> bytes = await _client.downloadDocumentBlob(
        circleId: circleId,
        key: objectNameFromStorageKey(key),
      );
      if (bytes.isEmpty) return null;
      final Directory dir = await _cacheDir();
      final File out = File('${dir.path}/${objectKey(docId, field)}');
      await out.writeAsBytes(bytes, flush: true);
      return out.path;
    } catch (_) {
      // Offline / 404 / write error — the row keeps its (missing) path; a
      // later sync tick retries.
      return null;
    }
  }

  static String _contentTypeFor(String path) {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'application/octet-stream';
  }
}

/// Riverpod-wired [DocumentBlobService] (server-authoritative sync
/// follow-up). Resolves to the real HTTP service only when a backend URL is
/// baked into the build; otherwise the no-op service keeps the app fully
/// local (tests, demo, local-only alpha) — matching how
/// [forumApiClientProvider] falls back to the fake client.
@Riverpod(keepAlive: true)
DocumentBlobService documentBlobService(Ref ref) {
  if (!forumBackendConfigured) {
    return const NoopDocumentBlobService();
  }
  return HttpDocumentBlobService.fromStateStore(
    client: ref.watch(forumApiClientProvider),
    stateStore: ref.watch(syncStateStoreProvider),
  );
}
