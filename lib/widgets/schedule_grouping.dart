import 'package:flutter/foundation.dart';

import '../models/care_event.dart';

/// A folded medication window for the schedule surfaces — every dose that
/// shares one window slot on one calendar day, collapsed into a single
/// row headed by the window name + anchor time with the medications listed
/// beneath.
///
/// Shared by the Home **Schedule** card and the Care Team **Calendar** so
/// both read medications the same way: "Morning Medication · 8:00 AM"
/// with each med + its taken/pending status, instead of one row per dose.
@immutable
class DoseWindowGroup {
  const DoseWindowGroup({
    required this.start,
    required this.meds,
    required this.firstEventId,
    required this.windowLabel,
  });

  /// The window's effective time — its anchored slot when known, used as
  /// both the header time and the past/future cutoff so a late-logged
  /// dose still reads at its window's hour.
  final DateTime start;

  /// Per-medication status in the window, alphabetical by name.
  final List<({String name, bool taken})> meds;

  /// The first event's id, used as a stable key for tests/hits.
  final String firstEventId;

  /// The dose window's name ("Morning", "Evening"), or null for a dose
  /// event that predates window scheduling — then the header falls back
  /// to the bare time.
  final String? windowLabel;

  /// True when every dose in the window has already been logged.
  bool get allLogged => meds.every((({String name, bool taken}) m) => m.taken);
}

/// One row in a grouped schedule: either a passthrough [CareEvent]
/// ([EventRow]) or a folded medication window ([DoseGroupRow]).
sealed class ScheduleRow {
  const ScheduleRow();
}

/// A non-dose event (appointment, task, journal, …) that renders as-is.
class EventRow extends ScheduleRow {
  const EventRow(this.event);
  final CareEvent event;
}

/// A folded medication window.
class DoseGroupRow extends ScheduleRow {
  const DoseGroupRow(this.group);
  final DoseWindowGroup group;
}

/// Group consecutive dose events (doseScheduled / doseLogged) that belong
/// to the same dose window on the same calendar day — so the Morning meds
/// list under one "Morning · 8:00 AM" header even when one was logged a
/// few minutes off its anchor. A dose event with no [CareEvent.windowLabel]
/// (legacy data) falls back to grouping by exact wall-clock minute. Other
/// event kinds pass through in their original order.
///
/// Ordering is by **effective time** — a dose sits at its window slot
/// (anchor), not its logged time — so a dose given late still lists under
/// its window's place in the day; non-dose events keep their own start.
List<ScheduleRow> groupDoseEventsByWindow(List<CareEvent> events) {
  final List<CareEvent> ordered = List<CareEvent>.of(events)
    ..sort((CareEvent a, CareEvent b) =>
        _effectiveTime(a).compareTo(_effectiveTime(b)));

  final List<ScheduleRow> out = <ScheduleRow>[];
  int i = 0;
  while (i < ordered.length) {
    final CareEvent e = ordered[i];
    if (!_isDose(e)) {
      out.add(EventRow(e));
      i++;
      continue;
    }
    final String groupKey = _doseGroupKey(e);
    int j = i;
    // Aggregate per-medication taken status: a medication counts as taken
    // if ANY event in the window is doseLogged for it.
    final Map<String, bool> takenByName = <String, bool>{};
    while (j < ordered.length) {
      final CareEvent c = ordered[j];
      if (!_isDose(c)) break;
      if (_doseGroupKey(c) != groupKey) break;
      final bool taken = c.kind == CareEventKind.doseLogged;
      takenByName.update(c.title, (bool prev) => prev || taken,
          ifAbsent: () => taken);
      j++;
    }
    final List<({String name, bool taken})> meds = takenByName.entries
        .map((MapEntry<String, bool> e) => (name: e.key, taken: e.value))
        .toList()
      ..sort((({String name, bool taken}) a, ({String name, bool taken}) b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    out.add(DoseGroupRow(DoseWindowGroup(
      start: _effectiveTime(e),
      meds: meds,
      firstEventId: e.id,
      windowLabel: e.windowLabel,
    )));
    i = j;
  }
  return out;
}

bool _isDose(CareEvent e) =>
    e.kind == CareEventKind.doseScheduled ||
    e.kind == CareEventKind.doseLogged;

/// The time a dose [event] occupies in the schedule — its window slot
/// (anchor) when known, else its raw [CareEvent.start]. Keeps a
/// late-logged dose anchored to its window's place in the day.
DateTime _effectiveTime(CareEvent event) => event.windowSlot ?? event.start;

/// Grouping key for a dose [event]: its window occurrence (the anchored
/// slot) when known — so a scheduled dose and an already-logged dose in
/// the same slot fold under one header even though their starts differ —
/// else its exact wall-clock minute (legacy fallback).
String _doseGroupKey(CareEvent event) {
  final DateTime? slot = event.windowSlot;
  if (slot != null) return 'slot:${slot.toIso8601String()}';
  final DateTime s = event.start;
  return 'min:${s.year}-${s.month}-${s.day}:${s.hour}:${s.minute}';
}
