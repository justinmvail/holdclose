/// Operator-curated, locked content for the Community → Support segment
/// (BUILD_SPEC.md §5.16, TASKS.md Phase 14.38).
///
/// Three content kinds live here:
///   * [burnoutQuestions] + [burnoutScaleLabels] — the 10-item Likert
///     self-check the [SupportScreen] renders. The scoring lives in
///     `lib/services/burnout_score.dart`; this file owns only the prompts
///     and the 1–5 scale labels.
///   * [respiteResources] — national caregiver hotlines + help lines. The
///     "search local respite" affordance launches [respiteSearchUrl]; a
///     real local directory is deferred to a later phase.
///   * [expertAnswers] — a read-only list of curated, operator-seeded
///     answers shown in the Expert Q&A card.
///
/// Treat these as content, not config — the warm, de-escalating,
/// non-clinical voice is load-bearing (BUILD_SPEC.md §13.1). Like
/// `learn_content.dart`, the operator updates this via a spec change
/// (PR + operator signoff), never at runtime. Plain const data — this
/// is bundled seed copy, not persisted state.
library;

/// The 10 self-check statements (Phase 14.38). Each is a first-person
/// statement the Careblazer rates on the 1–5 [burnoutScaleLabels] scale,
/// where a higher rating signals more strain. Order is fixed — the
/// scoring sums the answers positionally.
const List<String> burnoutQuestions = <String>[
  'I feel emotionally drained by caring for my loved one.',
  'I have less time for myself than I need.',
  'I feel alone in caring for my loved one.',
  "I'm having trouble sleeping or truly resting.",
  'I feel overwhelmed by everything I have to manage.',
  "I get impatient or short-tempered more than I'd like.",
  'My own health has taken a back seat.',
  'I feel guilty no matter what I do.',
  "I've lost touch with friends or things I used to enjoy.",
  "I worry I can't keep going at this pace.",
];

/// Labels for the 1–5 Likert scale, index 0 = a rating of 1. Shown as a
/// legend above the questions so the numbers read as a frequency.
const List<String> burnoutScaleLabels = <String>[
  'Never',
  'Rarely',
  'Sometimes',
  'Often',
  'Always',
];

/// A national caregiver help line / respite resource shown in the Respite
/// card. [phone] and [url] are both optional — a resource may offer a
/// phone line, a website, or both. The Support screen launches [phone] as
/// a `tel:` link and [url] in the browser through the shared
/// `LinkLauncher` seam.
class RespiteResource {
  const RespiteResource({
    required this.id,
    required this.name,
    required this.description,
    this.phone,
    this.url,
  });

  /// Stable id used for the resource row's widget key.
  final String id;

  /// Organization / line name shown as the row title.
  final String name;

  /// One-sentence description of what the line offers.
  final String description;

  /// Dialable number, e.g. `1-800-272-3900`. Null when the resource is
  /// web-only.
  final String? phone;

  /// Website, opened in the browser. Null when the resource is phone-only.
  final String? url;

  /// `tel:` URI for [phone] with separators stripped, or null when there
  /// is no phone number.
  Uri? get phoneUri {
    final String? raw = phone;
    if (raw == null) return null;
    final String digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    return Uri.parse('tel:$digits');
  }
}

