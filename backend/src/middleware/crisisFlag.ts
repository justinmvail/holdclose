import {
  CRISIS_KEYWORDS,
  crisisResources,
  type CrisisKeyword,
  type CrisisKeywordCategory,
  type CrisisResources,
} from '../data/crisis-keywords';

// Phase 13.8: shared crisis-keyword auto-flag used by POST /posts
// and POST /comments. Not a Hono middleware in the literal sense —
// it runs inside the route handler after body validation but before
// persistence, because the matcher needs the *parsed* title/body
// (Hono middlewares operate on the raw request and can't share the
// already-consumed JSON body cleanly). The name "middleware" is
// retained because the file lives in middleware/ alongside auth.ts
// per the BUILD_SPEC §13.8 path and the role is the same: a
// cross-cutting hook applied to every write.

export type CrisisDetection =
  | { flagged: false }
  | {
      flagged: true;
      matches: ReadonlyArray<CrisisKeyword>;
      resources: CrisisResources;
    };

// Build a single normalized blob and scan it. Lowercasing once is
// cheaper than re-lowercasing per keyword, and combining title +
// body lets a phrase that straddles the boundary still match.
export function detectCrisisContent(
  ...segments: ReadonlyArray<string | null | undefined>
): CrisisDetection {
  // Single-space join (not a newline) so a phrase that straddles
  // the title/body boundary — e.g. "...kill" + "myself..." —
  // still matches on the joined scan.
  const haystack = segments
    .filter((s): s is string => typeof s === 'string' && s.length > 0)
    .join(' ')
    .toLowerCase();

  if (haystack.length === 0) {
    return { flagged: false };
  }

  const matches: CrisisKeyword[] = [];
  for (const kw of CRISIS_KEYWORDS) {
    if (haystack.includes(kw.phrase)) {
      matches.push(kw);
    }
  }

  if (matches.length === 0) {
    return { flagged: false };
  }

  return {
    flagged: true,
    matches,
    resources: crisisResources(),
  };
}

// Convenience accessor for callers that want the canonical resources
// payload without running detection — e.g. tests that need to assert
// the response shape.
export { crisisResources };
export type { CrisisKeyword, CrisisKeywordCategory, CrisisResources };
