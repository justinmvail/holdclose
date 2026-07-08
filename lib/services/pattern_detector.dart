import 'package:flutter/foundation.dart';

import '../models/journal_entry.dart';

/// Severity rung for a [PatternAlert] (BUILD_SPEC.md §5.5 + §7.6).
///
/// Drives the alert card's color treatment: [info] uses the brand's soft
/// navy; [warning] uses `context.hc.accentDeep` so the "3+ falls this
/// week" rule lands with the visual weight the spec calls for.
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
/// One v1 rule:
///
/// * **3+ falls in 7 days** — naive substring match for `fall` or `fell`
///   inside each entry's free text (situation / attempts / notes).
///   Future: a structured tag on the entry rather than a text scan.
///
/// The behavior-keyed rules (sundowning bursts, new-behavior spikes) were
/// retired with the behavior decoder — journal entries are now free text,
/// so there is no canonical behavior id to count. The UTI red-flag rule
/// from BUILD_SPEC.md §7.6 remains out of scope: it needs structured tags
/// the entry model doesn't carry.
class PatternDetector {
  const PatternDetector();

  static const Duration _shortWindow = Duration(days: 7);

  /// Run every rule against [entries] anchored at [now].
  List<PatternAlert> detect(
    List<JournalEntry> entries, {
    required DateTime now,
  }) {
    final List<PatternAlert> alerts = <PatternAlert>[
      if (_detectFalls(entries, now) case final PatternAlert a) a,
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

  /// Naive fall-mention probe: case-insensitive substring scan over the
  /// entry's free-text fields. The scope-creep risks ("fallow", "fellow")
  /// are accepted in v1 — see BUILD_SPEC.md §7.6 ("naive in v1: matches
  /// text 'fall' or 'fell'").
  bool _mentionsFall(JournalEntry e) {
    for (final String? field in <String?>[
      e.situationText,
      e.attemptsText,
      e.notes,
    ]) {
      if (field != null && _hasFallToken(field)) return true;
    }
    return false;
  }

  bool _hasFallToken(String s) {
    final String lower = s.toLowerCase();
    return lower.contains('fall') || lower.contains('fell');
  }
}
