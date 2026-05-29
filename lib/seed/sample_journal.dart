import '../models/behavior.dart';
import '../models/decoder_result.dart';
import '../models/journal_entry.dart';
import '../models/triage.dart';
import 'fake_llm_seeds.dart';

/// Demo seed journal entries (BUILD_SPEC.md §9.2).
///
/// Six auto-logged decoder runs spanning the last ~10 days, weighted to
/// demonstrate the §7.6 pattern detector: three sundowning entries inside
/// the trailing 7-day window so the journal "Heads up" card surfaces the
/// canonical sundowning alert without any user interaction.
///
/// Dates are computed relative to [clock] (defaults to [DateTime.now]) so
/// the seed always looks fresh — the autoloop runs against a moving
/// "today" and the demo tour expects entries to land under "Today /
/// Yesterday" not "older". The [DecoderResult] bodies are reused from
/// [fakeLLMSeeds] so the on-screen scripts match what the FakeLLMProvider
/// would emit if the caregiver ran the decoder live.
///
/// Authored alongside Task 26's reset-on-launch wiring. Task 33 owns the
/// long-term home of this file; refinements to body content + outcome
/// distribution belong there.
List<JournalEntry> sampleJournalEntries({DateTime Function()? clock}) {
  final DateTime now = (clock ?? DateTime.now)();

  return <JournalEntry>[
    _entry(
      id: 'seed-sundowning-1',
      behaviorId: 'sundowning',
      createdAt: now.subtract(const Duration(days: 1, hours: 4)),
      triage: const TriageAnswers(
        when: TriageWhen.lateAfternoonEvening,
        whatChanged: TriageWhatChanged.nothing,
        whatTried: TriageWhatTried.talked,
      ),
      outcome: JournalOutcome.positive,
      notes: 'Dimmed the lamps and put on the Sunday playlist. Settled within '
          'ten minutes.',
    ),
    _entry(
      id: 'seed-sundowning-2',
      behaviorId: 'sundowning',
      createdAt: now.subtract(const Duration(days: 3, hours: 5)),
      triage: const TriageAnswers(
        when: TriageWhen.lateAfternoonEvening,
        whatChanged: TriageWhatChanged.environment,
        whatTried: TriageWhatTried.distracted,
      ),
      outcome: JournalOutcome.positive,
    ),
    _entry(
      id: 'seed-sundowning-3',
      behaviorId: 'sundowning',
      createdAt: now.subtract(const Duration(days: 5, hours: 6)),
      triage: const TriageAnswers(
        when: TriageWhen.lateAfternoonEvening,
        whatChanged: TriageWhatChanged.nothing,
        whatTried: TriageWhatTried.walkedAway,
      ),
      outcome: JournalOutcome.triedDifferent,
      attempt: 1,
    ),
    _entry(
      id: 'seed-refusing-care-1',
      behaviorId: 'refusing_care',
      createdAt: now.subtract(const Duration(days: 2, hours: 9)),
      triage: const TriageAnswers(
        when: TriageWhen.morning,
        whatChanged: TriageWhatChanged.nothing,
        whatTried: TriageWhatTried.triedToExplain,
      ),
      outcome: JournalOutcome.positive,
      notes: 'Offered the warm-towel-first detour. She let me help with the '
          'rest of the routine.',
    ),
    _entry(
      id: 'seed-accusing-1',
      behaviorId: 'accusing',
      createdAt: now.subtract(const Duration(days: 7, hours: 2)),
      triage: const TriageAnswers(
        when: TriageWhen.afternoon,
        whatChanged: TriageWhatChanged.nothing,
        whatTried: TriageWhatTried.triedToExplain,
      ),
      outcome: JournalOutcome.positive,
    ),
    _entry(
      id: 'seed-asking-for-someone-1',
      behaviorId: 'asking_for_someone',
      createdAt: now.subtract(const Duration(days: 9, hours: 3)),
      triage: const TriageAnswers(
        when: TriageWhen.morning,
        whatChanged: TriageWhatChanged.nothing,
        whatTried: TriageWhatTried.nothingYet,
      ),
      outcome: JournalOutcome.positive,
      notes: '"Where is your father?" — sat with her with the wedding album.',
    ),
  ];
}

JournalEntry _entry({
  required String id,
  required String behaviorId,
  required DateTime createdAt,
  required TriageAnswers triage,
  required JournalOutcome outcome,
  int attempt = 0,
  String? notes,
}) {
  final Behavior behavior = Behavior.byId(behaviorId)!;
  final DecoderResult seed = fakeLLMSeeds[behaviorId]!;
  return JournalEntry(
    id: id,
    behavior: behavior,
    triage: triage,
    result: DecoderResult(
      say: seed.say,
      tweak: seed.tweak,
      dontSay: seed.dontSay,
      generatedAt: createdAt,
    ),
    outcome: outcome,
    attempt: attempt,
    createdAt: createdAt,
    notes: notes,
  );
}
