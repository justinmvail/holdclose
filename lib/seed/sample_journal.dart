import '../models/journal_entry.dart';

/// Demo seed journal entries (BUILD_SPEC.md §9.2).
///
/// Six caregiver-authored entries spanning the last ~10 days, so the
/// journal screen opens with a populated "This week" summary and a
/// realistic Today / Yesterday / Earlier grouping instead of the empty
/// state.
///
/// Dates are computed relative to [clock] (defaults to [DateTime.now]) so
/// the seed always looks fresh — the demo tour expects entries to land
/// under "Today / Yesterday" not "older".
List<JournalEntry> sampleJournalEntries({DateTime Function()? clock}) {
  final DateTime now = (clock ?? DateTime.now)();

  return <JournalEntry>[
    _entry(
      id: 'seed-journal-1',
      createdAt: now.subtract(const Duration(days: 1, hours: 4)),
      situationText: 'Restless and anxious as the light faded in the late '
          'afternoon — kept getting up and pacing the hallway.',
      attemptsText: 'Dimmed the lamps and put on the Sunday playlist.',
      notes: 'Settled within ten minutes.',
    ),
    _entry(
      id: 'seed-journal-2',
      createdAt: now.subtract(const Duration(days: 3, hours: 5)),
      situationText: 'Unsettled again in the evening after the visitors left.',
      attemptsText: 'Took a slow walk to the kitchen for tea and a snack.',
    ),
    _entry(
      id: 'seed-journal-3',
      createdAt: now.subtract(const Duration(days: 5, hours: 6)),
      situationText: 'Agitated late in the day and didn\'t want company.',
      attemptsText: 'Gave her some quiet space, then checked back in after a '
          'few minutes.',
    ),
    _entry(
      id: 'seed-journal-4',
      createdAt: now.subtract(const Duration(days: 2, hours: 9)),
      situationText: 'Refused help with the morning routine — pushed back on '
          'getting washed up.',
      attemptsText: 'Offered the warm-towel-first detour.',
      notes: 'She let me help with the rest of the routine.',
    ),
    _entry(
      id: 'seed-journal-5',
      createdAt: now.subtract(const Duration(days: 7, hours: 2)),
      situationText: 'Convinced I had moved her purse and got upset about it.',
      attemptsText: 'Didn\'t argue — helped her look, and we found it together '
          'on the chair.',
    ),
    _entry(
      id: 'seed-journal-6',
      createdAt: now.subtract(const Duration(days: 9, hours: 3)),
      situationText: '"Where is your father?" first thing in the morning.',
      attemptsText: 'Sat with her and the wedding album for a while.',
    ),
  ];
}

JournalEntry _entry({
  required String id,
  required DateTime createdAt,
  String? situationText,
  String? attemptsText,
  String? notes,
}) {
  return JournalEntry(
    id: id,
    createdAt: createdAt,
    occurredAt: createdAt,
    situationText: situationText,
    attemptsText: attemptsText,
    notes: notes,
  );
}
