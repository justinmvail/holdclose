import 'package:flutter/foundation.dart';

import '../models/journal_entry.dart';

/// Severity rung for a [PatternAlert] (BUILD_SPEC.md §5.5 + §7.6).
///
/// Drives the alert card's color treatment: [info] uses the brand's soft
/// navy; [warning] uses `careblazersColors.accentDeep` so the "3+ falls
/// this week" rule lands with the visual weight the spec calls for.
enum PatternSeverity { info, warning }

/// One alert surfaced on the journal screen's "Heads up" card
/// (BUILD_SPEC.md §5.5 + §7.6).
///
/// [kind] is a stable identifier (e.g. `falls_3plus_7d`) so tests and
/// any future analytics can key off it without depending on the
/// rendered [text].
@immutable
class PatternAlert {
  const PatternAlert({
    required this.kind,
    required this.text,
    required this.severity,
  });

  final String kind;
  final String text;
  final PatternSeverity severity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PatternAlert &&
          other.kind == kind &&
          other.text == text &&
          other.severity == severity);

  @override
  int get hashCode => Object.hash(kind, text, severity);
}

/// Pattern detector for the journal screen (BUILD_SPEC.md §7.6).
///
/// Pure function over a list of journal entries — no I/O, no riverpod.
/// The riverpod-wired hook lives in `providers/pattern_detector_provider`
/// which feeds the current journal window + clock through to [detect].
///
/// Three v1 rules:
///
/// * **3+ falls in 7 days** — naive substring match for `fall` or `fell`
///   inside each entry's `result.tweak` or `notes`. Future: a structured
///   tag on the entry rather than a text scan.
/// * **5+ sundowning entries in 7 days** — counts entries whose
///   `behavior.id` is `sundowning`.
/// * **3+ distinct new behaviors in 14 days** — a behavior id is "new"
///   when its earliest appearance in the supplied entries is within the
///   14-day window. The supplied list is the journal window (currently
///   30 days), so "first appearance" is a within-window proxy for "first
///   appearance in the patient's history".
///
/// The UTI red-flag rule from BUILD_SPEC.md §7.6 is deliberately out of
/// scope for v1 — it requires structured tags the journal entry model
/// doesn't carry yet.
class PatternDetector {
  const PatternDetector();

  static const Duration _shortWindow = Duration(days: 7);
  static const Duration _longWindow = Duration(days: 14);

  /// Run every rule against [entries] anchored at [now]. Returns the
  /// alerts in a stable order: falls → sundowning → new-behaviors. The
  /// journal screen renders them top-to-bottom in that order.
  List<PatternAlert> detect(
    List<JournalEntry> entries, {
    required DateTime now,
  }) {
    final List<PatternAlert> alerts = <PatternAlert>[
      if (_detectFalls(entries, now) case final PatternAlert a) a,
      if (_detectSundowning(entries, now) case final PatternAlert a) a,
      if (_detectNewBehaviors(entries, now) case final PatternAlert a) a,
    ];
    return List<PatternAlert>.unmodifiable(alerts);
  }

  PatternAlert? _detectFalls(List<JournalEntry> entries, DateTime now) {
    final DateTime cutoff = now.subtract(_shortWindow);
    int count = 0;
    for (final JournalEntry e in entries) {
      if (!e.createdAt.isAfter(cutoff)) continue;
      if (_mentionsFall(e)) count += 1;
    }
    if (count < 3) return null;
    return const PatternAlert(
      kind: 'falls_3plus_7d',
      text: '3+ falls this week. Worth mentioning at the next visit.',
      severity: PatternSeverity.warning,
    );
  }

  PatternAlert? _detectSundowning(List<JournalEntry> entries, DateTime now) {
    final DateTime cutoff = now.subtract(_shortWindow);
    int count = 0;
    for (final JournalEntry e in entries) {
      if (!e.createdAt.isAfter(cutoff)) continue;
      if (e.behavior.id == 'sundowning') count += 1;
    }
    if (count < 5) return null;
    return const PatternAlert(
      kind: 'sundowning_5plus_7d',
      text: 'Sundowning is hitting hard this week. '
          'Talk to your doctor about evening routines.',
      severity: PatternSeverity.warning,
    );
  }

  PatternAlert? _detectNewBehaviors(
    List<JournalEntry> entries,
    DateTime now,
  ) {
    final DateTime cutoff = now.subtract(_longWindow);
    final Map<String, DateTime> firstSeen = <String, DateTime>{};
    for (final JournalEntry e in entries) {
      final DateTime? prior = firstSeen[e.behavior.id];
      if (prior == null || e.createdAt.isBefore(prior)) {
        firstSeen[e.behavior.id] = e.createdAt;
      }
    }
    int newCount = 0;
    for (final DateTime ts in firstSeen.values) {
      if (ts.isAfter(cutoff)) newCount += 1;
    }
    if (newCount < 3) return null;
    return const PatternAlert(
      kind: 'new_behaviors_3plus_14d',
      text: 'Multiple new behaviors this week. '
          'Worth a check-in with the doctor.',
      severity: PatternSeverity.warning,
    );
  }

  /// Naive fall-mention probe: case-insensitive substring scan over the
  /// entry's `notes` and every `tweak` line of its decoder result. The
  /// scope-creep risks ("fallow", "fellow") are accepted in v1 — see
  /// BUILD_SPEC.md §7.6 ("naive in v1: matches text 'fall' or 'fell'").
  bool _mentionsFall(JournalEntry e) {
    final String? notes = e.notes;
    if (notes != null && _hasFallToken(notes)) return true;
    for (final String t in e.result.tweak) {
      if (_hasFallToken(t)) return true;
    }
    return false;
  }

  bool _hasFallToken(String s) {
    final String lower = s.toLowerCase();
    return lower.contains('fall') || lower.contains('fell');
  }
}
