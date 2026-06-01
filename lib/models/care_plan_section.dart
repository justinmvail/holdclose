import 'package:freezed_annotation/freezed_annotation.dart';

part 'care_plan_section.freezed.dart';
part 'care_plan_section.g.dart';

/// When during the day a [CarePlanSection] applies (TASKS.md Phase
/// 14.18).
///
/// The Care Plan screen (a later Phase 14 task) groups sections under
/// these slots top-to-bottom — the routine reads as a daily timeline.
/// [asNeeded] is the catch-all for guidance that isn't tied to a time of
/// day ("if she refuses a bath, try again after lunch"); it sorts last.
///
/// One token per value so the JSON name matches the enum name exactly
/// (`asNeeded`, not `as_needed`) — `json_serializable` serialises enums
/// by `.name` and the round-trip tests pin that.
enum CarePlanSlot {
  morning,
  afternoon,
  evening,
  night,
  asNeeded,
}

/// Which stage of dementia a [CarePlanSection] is written for (TASKS.md
/// Phase 14.18).
///
/// A wellness/organisational tag, NOT a clinical staging tool — the
/// caregiver picks the bucket that fits what they're seeing so the plan
/// can carry stage-appropriate routine notes. [anyStage] is the default
/// for guidance that holds regardless of progression. The model never
/// infers a stage; the caregiver chooses it.
enum CareStage {
  early,
  middle,
  late,
  anyStage,
}

/// One section of the loved one's care plan (TASKS.md Phase 14.18).
///
/// Lives under Medical → Care Plan (BUILD_SPEC.md §5.13). A caregiver-
/// authored routine note — what to do in the [morning], how bathing
/// tends to go, what calms the evenings — grouped by [slot] and tagged
/// by [appliesInStage]. This is organisational, not medical: nothing
/// here diagnoses, prescribes, or stages the condition clinically.
///
/// [body] is a markdown string so the caregiver can use simple lists and
/// emphasis; the screen renders it. [order] is the section's 0-based
/// position WITHIN its [slot] — the care-plan provider keeps each slot's
/// orders contiguous and duplicate-free (gaps close when a section is
/// deleted), so a row's [order] is always a clean index, never a sparse
/// sort key.
///
/// [patientId] FKs (logically — the patients table is single-row, so
/// there's no DB foreign key; see `lib/db/tables.dart`) onto the loved
/// one the install is configured for, carried explicitly so a future
/// multi-patient model lands without a migration.
@freezed
abstract class CarePlanSection with _$CarePlanSection {
  const factory CarePlanSection({
    required String id,
    required String patientId,
    required CarePlanSlot slot,
    required String title,
    required String body,
    required int order,
    required CareStage appliesInStage,
  }) = _CarePlanSection;

  factory CarePlanSection.fromJson(Map<String, dynamic> json) =>
      _$CarePlanSectionFromJson(json);
}
