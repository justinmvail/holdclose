import 'package:flutter/material.dart' show TimeOfDay;
import 'package:freezed_annotation/freezed_annotation.dart';

import 'medication.dart' show FrequencyKind, TimeOfDayJsonConverter;

part 'care_plan_routine.freezed.dart';
part 'care_plan_routine.g.dart';

/// A scheduled care routine — a wall-clock time + recurrence the
/// caregiver wants to be reminded of (BUILD_SPEC.md §5.13 v2).
///
/// Replaces the v1 [CarePlanSection] (slot + stage) model, which read
/// as organisational notes grouped under fuzzy buckets like "morning"
/// and "early stage". v2 makes care routines first-class scheduled
/// tasks so they project into the unified patient timeline alongside
/// medications and appointments — caregivers see "hygiene at 7:30 AM"
/// in the same chronological view as the morning dose, not in a
/// separate buried screen.
///
/// Reuses the [FrequencyKind] enum from [Medication] so the daily /
/// weekly / asNeeded shape stays consistent across the two scheduled
/// data sources. [scheduledTime] is the single wall-clock anchor;
/// [daysOfWeek] only applies when [frequencyKind] is
/// [FrequencyKind.weekly] (Monday = 1 … Sunday = 7, matching
/// `DateTime.weekday`).
///
/// Situational protocols ("when sundowning starts, try X") moved out
/// of the Care Plan tile into the Community → Learn playbook surface;
/// they're reference content, not time-keyed routines.
@freezed
abstract class CarePlanRoutine with _$CarePlanRoutine {
  const factory CarePlanRoutine({
    required String id,
    required String patientId,
    required String title,
    required String body,
    @TimeOfDayJsonConverter() required TimeOfDay scheduledTime,
    required FrequencyKind frequencyKind,
    required Set<int> daysOfWeek,
    required DateTime startsOn,
    DateTime? endsOn,
  }) = _CarePlanRoutine;

  factory CarePlanRoutine.fromJson(Map<String, dynamic> json) =>
      _$CarePlanRoutineFromJson(json);
}
