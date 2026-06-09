import 'package:flutter/material.dart';

/// A row of seven toggleable weekday chips (Mon–Sun) for picking a
/// day-of-week recurrence set. Days use `DateTime.weekday` numbering —
/// Monday = 1 … Sunday = 7 — to match [Medication]'s
/// `MedicationWindowEntry.daysOfWeek` and [CarePlanRoutine.daysOfWeek].
///
/// Stateless: the caller owns the [selected] set and rebuilds on
/// [onChanged]. Mirrors the picker the care-plan routine form already
/// uses so weekly scheduling reads the same across meds + routines.
class WeekdayPicker extends StatelessWidget {
  const WeekdayPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// The currently-selected weekdays (1 = Mon … 7 = Sun).
  final Set<int> selected;

  /// Fired with the next set when a chip is toggled.
  final ValueChanged<Set<int>> onChanged;

  static const List<String> _labels = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];

  /// Per-chip key so tests can target a specific weekday.
  static Key chipKey(int weekday) => Key('weekday-picker-chip-$weekday');

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: <Widget>[
        for (int i = 0; i < 7; i++)
          FilterChip(
            key: chipKey(i + 1),
            label: Text(_labels[i]),
            selected: selected.contains(i + 1),
            onSelected: (bool on) {
              final Set<int> next = <int>{...selected};
              if (on) {
                next.add(i + 1);
              } else {
                next.remove(i + 1);
              }
              onChanged(next);
            },
          ),
      ],
    );
  }
}
