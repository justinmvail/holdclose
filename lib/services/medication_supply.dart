import '../models/medication.dart';

/// How a medication's refill runway looks right now.
enum SupplyStatus {
  /// Not enough label data to estimate (no quantity/refills/date, or an
  /// as-needed med with no daily schedule).
  unknown,

  /// Supply + refills look fine.
  ok,

  /// The current fill runs out soon — refill while there's time.
  refillSoon,

  /// No refills left on the prescription — the caregiver must contact the
  /// prescriber to renew, not just call the pharmacy.
  outOfRefills,
}

/// A best-effort read of a medication's supply runway, computed purely from
/// the label fields the scan captures (quantity, refills, date filled) plus
/// how many scheduled doses it takes per day.
class MedicationSupply {
  const MedicationSupply({
    required this.status,
    this.daysOfSupply,
    this.runOutDate,
    this.refillsRemaining,
  });

  final SupplyStatus status;

  /// Estimated days one fill lasts (quantity ÷ doses-per-day), or null.
  final int? daysOfSupply;

  /// Estimated run-out date (date filled + days of supply), or null when
  /// the fill date couldn't be parsed.
  final DateTime? runOutDate;

  /// Refills remaining parsed off the label, or null when not readable.
  final int? refillsRemaining;

  bool get needsAttention =>
      status == SupplyStatus.refillSoon || status == SupplyStatus.outOfRefills;
}

/// Estimate a medication's supply runway. Everything is best-effort: a field
/// we can't read or parse simply drops out, and the result degrades to
/// [SupplyStatus.unknown] rather than guessing.
///
/// This is arithmetic on the caregiver's OWN captured data to help plan a
/// reorder — never medical advice, and it never changes anything on its own.
/// [scheduledDosesPerDay] should exclude as-needed windows (their
/// consumption is unpredictable); when it's 0 the days-of-supply estimate is
/// left null. Over-counting doses errs toward an *earlier* refill nudge,
/// which is the safe direction.
MedicationSupply computeMedicationSupply(
  Medication med, {
  required int scheduledDosesPerDay,
  required DateTime now,
  int refillSoonWithinDays = 10,
}) {
  final int? qty = _leadingInt(med.quantity);
  final int? refills = _leadingInt(med.refills);
  final int? days = (scheduledDosesPerDay > 0 && qty != null && qty > 0)
      ? qty ~/ scheduledDosesPerDay
      : null;
  final DateTime? filled = parseUsLabelDate(med.dateFilled);
  final DateTime? runOut =
      (filled != null && days != null) ? filled.add(Duration(days: days)) : null;

  final SupplyStatus status;
  if (refills != null && refills <= 0) {
    status = SupplyStatus.outOfRefills;
  } else if (runOut != null &&
      !runOut.isAfter(now.add(Duration(days: refillSoonWithinDays)))) {
    status = SupplyStatus.refillSoon;
  } else if (days != null || refills != null) {
    status = SupplyStatus.ok;
  } else {
    status = SupplyStatus.unknown;
  }

  return MedicationSupply(
    status: status,
    daysOfSupply: days,
    runOutDate: runOut,
    refillsRemaining: refills,
  );
}

/// First run of digits in [s] as an int ("3 by 5/27/22" → 3, "0" → 0,
/// "PRN" → null). Visible for tests.
int? _leadingInt(String? s) {
  if (s == null) return null;
  final Match? m = RegExp(r'\d+').firstMatch(s);
  return m == null ? null : int.tryParse(m.group(0)!);
}

/// Parse a US-format label date ("12/3/21", "12/03/2021", "12-3-21") into a
/// [DateTime]; null on anything it can't confidently read. Two-digit years
/// are treated as 20xx. Visible for tests.
DateTime? parseUsLabelDate(String? s) {
  if (s == null) return null;
  final String text = s.trim();

  // 8/3/2026, 08-03-26 …
  final Match? numeric =
      RegExp(r'(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})').firstMatch(text);
  if (numeric != null) {
    return _dateFrom(
      month: int.parse(numeric.group(1)!),
      day: int.parse(numeric.group(2)!),
      year: int.parse(numeric.group(3)!),
    );
  }

  // "August 3, 2026" / "Aug 3 2026" / "3 August 2026".
  //
  // Appointment cards print the month by NAME far more often than as digits,
  // and this parser only accepted digits — so a scanned card produced an
  // appointment with NO DATE, which is a useless appointment. Found by running
  // the real scanner against the live model (2026-07-13): the model read
  // "August 3, 2026" correctly and the app threw it away.
  final Match? named = RegExp(
    r'([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})',
    caseSensitive: false,
  ).firstMatch(text);
  if (named != null) {
    final int? month = _monthFromName(named.group(1)!);
    if (month != null) {
      return _dateFrom(
        month: month,
        day: int.parse(named.group(2)!),
        year: int.parse(named.group(3)!),
      );
    }
  }
  final Match? dayFirst = RegExp(
    r'(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]{3,9})\.?,?\s+(\d{4})',
    caseSensitive: false,
  ).firstMatch(text);
  if (dayFirst != null) {
    final int? month = _monthFromName(dayFirst.group(2)!);
    if (month != null) {
      return _dateFrom(
        month: month,
        day: int.parse(dayFirst.group(1)!),
        year: int.parse(dayFirst.group(3)!),
      );
    }
  }
  return null;
}

/// Build a date, rejecting impossible ones (2/30 must not roll into March).
DateTime? _dateFrom({
  required int month,
  required int day,
  required int year,
}) {
  int y = year;
  if (y < 100) y += 2000;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final DateTime d = DateTime(y, month, day);
  if (d.month != month || d.day != day) return null;
  return d;
}

/// Month number from a full or 3+ letter abbreviated English month name.
int? _monthFromName(String raw) {
  final String name = raw.toLowerCase();
  const List<String> months = <String>[
    'january', 'february', 'march', 'april', 'may', 'june',
    'july', 'august', 'september', 'october', 'november', 'december',
  ];
  for (int i = 0; i < months.length; i++) {
    if (months[i].startsWith(name) || name.startsWith(months[i].substring(0, 3))) {
      // Guard the sept/sep ambiguity-free case: a 3-letter prefix is unique
      // across English months.
      if (months[i].startsWith(name.substring(0, 3))) return i + 1;
    }
  }
  return null;
}
