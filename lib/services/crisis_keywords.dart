// Code-side crisis watchdog for the chat coach. Ported from the backend's
// vetted keyword list (backend/src/data/crisis-keywords.ts, Phase 13.8) so the
// caregiver's OUTGOING chat / voice message is scanned before the model ever
// sees it — the trusted crisis-resources card is rendered on a match
// regardless of what (or whether) the coach replies. Matching is
// substring, case-insensitive, biased for recall over precision: a
// false-positive surfaces a supportive resources card, which is the
// failure mode we prefer in a caregiving app.
//
// This file is the client twin of the backend list; keep the two in sync
// when either changes.

/// The kind of concern a matched phrase signals. Mirrors the backend's
/// `CrisisKeywordCategory`.
enum CrisisKeywordCategory { suicidality, selfHarm, severeAbuse }

/// One vetted crisis phrase + the category it signals.
class CrisisKeyword {
  const CrisisKeyword(this.phrase, this.category);

  /// Lower-cased substring matched against the caregiver's message.
  final String phrase;
  final CrisisKeywordCategory category;
}

/// Vetted phrases the watchdog scans for. New entries should be reviewed by
/// an operator with caregiver-domain context before landing — over-broad
/// terms ("alone", "tired") would drown the card in noise and erode trust.
/// Kept in lock-step with backend/src/data/crisis-keywords.ts.
const List<CrisisKeyword> crisisKeywords = <CrisisKeyword>[
  // Suicidality — caregiver-as-subject phrasing dominates (burnout,
  // hopelessness), but loved-one-as-subject also appears.
  CrisisKeyword('kill myself', CrisisKeywordCategory.suicidality),
  CrisisKeyword('killing myself', CrisisKeywordCategory.suicidality),
  CrisisKeyword('want to die', CrisisKeywordCategory.suicidality),
  CrisisKeyword('wish i was dead', CrisisKeywordCategory.suicidality),
  CrisisKeyword('wish i were dead', CrisisKeywordCategory.suicidality),
  CrisisKeyword('end my life', CrisisKeywordCategory.suicidality),
  CrisisKeyword('end it all', CrisisKeywordCategory.suicidality),
  CrisisKeyword('take my own life', CrisisKeywordCategory.suicidality),
  CrisisKeyword('taking my own life', CrisisKeywordCategory.suicidality),
  CrisisKeyword('suicide', CrisisKeywordCategory.suicidality),
  CrisisKeyword('suicidal', CrisisKeywordCategory.suicidality),

  // Self-harm — methods and behaviors, scoped to phrases unlikely to
  // collide with the medical-context conversation ("cutting" his pills,
  // "overdose" of acetaminophen).
  CrisisKeyword('cutting myself', CrisisKeywordCategory.selfHarm),
  CrisisKeyword('cut myself', CrisisKeywordCategory.selfHarm),
  CrisisKeyword('self harm', CrisisKeywordCategory.selfHarm),
  CrisisKeyword('self-harm', CrisisKeywordCategory.selfHarm),
  CrisisKeyword('hurt myself', CrisisKeywordCategory.selfHarm),
  CrisisKeyword('overdose on', CrisisKeywordCategory.selfHarm),
  CrisisKeyword('take all the pills', CrisisKeywordCategory.selfHarm),
  CrisisKeyword('took all the pills', CrisisKeywordCategory.selfHarm),

  // Severe abuse — caregiver-as-target and loved-one-as-target both
  // matter; the response is the same (crisis resources + APS reference).
  CrisisKeyword('hitting them', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('hitting him', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('hitting her', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('they hit me', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('he hit me', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('she hit me', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('i hit him', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('i hit her', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('i hit them', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('beat me', CrisisKeywordCategory.severeAbuse),
  CrisisKeyword('beating me', CrisisKeywordCategory.severeAbuse),
];

/// A crisis hotline surfaced on the trusted crisis card. Mirrors the
/// backend's `CrisisHotline` — kept short so the card is a pointer, not a
/// directory.
class CrisisHotline {
  const CrisisHotline({
    required this.label,
    required this.number,
    required this.description,
  });

  final String label;

  /// Dialable / textable number (bare digits for `988`, or a full number).
  final String number;
  final String description;
}

/// Surfaced verbatim on the trusted crisis card. Order matters — the 988
/// Lifeline leads.
const List<CrisisHotline> crisisHotlines = <CrisisHotline>[
  CrisisHotline(
    label: '988 Suicide & Crisis Lifeline',
    number: '988',
    description: '24/7 confidential support — call or text in the US.',
  ),
  CrisisHotline(
    label: 'Eldercare Locator',
    number: '1-800-677-1116',
    description: 'Connects you to local Adult Protective Services.',
  ),
];

/// Scan [message] for any vetted crisis phrase (substring, case-insensitive)
/// and return true on the first match. Empty / whitespace input never
/// matches. Used code-side by the chat + voice paths so the trusted card is
/// surfaced independently of the model.
bool messageTriggersCrisis(String message) =>
    firstCrisisMatch(message) != null;

/// The first [CrisisKeyword] whose phrase appears in [message], or null when
/// none does. Exposed (alongside [messageTriggersCrisis]) so callers that
/// want the category — e.g. HITL logging — can read it without re-scanning.
CrisisKeyword? firstCrisisMatch(String message) {
  final String haystack = message.toLowerCase();
  if (haystack.trim().isEmpty) return null;
  for (final CrisisKeyword k in crisisKeywords) {
    if (haystack.contains(k.phrase)) return k;
  }
  return null;
}