/// National caregiver + crisis help lines (Phase 14.38). These refer
/// Holdclose to professional support; per BUILD_SPEC.md §13.1 they do
/// not diagnose or prescribe. A local respite directory is deferred — the
/// "search local respite" affordance launches [respiteSearchUrl] instead.
const List<RespiteResource> respiteResources = <RespiteResource>[
  RespiteResource(
    id: 'eldercare-locator',
    name: 'Eldercare Locator',
    description:
        'A free public service that connects you to respite, in-home '
        'help, and other support near you.',
    phone: '1-800-677-1116',
    url: 'https://eldercare.acl.gov',
  ),
  RespiteResource(
    id: 'alz-helpline',
    name: "Alzheimer's Association Helpline",
    description:
        'Around-the-clock support from specialists — any hour, any day. '
        'Dementia-focused, but a warm first call for many caregivers.',
    phone: '1-800-272-3900',
    url: 'https://www.alz.org/help-support/resources/helpline',
  ),
  RespiteResource(
    id: 'family-caregiver-alliance',
    name: 'Family Caregiver Alliance',
    description:
        'Guidance, respite planning, and caregiver programs for families '
        'doing this work at home.',
    phone: '1-800-445-8106',
    url: 'https://www.caregiver.org',
  ),
  RespiteResource(
    id: 'arch-respite',
    name: 'ARCH National Respite Locator',
    description:
        'A searchable directory of respite services state by state, so '
        'you can hand off the care for a while.',
    url: 'https://archrespite.org/respitelocator',
  ),
  RespiteResource(
    id: 'crisis-lifeline-988',
    name: '988 Suicide & Crisis Lifeline',
    description:
        "If today feels like too much, you can reach a caring person now. "
        'Call or text 988, any time.',
    phone: '988',
    url: 'https://988lifeline.org',
  ),
];

/// Web-search URL the "search local respite" link opens. A real local
/// directory is deferred to a later phase; until then this hands the
/// Careblazer to a plain web search seeded with a respite query.
Uri respiteSearchUrl() =>
    Uri.parse('https://www.google.com/search?q=respite+care+near+me');

/// A curated Expert Q&A entry shown read-only in the Support card
/// (Phase 14.38). Answers are operator-seeded in a warm, evidence-based
/// coaching voice — there is no live answering in v1.
class ExpertAnswer {
  const ExpertAnswer({
    required this.id,
    required this.question,
    required this.answer,
    this.attribution = 'Caregiving support',
  });

  /// Stable id used for the answer's widget key.
  final String id;

  /// The caregiver question, shown as the entry heading.
  final String question;

  /// The seeded answer body, in the coaching framework voice.
  final String answer;

  /// Who the answer is credited to. Defaults to a generic caregiving
  /// support credit.
  final String attribution;
}

/// The seeded Expert Q&A entries (Phase 14.38). Caregiver-wellbeing
/// focused, warm, and non-clinical — they coach, they do not prescribe.
const List<ExpertAnswer> expertAnswers = <ExpertAnswer>[
  ExpertAnswer(
    id: 'permission-to-rest',
    question: 'I feel guilty taking any time for myself. Is that wrong?',
    answer:
        'It is one of the most common feelings caregivers carry, and it '
        'is not a sign you are doing anything wrong. Rest is not a reward '
        'you have to earn — it is part of how you keep showing up. A '
        'cared-for caregiver gives steadier care. Start small: one hour, '
        'one walk, one cup of coffee that is only yours.',
  ),
  ExpertAnswer(
    id: 'asking-for-help',
    question: 'How do I ask family to help without it turning into a fight?',
    answer:
        'Ask for something specific rather than help in general. "Can you '
        'sit with Mom on Tuesday afternoon" is easier to say yes to than '
        '"I need more support." Name one concrete task and one time. People '
        'who feel unsure how to help often step in once they know exactly '
        'what would lighten the load.',
  ),
  ExpertAnswer(
    id: 'when-its-too-much',
    question: 'Some days I feel like I am at my breaking point. What do I do?',
    answer:
        'First, please hear that reaching a breaking point does not make '
        'you a failing caregiver — it makes you a human one. On those days, '
        'lower the bar to only what keeps your loved one safe and fed, and '
        'let the rest wait. Then reach out to a real person: a respite '
        'line, a counselor, or your own doctor. You are allowed to need '
        'care too.',
  ),
  ExpertAnswer(
    id: 'losing-myself',
    question: 'I feel like I am losing who I used to be. Is that normal?',
    answer:
        'It is, and naming it is important. Caregiving can quietly crowd '
        'out the parts of life that made you feel like you. Protecting one '
        'small thread — a friendship, a hobby, a standing phone call — is '
        'not selfish. It keeps a version of yourself alive that your loved '
        'one still needs you to be.',
  ),
];
