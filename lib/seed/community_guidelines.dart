/// One section of the locked community guidelines (BUILD_SPEC.md §13 /
/// Phase 13.12). Each section is rendered as a titled block in
/// [CommunityGuidelinesScreen]; the four-section split mirrors the
/// brevity of in-the-moment caregiving copy — long blocks of legal
/// prose get scrolled past unread.
class CommunityGuidelineSection {
  const CommunityGuidelineSection({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;
}

/// The four pillars of the holdclose community (BUILD_SPEC.md §13 /
/// Phase 13.12).
///
/// Order matters. Tone first — caregivers under duress need to know
/// what kind of room they're walking into before they read scope or
/// rules. Scope second so first-time posters self-redirect off-topic
/// drafts. The no-medical-advice section is third because it's the
/// hardest line to maintain — and posting it BEFORE the crisis pointer
/// makes "this is not a clinician" land before "here is who is".
///
/// Operator can update via a spec change (PR + operator signoff).
/// Treat this list as content, not config — the locked-down voice is
/// load-bearing for the support promise.
const List<CommunityGuidelineSection> communityGuidelines =
    <CommunityGuidelineSection>[
  CommunityGuidelineSection(
    title: 'Tone — assume good intent.',
    body:
        "Everyone here is a caregiver carrying a hard day. Before you "
        "post or reply, picture the person on the other side at 2am "
        "after a fall. Lead with what worked for you, not with what "
        "they did wrong. Disagree with the idea, never the person. If "
        "you feel a reply rising in heat, draft it, walk away, come "
        "back in an hour — that's the rule we hold each other to.",
  ),
  CommunityGuidelineSection(
    title: 'Scope — caregiving, not everything.',
    body:
        "This board is for dementia caregiving questions, scripts that "
        "worked, scripts that didn't, and the moments in between. Posts "
        "about politics, religion, fundraising, products, or general "
        "venting drift off-mission and we move them to a quieter place. "
        "Asking 'how do I respond when she calls me by her mother's "
        "name?' belongs here. Asking 'which insurance plan is best?' "
        "belongs somewhere else.",
  ),
  CommunityGuidelineSection(
    title: 'No medical advice — name your role.',
    body:
        "Nobody here is your loved one's clinician, not even the nurses "
        "and doctors who post on their days off. Share what your team "
        "tried. Don't recommend dosage changes, medication swaps, or "
        "treatment plans. If a post asks for advice that needs a "
        "clinician — call the doctor's after-hours line, not the "
        "comments section. Reports of medication advice go straight to "
        "the moderation queue.",
  ),
  CommunityGuidelineSection(
    title: 'In crisis — leave this app and call.',
    body:
        "If you or your loved one is in immediate danger, this board "
        "is not the place. The Crisis tab (the bell on the right) has "
        "the 988 Suicide & Crisis Lifeline, the Alzheimer's "
        "Association 24/7 Helpline, and your local 911. We will not "
        "be faster than the people on those lines. Post here after "
        "you're safe — we'll be here when you get back.",
  ),
];

/// The acknowledgement copy shown on the first-post modal (BUILD_SPEC.md
/// §13 / Phase 13.12). Short — three sentences caregiver-tired eyes can
/// actually finish. The "I've read them" button enables only after the
/// full text is in view, gated by the modal's scroll listener; the
/// negative path returns to the compose screen with the draft intact.
const String firstPostAcknowledgement =
    "Before your first post, take a beat with the four guidelines. "
    "They're not legal disclaimers — they're the agreement that lets "
    "caregivers tell each other the truth about hard days. Tap 'I've "
    "read them' once you've actually read them; we'll never ask again.";
