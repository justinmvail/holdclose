import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/triage.dart';

part 'triage_provider.g.dart';

/// Notifier holding the in-flight triage answers (BUILD_SPEC.md §5.3).
///
/// State is a single [TriageAnswers] whose nullable fields capture the
/// "Q1 answered, Q2/Q3 pending" middle states. The triage screen calls
/// the typed setters as the caregiver progresses, and reads
/// `state.when` / `.whatChanged` / `.whatTried` on Back so the prior
/// selection re-highlights without a separate undo path.
///
/// `keepAlive: false` — popping the triage screen back to the behavior
/// picker disposes the provider so the next decoder run starts from a
/// fresh answers object. Within a single triage session (Q1 → Q2 → Q3
/// → result → back), the screen + the pushed result both retain
/// listeners, so the state survives Back navigation between questions.
@Riverpod(keepAlive: false)
class Triage extends _$Triage {
  @override
  TriageAnswers build() => const TriageAnswers();

  void selectWhen(TriageWhen value) {
    state = state.copyWith(when: value);
  }

  void selectWhatChanged(TriageWhatChanged value) {
    state = state.copyWith(whatChanged: value);
  }

  void selectWhatTried(TriageWhatTried value) {
    state = state.copyWith(whatTried: value);
  }

  /// Clear every field. Not used by the triage screen itself
  /// (autoDispose handles fresh runs), but handy for the demo tour
  /// reset path and for unit tests that re-run the same notifier.
  void reset() {
    state = const TriageAnswers();
  }
}
