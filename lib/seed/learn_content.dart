/// Operator-curated, locked content for the Community → Learn segment
/// (BUILD_SPEC.md §5.16, TASKS.md Phase 14.37).
///
/// Two content kinds live here:
///   * [LearnVideo] — short Careblazers framework videos. Real video
///     hosting is deferred to a later phase; the detail screen renders a
///     soft "coming soon" placeholder over this metadata.
///   * [LearnPlaybook] — "what do I do when…" step-by-step guides grouped
///     by [LearnTopic]. The detail screen renders the ordered steps.
///
/// Treat these lists as content, not config — the warm, de-escalating
/// voice is load-bearing for the coaching promise. Like
/// `community_guidelines.dart`, the operator updates this via a spec
/// change (PR + Dr. Natali signoff), never at runtime. Plain const data
/// classes (no freezed / drift) — this is bundled seed copy, not
/// persisted state.
library;

/// A seeded Careblazers framework video shown in the Learn → Videos list.
class LearnVideo {
  const LearnVideo({
    required this.id,
    required this.title,
    required this.youtubeId,
    required this.blurb,
    this.duration,
  });

  /// Stable id used in the `/community/learn/videos/:id` route.
  final String id;

  /// Title shown on the list card + the detail header.
  final String title;

  /// The YouTube video id — drives [youtubeUrl] (opened externally) and
  /// [thumbnailUrl]. These are Dr. Natali's own public Dementia
  /// Careblazers videos; the app links out to them rather than re-hosting.
  final String youtubeId;

  /// Optional run length. Rendered as `m:ss` via [durationLabel] when
  /// known; null hides the label (YouTube shows the real length on open).
  final Duration? duration;

  /// One-sentence description shown under the title on the list card and
  /// on the detail screen.
  final String blurb;

  /// Canonical watch URL handed to the link launcher.
  String get youtubeUrl => 'https://www.youtube.com/watch?v=$youtubeId';

  /// Static thumbnail for the video (YouTube's hosted hqdefault frame).
  String get thumbnailUrl =>
      'https://img.youtube.com/vi/$youtubeId/hqdefault.jpg';

