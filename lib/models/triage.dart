import 'package:freezed_annotation/freezed_annotation.dart';

part 'triage.freezed.dart';
part 'triage.g.dart';

/// Q1: When does the behavior tend to happen? (BUILD_SPEC.md §5.3)
enum TriageWhen {
  morning,
  afternoon,
  lateAfternoonEvening,
  night,
  justStarted,
}

/// Q2: What changed recently? (BUILD_SPEC.md §5.3)
enum TriageWhatChanged {
  nothing,
  schedule,
  medication,
  health,
  environment,
  dontKnow,
}

/// Q3: What has the caregiver already tried? (BUILD_SPEC.md §5.3)
enum TriageWhatTried {
  talked,
  triedToExplain,
  walkedAway,
  distracted,
  nothingYet,
}

/// The caregiver's answers to the three triage questions, the input to
/// the decoder LLM call (BUILD_SPEC.md §5.3 + §7.2).
///
/// Fields are nullable so the in-flight triage state (Q1 answered,
/// Q2/Q3 pending) can be represented as a single object. The decoder
/// service asserts all three are non-null before invoking the LLM.
@freezed
abstract class TriageAnswers with _$TriageAnswers {
  const factory TriageAnswers({
    TriageWhen? when,
    TriageWhatChanged? whatChanged,
    TriageWhatTried? whatTried,
  }) = _TriageAnswers;

  factory TriageAnswers.fromJson(Map<String, dynamic> json) =>
      _$TriageAnswersFromJson(json);
}
