/// Shared date/time formatting primitives for screen-level labels.
///
/// Consolidates the month-abbreviation table + the two formatters that
/// were hand-rolled (byte-identically) across the feature screens. Only
/// formats whose OUTPUT is identical everywhere live here — a screen
/// whose stamp differs (lowercase am/pm, ":00"-less clock, long month
/// names, …) keeps its own local helper.
library;

/// Three-letter English month abbreviations, January first.
const List<String> monthAbbreviations = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Jun 3, 2026" — abbreviated month, day, full year.
String formatMonthDayYear(DateTime t) =>
    '${monthAbbreviations[t.month - 1]} ${t.day}, ${t.year}';

/// "2:30 PM" — 12-hour clock, no leading zero on the hour, two-digit
/// minutes, uppercase AM/PM.
String formatClock12h(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}
