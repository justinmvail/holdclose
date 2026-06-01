import 'package:freezed_annotation/freezed_annotation.dart';

part 'care_shift.freezed.dart';
part 'care_shift.g.dart';

/// One caregiving shift on the Care Team coverage board (TASKS.md Phase
/// 14.31, BUILD_SPEC.md §5.14).
///
/// A caregiver ([caregiverId]) signs up to cover the loved one for a
/// window [start]..[end], with optional [notes] (a handoff reminder, where
/// they'll be, etc.). The Shifts screen lays a day's shifts onto a 24-hour
/// bar and flags the spans no shift covers; the gap math (see
/// `gapsFor` in `lib/providers/care_shifts_provider.dart`) reads off the
/// [start]/[end] pair, which is the single source of truth for coverage.
///
/// [caregiverId] is a logical link to the care-circle roster
/// ([Caregiver.id]), not a DB foreign key — a shift should survive a
/// caregiver being removed from the circle (the history stays intact and
/// the bar falls back to a neutral band), mirroring how a [CareTask]'s
/// assignee resolves softly at read time. [patientId] is a logical link to
/// the single-row patients table, carried explicitly so a future
/// multi-patient model lands without a migration — same as the care-task +
/// care-event models.
@freezed
abstract class CareShift with _$CareShift {
  const factory CareShift({
    required String id,
    required String caregiverId,
    required DateTime start,
    required DateTime end,
    required String patientId,

    /// Optional free-text handoff note shown on the schedule sheet.
    String? notes,
  }) = _CareShift;

  factory CareShift.fromJson(Map<String, dynamic> json) =>
      _$CareShiftFromJson(json);
}

/// Coverage helpers for [CareShift], kept off the freezed factory so the
/// generated model stays a pure data class.
extension CareShiftX on CareShift {
  /// The shift's length. Never negative — an [end] at or before [start]
  /// collapses to zero so the coverage math treats it as no coverage.
  Duration get duration {
    final Duration d = end.difference(start);
    return d <= Duration.zero ? Duration.zero : d;
  }

  /// True when [start] and [end] sit on different calendar days — the
  /// shift spills across midnight, so it contributes coverage to two days
  /// of the strip.
  bool get spansMidnight =>
      start.year != end.year ||
      start.month != end.month ||
      start.day != end.day;
}
