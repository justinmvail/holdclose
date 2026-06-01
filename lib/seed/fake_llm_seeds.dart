import '../models/behavior.dart';
import '../models/decoder_result.dart';

/// One hand-authored [DecoderResult] per canonical behavior id
/// (BUILD_SPEC.md §10.2). The [FakeLLMProvider] looks responses up here
/// by [Behavior.id] and streams them back to the decoder screen in
/// 8-token chunks.
///
/// The voice and structure follow the system prompt in BUILD_SPEC.md
/// §7.1: respond to the emotion (not the words), connection-not-
/// correction, family vocabulary, no exclamation marks, 2–3 concrete
/// "say" entries + 1–2 environmental "tweak" entries + 1–2 "don't say"
/// warnings. The `generatedAt` slot here is a placeholder — the
/// provider stamps its own `now()` before yielding.
final Map<String, DecoderResult> fakeLLMSeeds = <String, DecoderResult>{
  // ---- 1. upset / crying ---------------------------------------------------
  'upset': DecoderResult(
    say: const <String>[
      "I can see this is really hard. I'm right here with you.",
      "You don't have to explain anything. Let's just sit together for a minute.",
      'Would it help if I held your hand, or would you rather I sat close by?',
    ],
    tweak: const <String>[
      'Lower your voice and slow your pace. Sit at their eye level — not standing over them — and put your phone away.',
    ],
    dontSay: const <String>[
      "Don't say 'there's nothing to cry about' or 'you're fine.' In the moment, the tears are real even if the trigger is invisible to you. Acknowledge first; reassure second.",
    ],
    generatedAt: _seedTimestamp,
  ),

  // ---- 2. refusing_care ----------------------------------------------------
  'refusing_care': DecoderResult(
    say: const <String>[
      'I hear you — you really don\'t want to do this right now. Let\'s pause for a moment.',
      'How about we start with something easier — would you like to wash your face first, or comb your hair?',
      'I\'ll be right here with you the whole time. We can take it one small step at a time.',
    ],
    tweak: const <String>[
      'Offer two simple choices instead of one yes/no question. Move the activity to a calmer, warmer room and bring a familiar object — a favorite towel, a photo — with you.',
    ],
    dontSay: const <String>[
      "Don't say 'you have to' or 'we already talked about this.' Refusal is usually about loss of control, not the task itself. Restoring a small choice often unlocks the rest.",
    ],
    generatedAt: _seedTimestamp,
  ),

  // ---- 3. wants_home -------------------------------------------------------
  'wants_home': DecoderResult(
    say: const <String>[
      'Tell me about home. What do you miss most about it right now?',
      "I know. Home is such a comforting word — let's sit together and look at some pictures of it.",
      "We're going to be okay right here for a little while. You're safe, and I'm not going anywhere.",
    ],
    tweak: const <String>[
      'Bring out a familiar object from their long-term past — an afghan, a coffee mug, a photo album — and invite them to look at it together. "Home" is often a feeling more than an address.',
    ],
    dontSay: const <String>[
      "Don't say 'you are home' or 'this is your home now.' Their brain is asking for a feeling, not a fact — arguing the address will only deepen the distress.",
    ],
    generatedAt: _seedTimestamp,
  ),

  // ---- 4. asking_for_someone ----------------------------------------------
  'asking_for_someone': DecoderResult(
    say: const <String>[
      'Tell me about them. What\'s your favorite memory of them?',
      'They sound wonderful. I love hearing you talk about them.',
      "Let's keep them close right now — would you like to look at a photo together?",
    ],
    tweak: const <String>[
      'Have a small photo of the person they\'re asking for somewhere within reach. Looking at the face together turns the absence into a shared memory instead of a fresh loss.',
    ],
    dontSay: const <String>[
      "Don't say 'they passed away' or 'they've been gone for years.' Re-delivering a death notice every few hours is cruel and doesn't stick. Step into the moment they're remembering.",
    ],
    generatedAt: _seedTimestamp,
  ),

  // ---- 5. accusing ---------------------------------------------------------
  'accusing': DecoderResult(
    say: const <String>[
      "That sounds really upsetting. I'm here with you.",
      'Tell me more about what you\'re feeling.',
      "Let's look in your favorite places together — sometimes the things we treasure most are also the easiest to misplace.",
    ],
    tweak: const <String>[
      "Sit next to her at eye level, not across from her — being 'aligned' physically makes the conversation feel less like interrogation.",
    ],
    dontSay: const <String>[
      "Don't say 'no one took anything' or try to prove the item wasn't stolen. You won't win the story; you'll only confirm her sense that something is wrong and no one believes her.",
    ],
    generatedAt: _seedTimestamp,
  ),

  // ---- 6. sundowning -------------------------------------------------------
  'sundowning': DecoderResult(
    say: const <String>[
      "That sounds really hard. I'm right here with you.",
      "Let's sit together for a moment. You don't have to do anything.",
      "I'm going to dim the lights and put on the song you like — the one we played on Sunday.",
    ],
    tweak: const <String>[
      'Dim overhead lights and switch on a single warm lamp. Turn off the TV.',
    ],
    dontSay: const <String>[
      "Don't say 'you already asked me that' or 'it's not bedtime yet.' Sundowning isn't logic-resolvable — it's the brain in transition. Comfort first.",
    ],
    generatedAt: _seedTimestamp,
  ),

  // ---- 7. wandering --------------------------------------------------------
  'wandering': DecoderResult(
    say: const <String>[
      "It looks like you have somewhere to be. Walk with me for a minute and tell me about it.",
      "I'd love the company — let's take a little loop together through the kitchen and see what's there.",
      'You\'ve been working so hard. How about we sit for a minute and have a sip of something warm?',
    ],
    tweak: const <String>[
      'Join the pace instead of blocking it. Walking alongside for a few minutes usually settles the urge faster than redirection at the door. Make sure shoes are on and the path is clear.',
    ],
    dontSay: const <String>[
      "Don't say 'sit down' or 'you can't leave.' Wandering is almost always an unmet need — energy, restlessness, looking for a person or a purpose. Meet it; don't fight it.",
    ],
    generatedAt: _seedTimestamp,
  ),

  // ---- 8. hallucinating ----------------------------------------------------
  'hallucinating': DecoderResult(
    say: const <String>[
      "I believe you — that sounds startling. I'm right here.",
      'Can you tell me what you\'re seeing? I want to understand.',
      "Let's turn on a brighter light and look together — sometimes shadows play tricks, and I'd like to see what you see.",
    ],
    tweak: const <String>[
      'Turn on more lights, close blinds against window reflections, and remove mirrors or patterned items from the field of view. Many visual hallucinations in dementia are the brain over-interpreting a real shape.',
    ],
    dontSay: const <String>[
      "Don't say 'there's nothing there' or 'you're imagining it.' To them, the experience is fully real. Denial pushes the fear inward; presence and gentle reality-checking together is the lighter touch.",
    ],
    generatedAt: _seedTimestamp,
  ),
};

/// Placeholder timestamp on the canned seeds. The [FakeLLMProvider]
/// replaces this with `DateTime.now()` (or its injected clock) before
/// yielding the `done` chunk — so consumers never see this value.
final DateTime _seedTimestamp = DateTime.utc(2026, 1, 1);

/// The deterministic "catch me up" recap the [FakeLLMProvider] streams
/// for the Home dashboard card (Phase 14.12 / BUILD_SPEC.md §6.1).
///
/// One warm, plain-language paragraph — a factual recap of the last
/// day, in the family vocabulary the rest of the app uses ("your loved
/// one"). It deliberately stays a recap: no diagnosis, no symptom
/// reading, no treatment suggestion, no exclamation marks. The card
/// caches it for 30 minutes so reopening Home doesn't re-stream it.
const String fakeActivitySummary =
    'Over the last day, things have been mostly steady. You logged a '
    'late-afternoon moment when your loved one got upset, and the '
    'gentle approach you tried seemed to settle it. Medications stayed '
    'on track — the evening dose went down without a fuss. There is a '
    'visit with the doctor coming up on the calendar, so it may help to '
    'jot down anything you have noticed before then. All in all, a '
    'manageable day — and you handled it with a lot of care.';
