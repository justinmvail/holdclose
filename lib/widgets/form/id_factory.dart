import 'dart:math' as math;

/// Mint a unique row id in the app-wide `'<prefix>-<ms>-<rand>'` shape
/// (or `'<ms>-<rand>'` when [prefix] is empty — the appointment +
/// medication forms' historical shape).
///
/// [clock] overrides "now" so a caller can pin the millisecond stamp to
/// a moment it already captured (e.g. the entry's `createdAt`). The
/// random tail stays non-injectable — tests that need fully
/// deterministic ids override the screen-level id-factory provider
/// instead, exactly as before.
String mintId(String prefix, {DateTime Function()? clock}) {
  final int ms = (clock ?? DateTime.now)().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return prefix.isEmpty ? '$ms-$rand' : '$prefix-$ms-$rand';
}
