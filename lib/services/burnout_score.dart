import 'package:flutter/foundation.dart';

import '../seed/support_content.dart';

/// Strain band returned by [scoreBurnout] (BUILD_SPEC.md §5.16,
/// TASKS.md Phase 14.38).
///
/// Four rungs across the 10–50 raw-score range. The band drives both the
/// headline and the Dr.-Natali-style [BurnoutResult.message] — the
/// higher bands lean harder on "please reach out to a real person",
/// honoring the §13.1 referral guardrail (this is wellbeing coaching,
/// never a clinical diagnosis).
enum BurnoutBand { low, moderate, high, severe }

/// The result of scoring a completed self-check. Pure value type — no
/// I/O, no riverpod — so the screen can hold it in widget state and the
/// scoring stays trivially testable.
@immutable
class BurnoutResult {
  const BurnoutResult({
    required this.score,
    required this.band,
    required this.headline,
    required this.message,
  });

  /// Raw summed score, in the inclusive range [minScore]–[maxScore].
  final int score;

  /// The band [score] falls into.
  final BurnoutBand band;

  /// Short band title shown above the message (e.g. "Holding steady").
  final String headline;

  /// The warm, de-escalating, non-clinical response copy. Never claims a
  /// diagnosis; the higher bands point the Careblazer at professional
  /// help and the respite resources on the same screen.
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BurnoutResult &&
          other.score == score &&
          other.band == band &&
          other.headline == headline &&
          other.message == message);

  @override
  int get hashCode => Object.hash(score, band, headline, message);
}

/// Lowest rating allowed for a single self-check item.
const int minAnswer = 1;

/// Highest rating allowed for a single self-check item.
const int maxAnswer = 5;

/// Minimum possible raw score (all 10 items at [minAnswer]).
int get minScore => burnoutQuestions.length * minAnswer;

/// Maximum possible raw score (all 10 items at [maxAnswer]).
int get maxScore => burnoutQuestions.length * maxAnswer;

/// Score a completed self-check.
///
/// [answers] must contain exactly one rating per [burnoutQuestions]
/// entry, each in the inclusive range [minAnswer]–[maxAnswer]. The raw
/// score is the sum; for the canonical 10 items that is 10–50. Bands
/// split that range into quartiles:
///
/// * **low** — score < 20 (Holding steady)
/// * **moderate** — 20–29 (Running low)
/// * **high** — 30–39 (Stretched thin)
/// * **severe** — score ≥ 40 (Running on empty)
///
/// Throws [ArgumentError] if the answer count or any value is out of
/// range — a malformed call is a programming error, not a user state.
BurnoutResult scoreBurnout(List<int> answers) {
  if (answers.length != burnoutQuestions.length) {
    throw ArgumentError.value(
      answers.length,
      'answers',
      'expected ${burnoutQuestions.length} answers',
    );
  }
  int score = 0;
  for (final int answer in answers) {
    if (answer < minAnswer || answer > maxAnswer) {
      throw ArgumentError.value(
        answer,
        'answers',
        'each rating must be between $minAnswer and $maxAnswer',
      );
    }
    score += answer;
  }

  final BurnoutBand band = _bandForScore(score);
  return BurnoutResult(
    score: score,
    band: band,
    headline: _headlines[band]!,
    message: _messages[band]!,
  );
}

/// The band a raw [score] falls into. Thresholds are quartiles of the
/// 10–50 range; written as `< 20 / < 30 / < 40 / else` so they hold even
/// if a future spec change widens the form.
BurnoutBand _bandForScore(int score) {
  if (score < 20) return BurnoutBand.low;
  if (score < 30) return BurnoutBand.moderate;
  if (score < 40) return BurnoutBand.high;
  return BurnoutBand.severe;
}

const Map<BurnoutBand, String> _headlines = <BurnoutBand, String>{
  BurnoutBand.low: 'Holding steady',
  BurnoutBand.moderate: 'Running low',
  BurnoutBand.high: 'Stretched thin',
  BurnoutBand.severe: 'Running on empty',
};

const Map<BurnoutBand, String> _messages = <BurnoutBand, String>{
  BurnoutBand.low:
      "You're carrying a real load and, right now, you're finding ways to "
      'stay steady under it. That balance is worth protecting. Keep the '
      'small things that refill you on the calendar, not just in your good '
      'intentions.',
  BurnoutBand.moderate:
      "The strain is starting to show, and that's a signal worth listening "
      'to, not a failure. See if you can hand off one task this week and '
      'take back an hour that is only yours. Even a short, regular break '
      'changes how the hard moments land.',
  BurnoutBand.high:
      "You're stretched further than anyone should carry alone, and the "
      'weight of it is real. This is the point to bring someone else in — a '
      'respite service, a family member, or one of the help lines below. '
      'Asking for help here is good caregiving, not giving up.',
  BurnoutBand.severe:
      "What you're feeling is past tired — it's the kind of depletion that "
      'needs more than a good night of sleep to mend. Please reach out to a '
      'person today: your doctor, a counselor, or one of the help lines '
      'below. You matter as much as the person you are caring for, and you '
      'deserve support too.',
};
