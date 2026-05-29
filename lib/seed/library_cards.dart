/// One topical primer card on the Library tab (BUILD_SPEC.md §5.7 +
/// §9.4). Cards are static seed data — they're not user-editable, not
/// persisted to drift, and not round-tripped over JSON — so the type is
/// a plain immutable class rather than a freezed model.
///
/// [body] is intentionally a 50–80 word placeholder in v1. Phase 8
/// polish replaces each one with the hand-finalized 300–500 word body
/// written in Dr. Natali's voice (BUILD_SPEC.md §9.4). Each placeholder
/// is tagged `// TODO(natali): refine` at the call site so the polish
/// pass can find them with a single grep.
///
/// [relatedBehaviorIds] points at one or more ids from
/// [Behavior.canonical]. The library card detail screen (BUILD_SPEC.md
/// §5.8) renders these as chips that deep-link into the decoder for
/// that behavior.
class LibraryCard {
  const LibraryCard({
    required this.id,
    required this.title,
    required this.hook,
    required this.body,
    required this.relatedBehaviorIds,
  });

  final String id;
  final String title;
  final String hook;
  final String body;
  final List<String> relatedBehaviorIds;
}

/// The 12 canonical Library cards locked by BUILD_SPEC.md §9.4.
///
/// Order matches the spec listing — Task 22's Library screen computes
/// "Today's card" as `date.dayOfYear % libraryCards.length`, so the
/// order here doubles as the rotation order.
const List<LibraryCard> libraryCards = <LibraryCard>[
  // 1. anosognosia
  LibraryCard(
    id: 'anosognosia',
    title: "Why she doesn't know she has dementia",
    hook:
        "Anosognosia isn't denial — her brain literally cannot perceive that anything is wrong.",
    // TODO(natali): refine
    body:
        "When your loved one insists she's fine, she isn't being stubborn and she isn't lying. The same brain changes that cause her memory loss have also taken away her ability to notice the changes. We call this anosognosia. Arguing the facts won't land — her brain can't receive them. Step into her reality instead, then redirect with care.",
    relatedBehaviorIds: <String>['refusing_care', 'accusing'],
  ),

  // 2. sundowning_basics
  LibraryCard(
    id: 'sundowning_basics',
    title: "What's happening between 4pm and bedtime",
    hook:
        'Late-afternoon agitation is the brain running out of fuel — and it has a name.',
    // TODO(natali): refine
    body:
        "Sundowning isn't a mood — it's a neurological pattern. As the day winds down, the dementia brain runs low on the energy it needs to interpret the world, and confusion, restlessness, or fear can spike. Dim the overhead lights, switch on a single warm lamp, lower your voice, and slow your pace. The goal isn't to reason her through it. The goal is to make the room feel safer until the wave passes.",
    relatedBehaviorIds: <String>['sundowning', 'wandering'],
  ),

  // 3. respond_to_emotion
  LibraryCard(
    id: 'respond_to_emotion',
    title: 'The single most useful sentence in dementia care',
    hook:
        "\"That sounds really hard. I'm right here with you.\" Start there, every time.",
    // TODO(natali): refine
    body:
        "When your loved one is upset, your instinct is to fix the words — to explain, correct, reassure with facts. The brain change makes that path a dead end. Respond to the emotion instead. Name what you see, sit close, slow down. The sentence above buys you thirty seconds of calm, and thirty seconds is usually all you need to find the next right step together.",
    relatedBehaviorIds: <String>['upset', 'accusing', 'wants_home'],
  ),

  // 4. five_causes
  LibraryCard(
    id: 'five_causes',
    title: 'The 5 things that drive every difficult behavior',
    hook:
        'Loss of control, relationship strain, brain changes, unmet needs, anosognosia.',
    // TODO(natali): refine
    body:
        "Behind nearly every hard moment is one of five causes — loss of control, relationship strain, actual brain changes, an unmet need, or anosognosia. Before you respond, take a breath and ask which one is loudest right now. Is she hungry, tired, in pain? Has her routine shifted? Does she feel powerless? Naming the cause doesn't fix it on its own, but it points you at the right tool.",
    relatedBehaviorIds: <String>[
      'refusing_care',
      'accusing',
      'sundowning',
      'wandering',
    ],
  ),

  // 5. step_into_reality
  LibraryCard(
    id: 'step_into_reality',
    title: 'When she asks for someone who died',
    hook:
        "Re-delivering a death notice every few hours is cruel — and it doesn't stick.",
    // TODO(natali): refine
    body:
        "When your loved one asks for her mother, her husband, or anyone she's lost, the kindest answer is rarely the literal truth. Her brain isn't holding the news; telling her again only forces fresh grief. Step into the moment she's remembering. Ask about him. Look at a photo together. Let her feel close to him in the way she can right now. You're not lying — you're meeting her where she is.",
    relatedBehaviorIds: <String>['asking_for_someone', 'upset'],
  ),

  // 6. accusations_basics
  LibraryCard(
    id: 'accusations_basics',
    title: 'When they accuse you of stealing',
    hook:
        "The accusation isn't really about the missing item — it's about feeling unsafe.",
    // TODO(natali): refine
    body:
        "Accusations sting because they sound like a moral charge. They're not. When your loved one says you took her purse, her brain is telling her something is wrong, and the missing item is the story it built to explain the feeling. Don't try to prove your innocence — you can't win that argument. Sit next to her, validate the worry, and offer to look together. The connection settles the alarm.",
    relatedBehaviorIds: <String>['accusing', 'upset'],
  ),

  // 7. wanting_to_go_home
  LibraryCard(
    id: 'wanting_to_go_home',
    title: "What 'home' actually means",
    hook:
        '"I want to go home" is rarely about an address — it\'s about a feeling she\'s missing.',
    // TODO(natali): refine
    body:
        'When your loved one asks to go home — even when she is home — her brain is reaching for a feeling: safety, familiarity, the version of life she remembers most clearly. Arguing the address only widens the gap. Ask her about home. What does she miss? Bring out an old photo, an afghan, a favorite mug. Sit with her in it. The feeling she\'s asking for is usually one you can offer right where you are.',
    relatedBehaviorIds: <String>['wants_home', 'upset'],
  ),

  // 8. family_doesnt_believe
  LibraryCard(
    id: 'family_doesnt_believe',
    title: "When your siblings don't believe you",
    hook:
        'You see her every day. They see the showtime version. Both things are true.',
    // TODO(natali): refine
    body:
        "It's one of the loneliest parts of caregiving — describing what you live with and watching your siblings shrug it off. They aren't lying; they're seeing the showtime version your loved one produces for short visits. Don't waste energy convincing them in the moment. Keep a simple log of incidents — the journal in this app fills itself for that reason — and share the pattern instead of the anecdote. Patterns travel further than stories.",
    relatedBehaviorIds: <String>['accusing'],
  ),

  // 9. caregiver_guilt
  LibraryCard(
    id: 'caregiver_guilt',
    title:
        'Guilty for being angry. Guilty for being tired. Guilty for being human.',
    hook:
        "Guilt is the tax caregivers pay on caring. Naming it is how you stop overpaying.",
    // TODO(natali): refine
    body:
        "Caregiver guilt shows up because you care, not because you're failing. You're angry because you're exhausted. You're tired because the work is real. You wish for an afternoon off because you're human, and humans need rest. None of that means you love her less. Name the feeling out loud — even to yourself — and let it pass through. Suppressed guilt grows. Acknowledged guilt eases.",
    relatedBehaviorIds: <String>['upset'],
  ),

  // 10. boundaries_compassion
  LibraryCard(
    id: 'boundaries_compassion',
    title: 'Saying no when yes is dangerous',
    hook:
        'A boundary is a kindness — to her, to you, and to the next twelve months of caregiving.',
    // TODO(natali): refine
    body:
        "Boundaries feel unkind until you remember what they protect. Saying no to a midnight drive, no to skipping her medication, no to a tenth re-explanation of the same news isn't refusal of love — it's the structure that lets the love keep showing up tomorrow. Be warm and clear. \"I hear you. We can't do that one tonight. Let's do this instead.\" Then redirect to a small, safe yes.",
    relatedBehaviorIds: <String>['refusing_care', 'wandering'],
  ),

  // 11. when_to_ask_respite
  LibraryCard(
    id: 'when_to_ask_respite',
    title: 'Permission to step away',
    hook:
        'Respite isn\'t a failure. It\'s the maintenance that keeps the long road possible.',
    // TODO(natali): refine
    body:
        "If you've been counting the days until something gives, that's the signal. Respite — a few hours, an afternoon, a weekend — isn't an admission that you can't handle this. It's how you stay handle-able. Ask the family member you've been protecting. Call the local Area Agency on Aging. Hire help for one shift. The first time is the hardest; after that, it becomes part of the routine that keeps everyone safer.",
    relatedBehaviorIds: <String>['upset'],
  ),

  // 12. showtime
  LibraryCard(
    id: 'showtime',
    title: "Why she 'presented so well' at the doctor",
    hook:
        "Short, high-stakes visits trigger her best mask — and obscure the picture the doctor needs.",
    // TODO(natali): refine
    body:
        "Showtime is real. In a short, focused visit, your loved one's brain can pull together a polished version of herself the doctor never sees crack. That's why your reports get waved off and why you leave appointments feeling unseen. Bring the journal. Bring two weeks of pattern, not one bad morning. When the doctor sees the data, the conversation shifts from \"she seems fine\" to \"let's look at what's happening at home.\"",
    relatedBehaviorIds: <String>['accusing', 'sundowning'],
  ),
];

/// Lookup a card by [id]. Returns null if no card with that id exists —
/// used by the library card detail route to render a 404-style fallback
/// rather than crashing on a stale deep-link.
LibraryCard? libraryCardById(String id) {
  for (final LibraryCard card in libraryCards) {
    if (card.id == id) return card;
  }
  return null;
}
