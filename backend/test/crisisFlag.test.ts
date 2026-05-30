import { describe, expect, it } from 'vitest';

import {
  CRISIS_CARD_URL,
  CRISIS_HOTLINES,
  CRISIS_KEYWORDS,
} from '../src/data/crisis-keywords';
import {
  crisisResources,
  detectCrisisContent,
} from '../src/middleware/crisisFlag';

describe('detectCrisisContent', () => {
  it('returns flagged: false for empty input', () => {
    expect(detectCrisisContent()).toEqual({ flagged: false });
    expect(detectCrisisContent('', null, undefined)).toEqual({
      flagged: false,
    });
  });

  it('returns flagged: false for benign caregiving copy', () => {
    const result = detectCrisisContent(
      'Sundowning at 4pm',
      'Every afternoon she gets restless and I take her on a walk.',
    );
    expect(result.flagged).toBe(false);
  });

  it('flags a suicidality phrase regardless of case', () => {
    const result = detectCrisisContent('I want to KILL MYSELF tonight.');
    expect(result.flagged).toBe(true);
    if (!result.flagged) return;
    expect(result.matches.some((m) => m.phrase === 'kill myself')).toBe(true);
    expect(result.matches.every((m) => m.category === 'suicidality')).toBe(
      true,
    );
  });

  it('flags self-harm phrasing', () => {
    const result = detectCrisisContent(
      'Title',
      'Some days I think about cutting myself just to feel something.',
    );
    expect(result.flagged).toBe(true);
    if (!result.flagged) return;
    expect(result.matches.some((m) => m.category === 'self_harm')).toBe(true);
  });

  it('flags severe-abuse phrasing in either direction', () => {
    const caregiverHit = detectCrisisContent('he hit me again last night');
    const lovedOneHit = detectCrisisContent('I lost it and I hit him');
    expect(caregiverHit.flagged).toBe(true);
    expect(lovedOneHit.flagged).toBe(true);
  });

  it('matches phrases that straddle the segment boundary', () => {
    // "kill myself" sits across the title/body join, exercising
    // the joined-blob scan path.
    const result = detectCrisisContent('I want to kill', 'myself tonight.');
    expect(result.flagged).toBe(true);
  });

  it('exposes the canonical crisis resources payload', () => {
    const res = crisisResources();
    expect(res.crisis_card_url).toBe(CRISIS_CARD_URL);
    expect(res.hotlines).toEqual(CRISIS_HOTLINES);
    expect(res.hotlines.length).toBeGreaterThan(0);
    expect(res.hotlines[0]).toHaveProperty('number');
  });

  it('ships keywords across all three categories', () => {
    const cats = new Set(CRISIS_KEYWORDS.map((k) => k.category));
    expect(cats.has('suicidality')).toBe(true);
    expect(cats.has('self_harm')).toBe(true);
    expect(cats.has('severe_abuse')).toBe(true);
  });
});
