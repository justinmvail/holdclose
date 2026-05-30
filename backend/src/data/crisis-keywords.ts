// Vetted keyword list for the crisis-flag middleware (Phase 13.8).
// Substring-matched, case-insensitive, against the lower-cased
// concatenation of post title + body or comment body. Designed for
// recall over precision: a false-positive surfaces the crisis-card
// banner above an otherwise innocuous post, which is the failure mode
// we prefer. New entries here should be reviewed by an operator with
// caregiver-domain context before landing — over-broad terms
// ("alone", "tired") would drown the banner in noise and erode trust.

export type CrisisKeywordCategory =
  | 'suicidality'
  | 'self_harm'
  | 'severe_abuse';

export type CrisisKeyword = {
  phrase: string;
  category: CrisisKeywordCategory;
};

export const CRISIS_KEYWORDS: ReadonlyArray<CrisisKeyword> = [
  // Suicidality — caregiver-as-subject phrasing dominates in
  // dementia-care forums (burnout, hopelessness) but loved-one-as-
  // subject phrasing also appears ("he says he wants to die").
  { phrase: 'kill myself', category: 'suicidality' },
  { phrase: 'killing myself', category: 'suicidality' },
  { phrase: 'want to die', category: 'suicidality' },
  { phrase: 'wish i was dead', category: 'suicidality' },
  { phrase: 'wish i were dead', category: 'suicidality' },
  { phrase: 'end my life', category: 'suicidality' },
  { phrase: 'end it all', category: 'suicidality' },
  { phrase: 'take my own life', category: 'suicidality' },
  { phrase: 'taking my own life', category: 'suicidality' },
  { phrase: 'suicide', category: 'suicidality' },
  { phrase: 'suicidal', category: 'suicidality' },

  // Self-harm — methods and behaviors, scoped to phrases unlikely to
  // collide with the medical-context conversation common in this
  // forum (e.g. "cutting" his pills, "overdose" of acetaminophen).
  { phrase: 'cutting myself', category: 'self_harm' },
  { phrase: 'cut myself', category: 'self_harm' },
  { phrase: 'self harm', category: 'self_harm' },
  { phrase: 'self-harm', category: 'self_harm' },
  { phrase: 'hurt myself', category: 'self_harm' },
  { phrase: 'overdose on', category: 'self_harm' },
  { phrase: 'take all the pills', category: 'self_harm' },
  { phrase: 'took all the pills', category: 'self_harm' },

  // Severe abuse — caregiver-as-target and loved-one-as-target both
  // matter; the response is the same (crisis resources + APS hotline
  // reference on the crisis card).
  { phrase: 'hitting them', category: 'severe_abuse' },
  { phrase: 'hitting him', category: 'severe_abuse' },
  { phrase: 'hitting her', category: 'severe_abuse' },
  { phrase: 'they hit me', category: 'severe_abuse' },
  { phrase: 'he hit me', category: 'severe_abuse' },
  { phrase: 'she hit me', category: 'severe_abuse' },
  { phrase: 'i hit him', category: 'severe_abuse' },
  { phrase: 'i hit her', category: 'severe_abuse' },
  { phrase: 'i hit them', category: 'severe_abuse' },
  { phrase: 'beat me', category: 'severe_abuse' },
  { phrase: 'beating me', category: 'severe_abuse' },
];

export type CrisisHotline = {
  label: string;
  number: string;
  description: string;
};

// Surfaced verbatim on the banner the client renders above the
// post/comment confirmation. Keep this list short — the banner is a
// pointer, not a directory. The deep list lives on the crisis card.
export const CRISIS_HOTLINES: ReadonlyArray<CrisisHotline> = [
  {
    label: '988 Suicide & Crisis Lifeline',
    number: '988',
    description: '24/7 confidential support — call or text in the US.',
  },
  {
    label: 'Eldercare Locator',
    number: '1-800-677-1116',
    description: 'Connects you to local Adult Protective Services.',
  },
];

export const CRISIS_CARD_URL = '/crisis';

export type CrisisResources = {
  crisis_card_url: typeof CRISIS_CARD_URL;
  hotlines: ReadonlyArray<CrisisHotline>;
};

export const crisisResources = (): CrisisResources => ({
  crisis_card_url: CRISIS_CARD_URL,
  hotlines: CRISIS_HOTLINES,
});