  /// `8:40`-style label, or null when [duration] is unknown.
  String? get durationLabel {
    final Duration? d = duration;
    if (d == null) return null;
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

/// The locked playbook topics (BUILD_SPEC.md §5.16 / Phase 14.37). Order
/// here is the order the Learn → Playbooks section groups by.
enum LearnTopic {
  sundowning('Sundowning'),
  refusal('Refusing care'),
  wandering('Wandering'),
  repetition('Repeated questions'),
  sleep('Sleep'),
  hygiene('Bathing & hygiene'),
  hallucinations('Seeing things'),
  aggression('Anger & aggression');

  const LearnTopic(this.label);

  /// Section-header label shown above the topic's playbooks.
  final String label;
}

/// One ordered step inside a [LearnPlaybook]. Rendered as a numbered card
/// on the playbook detail screen.
class PlaybookStep {
  const PlaybookStep({required this.title, required this.body});

  /// Short imperative heading, e.g. "Meet the feeling first".
  final String title;

  /// The body copy for the step — warm, concrete, non-clinical.
  final String body;
}

/// A step-by-step caregiving playbook shown in the Learn → Playbooks list
/// and rendered as ordered cards on its detail screen.
class LearnPlaybook {
  const LearnPlaybook({
    required this.id,
    required this.topic,
    required this.title,
    required this.summary,
    required this.steps,
  });

  /// Stable id used in the `/community/learn/playbooks/:id` route.
  final String id;

  /// The topic this playbook groups under in the Learn list.
  final LearnTopic topic;

  /// Title shown on the list row + the detail header.
  final String title;

  /// One-sentence hook shown under the title on the list row.
  final String summary;

  /// The ordered steps, rendered as numbered cards on the detail screen.
  final List<PlaybookStep> steps;
}

/// The seeded framework videos — Dr. Natali's own popular Dementia
/// Careblazers YouTube videos (verified channel: "Dementia Careblazers").
/// The app links out to each one rather than re-hosting it; tapping a
/// card opens the video on YouTube.
const List<LearnVideo> learnVideos = <LearnVideo>[
  LearnVideo(
    id: 'top-three',
    title: 'Top 3 must-watch videos on dementia care',
    youtubeId: 'Zx0Qzfm00Nw',
    blurb:
        "Dr. Natali's three most essential lessons for every caregiver, "
        'gathered into one place to start with.',
  ),
  LearnVideo(
    id: 'lying',
    title: 'Lying to someone with dementia',
    youtubeId: '5EM1Iu_eIS4',
    blurb:
        "A kinder way to think about little 'fibs' — when stepping into "
        "your loved one's reality is the more loving choice.",
  ),
  LearnVideo(
    id: 'stages',
    title: 'Stages of dementia caregiving: from chaos to calm',
    youtubeId: '-JbqrkO935E',
    blurb:
        'The three stages every caregiver moves through, and how to tell '
        'which one you are in right now.',
  ),
  LearnVideo(
    id: 'one-thing',
    title: 'The one thing every dementia caregiver can control',
    youtubeId: 'sQdH7CWIn_U',
    blurb:
        "You cannot control the disease, but there is one thing you can — "
        'and it changes the hardest moments.',
  ),
  LearnVideo(
    id: 'early-signs',
    title: "Early dementia signs caregivers wish they hadn't ignored",
    youtubeId: 's70cm2aGHno',
    blurb:
        'Real caregivers on the early signs they look back on, so you can '
        'recognise them sooner.',
  ),
  LearnVideo(
    id: 'level-of-care',
    title: 'Is it time? 8 signs it might be time for a different level of care',
    youtubeId: '646gn3Vy6t8',
    blurb:
        'Eight honest signs that it may be time to consider more help, and '
        'how to face that decision.',
  ),
];

/// The seeded playbooks (Phase 14.37), one or more per [LearnTopic]. The
/// Learn screen groups these by `topic` in [LearnTopic] declaration order.
const List<LearnPlaybook> learnPlaybooks = <LearnPlaybook>[
  LearnPlaybook(
    id: 'sundowning-evenings',
    topic: LearnTopic.sundowning,
    title: 'When the late afternoon gets hard',
    summary: 'Steady the evening before the restlessness builds.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Ease the light shift',
        body:
            'Turn on lamps before dusk so the room never dims around your '
            'loved one. Failing light can read as something wrong, and the '
            'unease shows up as pacing or worry.',
      ),
      PlaybookStep(
        title: 'Lower the load',
        body:
            'Quiet the TV, close the busy kitchen, and keep the room calm. '
            'Late in the day there is less reserve left to handle noise and '
            'commotion.',
      ),
      PlaybookStep(
        title: 'Offer a gentle anchor',
        body:
            'A familiar song, a warm drink, or folding towels together gives '
            'restless energy somewhere to go. You might say, "Sit with me a '
            'minute — keep me company while I finish this."',
      ),
    ],
  ),
  LearnPlaybook(
    id: 'sundowning-i-want-to-go-home',
    topic: LearnTopic.sundowning,
    title: '"I want to go home" at dusk',
    summary: 'Comfort the longing without arguing about the address.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Hear the feeling',
        body:
            '"Home" is usually a feeling of safety, not a street. You might '
            'say, "It sounds like you want to feel settled. I am right here '
            'with you."',
      ),
      PlaybookStep(
        title: 'Join, do not correct',
        body:
            'Skip "you are home." Instead, "Tell me about home — what do you '
            'miss right now?" Let them lead and stay alongside them.',
      ),
      PlaybookStep(
        title: 'Redirect to comfort',
        body:
            'Once the feeling eases, move toward something soothing — a cup '
            'of tea, a photo album, a short walk down the hall together.',
      ),
    ],
  ),
  LearnPlaybook(
    id: 'refusal-personal-care',
    topic: LearnTopic.refusal,
    title: 'When they say no to care',
    summary: 'Lower the threat so cooperation can return.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Pause and step back',
        body:
            'A firm "no" often means your loved one feels rushed or exposed. '
            'Stop, give space, and try again in a few minutes rather than '
            'pushing through.',
      ),
      PlaybookStep(
        title: 'Offer a small choice',
        body:
            'Control calms. "Would you like the blue shirt or the gray one?" '
            'lets them say yes to something rather than no to everything.',
      ),
      PlaybookStep(
        title: 'Go one step at a time',
        body:
            'Name only the next small action — "let us start with your '
            'slippers" — instead of the whole task. Smaller asks feel safer '
            'to agree to.',
      ),
    ],
  ),
  LearnPlaybook(
    id: 'wandering-pacing',
    topic: LearnTopic.wandering,
    title: 'When they keep pacing or trying to leave',
    summary: 'Walk with the restlessness instead of blocking it.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Walk alongside',
        body:
            'Rather than steering your loved one back, fall into step with '
            'them. Moving together feels like company, not a barrier, and '
            'the urgency often softens.',
      ),
      PlaybookStep(
        title: 'Look for the need',
        body:
            'Pacing often points at a need — a bathroom, hunger, boredom, or '
            'too much noise. Meeting that need can settle the body better '
            'than any words.',
      ),
      PlaybookStep(
        title: 'Redirect with a purpose',
        body:
            'Give the walk a destination: "Come help me water the plants." A '
            'small shared task turns aimless motion into something that '
            'feels useful.',
      ),
    ],
  ),
  LearnPlaybook(
    id: 'repetition-same-question',
    topic: LearnTopic.repetition,
    title: 'The same question, again and again',
    summary: 'Answer the worry under the question, not just the words.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Answer calmly, every time',
        body:
            'For your loved one it is the first time they are asking. Reply '
            'in the same warm tone you used at first — the question is real '
            'to them right now.',
      ),
      PlaybookStep(
        title: 'Soothe the feeling',
        body:
            'A repeated question usually carries worry. "Your appointment is '
            'taken care of, and I will be with you" answers the anxiety '
            'underneath, which is what actually quiets it.',
      ),
      PlaybookStep(
        title: 'Gently redirect',
        body:
            'After answering, shift to an activity — a snack, a song, a task '
            'to do together — so the mind has somewhere new to land.',
      ),
    ],
  ),
  LearnPlaybook(
    id: 'sleep-night-waking',
    topic: LearnTopic.sleep,
    title: 'Up and confused in the night',
    summary: 'Keep the night low and reassuring.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Keep it dim and quiet',
        body:
            'Use a soft night light and a low voice. A bright overhead light '
            'or a lot of talking can signal that it is time to be up and '
            'going.',
      ),
      PlaybookStep(
        title: 'Reassure, then guide back',
        body:
            'Let your loved one know they are safe and it is still night. '
            '"Everything is alright — it is sleeping time. I am right down '
            'the hall." Then gently steer back toward bed.',
      ),
      PlaybookStep(
        title: 'Notice daytime patterns',
        body:
            'Long afternoon naps and little daylight can flip the clock. '
            'More light and gentle activity during the day often helps the '
            'nights settle over time.',
      ),
    ],
  ),
  LearnPlaybook(
    id: 'hygiene-bathing',
    topic: LearnTopic.hygiene,
    title: 'When bath time turns into a battle',
    summary: 'Make the room feel safe before anything else.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Warm the room first',
        body:
            'Cold air and a chilly floor make bathing feel unsafe. Warm the '
            'room, have towels ready, and keep water at a gentle temperature '
            'before you begin.',
      ),
      PlaybookStep(
        title: 'Protect dignity',
        body:
            'Keep your loved one covered with a towel as much as you can and '
            'narrate softly what comes next. Feeling exposed is often the '
            'real reason for the resistance.',
      ),
      PlaybookStep(
        title: 'Shrink the task',
        body:
            'A full bath is not always needed. A warm washcloth and a calm '
            'pace can do the job on a hard day — comfort matters more than '
            'completeness.',
      ),
    ],
  ),
  LearnPlaybook(
    id: 'hallucinations-seeing-things',
    topic: LearnTopic.hallucinations,
    title: 'When they see something that is not there',
    summary: 'Tend to the fear before the facts.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Stay calm and close',
        body:
            'What your loved one sees feels completely real to them. A steady '
            'voice and a hand on the shoulder tells them they are not alone '
            'with it.',
      ),
      PlaybookStep(
        title: 'Validate the feeling',
        body:
            'Skip "there is nothing there." Try "that looks like it scared '
            'you — I am here, and you are safe with me." You are answering '
            'the fear, not debating the sight.',
      ),
      PlaybookStep(
        title: 'Change the scene',
        body:
            'Move to another room, turn on a light, or start a familiar '
            'activity. A new setting often lets the image fade on its own.',
      ),
    ],
  ),
  LearnPlaybook(
    id: 'aggression-rising-anger',
    topic: LearnTopic.aggression,
    title: 'When anger boils over',
    summary: 'Bring the temperature down before you do anything else.',
    steps: <PlaybookStep>[
      PlaybookStep(
        title: 'Give space and stay safe',
        body:
            'Step back, lower your voice, and drop your shoulders. Crowding '
            'or matching the intensity tends to feed it; calm space lets the '
            'wave pass.',
      ),
      PlaybookStep(
        title: 'Do not argue',
        body:
            'This is not the moment for facts or reasoning. "I can see you '
            'are upset, and that is okay" lands far better than trying to be '
            'right.',
      ),
      PlaybookStep(
        title: 'Redirect once it eases',
        body:
            'When the heat drops, gently shift to something comforting — a '
            'walk, a snack, a favorite song. Let the moment reset before you '
            'return to whatever sparked it.',
      ),
    ],
  ),
];

/// The seeded video with [id], or null when no video matches (e.g. a stale
/// deep link). Used by the video detail screen.
LearnVideo? learnVideoById(String id) {
  for (final LearnVideo video in learnVideos) {
    if (video.id == id) return video;
  }
  return null;
}

/// The seeded playbook with [id], or null when none matches. Used by the
/// playbook detail screen.
LearnPlaybook? learnPlaybookById(String id) {
  for (final LearnPlaybook playbook in learnPlaybooks) {
    if (playbook.id == id) return playbook;
  }
  return null;
}

/// The playbooks for [topic], in seed order. Empty when a topic has no
/// seeded playbooks yet — the Learn screen skips empty topic groups.
List<LearnPlaybook> learnPlaybooksForTopic(LearnTopic topic) =>
    <LearnPlaybook>[
      for (final LearnPlaybook playbook in learnPlaybooks)
        if (playbook.topic == topic) playbook,
    ];
