import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'sync_state_provider.g.dart';

/// shared_preferences key holding the active care-circle id
/// (server-authoritative sync). Null/absent = "not in a circle" =
/// fully local, sync no-ops everywhere.
const String syncCircleIdPrefsKey = 'careblazers.sync.circle_id';

/// Prefix for the per-circle pull cursor (`...<circleId>` → int rev).
/// Defaults to 0 (pull everything) when absent.
const String syncCursorPrefsKeyPrefix = 'careblazers.sync.cursor.';

/// Durable store for the sync engine's small bits of cross-launch state:
/// which care circle this install is bound to, and how far each circle's
/// pull cursor has advanced (server-authoritative sync). Backed by
/// shared_preferences so the choice survives a relaunch — no drift/schema
/// coupling, mirroring [TesterNameStore] / [FeedbackButtonStore].
///
/// Every method is best-effort and never throws to the caller: a missing
/// circle id simply means "local-only", which is the fail-safe default.
class SyncStateStore {
  const SyncStateStore();

  /// The active care-circle id, or null when this install isn't bound to
  /// a circle (the local-only default).
  Future<String?> getCircleId() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? v = prefs.getString(syncCircleIdPrefsKey)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Bind this install to [circleId]. Pass null/empty to clear (back to
  /// local-only).
  Future<void> setCircleId(String? circleId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (circleId == null || circleId.trim().isEmpty) {
      await prefs.remove(syncCircleIdPrefsKey);
      return;
    }
    await prefs.setString(syncCircleIdPrefsKey, circleId.trim());
  }

  String _cursorKey(String circleId) =>
      '$syncCursorPrefsKeyPrefix$circleId';

  /// The persisted pull cursor for [circleId] (the highest rev applied so
  /// far). Defaults to 0 — "pull everything" — when never stored.
  Future<int> getCursor(String circleId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_cursorKey(circleId)) ?? 0;
  }

  /// Persist the pull cursor for [circleId].
  Future<void> setCursor(String circleId, int cursor) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_cursorKey(circleId), cursor);
  }
}

/// Riverpod-wired [SyncStateStore]. `keepAlive: true` so the controller
/// and bootstrap share one instance per session.
@Riverpod(keepAlive: true)
SyncStateStore syncStateStore(Ref ref) => const SyncStateStore();
