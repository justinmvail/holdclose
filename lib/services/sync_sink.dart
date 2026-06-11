import 'dart:async';

/// Reusable enqueue seam for server-authoritative sync.
///
/// A repository (or the [StorageProvider]) holds one [SyncSink] and calls
/// it after every local write so the change can be routed into the sync
/// outbox. The sink has two shapes: [upsert] for a written model
/// (collection + id + the model's `toJson`) and [delete] for a tombstone
/// (collection + id). Both callbacks default to no-ops, so a repository
/// with no sink set behaves exactly as it always has — fully local. That
/// is the fail-safe default for tests, the demo, and any install not
/// bound to a care circle.
///
/// This is the generalisation of the original `MedicationSyncSink`; every
/// new synced repository reuses this one class rather than minting its own
/// per-family copy. The sync controller registers its
/// `enqueueUpsert`/`enqueueDelete` callbacks here at wiring time
/// (see `sync_service.dart`'s `syncController` provider).
class SyncSink {
  const SyncSink({this.onUpsert, this.onDelete});

  final void Function(
    String collection,
    String id,
    Map<String, dynamic> json,
  )? onUpsert;
  final void Function(String collection, String id)? onDelete;

  void upsert(String collection, String id, Map<String, dynamic> json) =>
      onUpsert?.call(collection, id, json);

  void delete(String collection, String id) => onDelete?.call(collection, id);
}

/// Mix into a repository to get the standard sync wiring for free:
///
///   - a settable [syncSink] field (defaults to a no-op [SyncSink]);
///   - an [applyingRemote] guard that suppresses the sink while a *pulled*
///     doc is being applied locally (the echo-loop guard — applying a
///     remote write must never re-enqueue it and bounce it back to the
///     server);
///   - [emitUpsert] / [emitDelete] helpers the repo's write methods call
///     after every local mutation. They no-op while [applyingRemote] is
///     active.
///
/// A repository registers in three steps:
///   1. `with SyncSinkHost` on the class.
///   2. call `emitUpsert(collection, id, model.toJson())` at the end of
///      every upsert, and `emitDelete(collection, id)` at the end of
///      every delete.
///   3. the `syncController` provider sets `repo.syncSink = SyncSink(...)`.
///
/// The apply dispatcher then wraps its local write in
/// `repo.applyingRemote(() => repo.upsertX(model))` so the pulled doc
/// lands without re-enqueuing.
mixin SyncSinkHost {
  /// Optional server-authoritative-sync sink. Set once at wiring time by
  /// the sync controller. Defaults to a no-op sink so a repository used in
  /// isolation — tests, the demo, a circle-less install — stays purely
  /// local.
  SyncSink syncSink = const SyncSink();

  /// Zone key marking "this async flow is applying a PULLED doc".
  ///
  /// Zone-scoped (2026-06-11), not a plain instance bool: [applyingRemote]
  /// awaits DB writes, and a USER save to the same repository can
  /// interleave on the event loop mid-apply. With an instance flag the
  /// interleaved local edit saw `suppress == true`, silently skipped its
  /// enqueue, and never reached the circle until the row was edited
  /// again. A zone value follows ONLY the apply's own async flow — the
  /// interleaved user write runs in the root zone and enqueues normally.
  static final Object _applyingRemoteZoneKey = Object();

  bool get _suppressSync => Zone.current[_applyingRemoteZoneKey] == true;

  /// Run [action] with the [syncSink] suppressed — used by the sync
  /// controller's apply dispatcher so applying a pulled write goes
  /// straight to local storage without re-enqueuing it.
  Future<T> applyingRemote<T>(Future<T> Function() action) {
    return runZoned<Future<T>>(
      action,
      zoneValues: <Object, Object>{_applyingRemoteZoneKey: true},
    );
  }

  /// Route a local upsert through the sink, unless we're applying a
  /// pulled doc.
  void emitUpsert(String collection, String id, Map<String, dynamic> json) {
    if (_suppressSync) return;
    syncSink.upsert(collection, id, json);
  }

  /// Route a local delete (tombstone) through the sink, unless we're
  /// applying a pulled doc.
  void emitDelete(String collection, String id) {
    if (_suppressSync) return;
    syncSink.delete(collection, id);
  }
}
