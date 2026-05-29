import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'journal_entries_provider.dart';

part 'pattern_detector_provider.g.dart';

/// Severity rung for a [PatternAlert] (BUILD_SPEC.md §5.5 + §7.6).
///
/// Drives the alert card's color treatment: [info] uses the brand's
/// soft navy; [warning] uses [careblazersColors.accentDeep] so the "3+
/// falls this week" rule lands with the visual weight the spec calls
/// for.
enum PatternSeverity { info, warning }

/// One alert surfaced on the journal screen's "Heads up" card
/// (BUILD_SPEC.md §5.5 + §7.6).
///
/// [kind] is a stable identifier (e.g. `falls_3plus_7d`) so tests +
/// future analytics can key off it without depending on the rendered
/// [text]. The real detection rules land in Task 18; this scaffold
/// keeps the shape so the screen renders end-to-end.
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

/// Pattern-detector hook for the journal screen (BUILD_SPEC.md §5.5 +
/// §7.6).
///
/// Stub. Task 18 lands the rules (3+ falls in 7 days, 5+ sundowning,
/// etc.) against [journalEntriesProvider] and replaces this body. The
/// `ref.watch` on the entries stream is here so a drop-in replacement
/// already wires up — without it, future detection logic wouldn't
/// recompute when the underlying journal changes.
@Riverpod(keepAlive: false)
List<PatternAlert> patternDetector(Ref ref) {
  ref.watch(journalEntriesProvider);
  return const <PatternAlert>[];
}
