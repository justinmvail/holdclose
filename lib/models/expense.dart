import 'package:freezed_annotation/freezed_annotation.dart';

part 'expense.freezed.dart';
part 'expense.g.dart';

/// What a shared care expense was spent on (TASKS.md Phase 14.33,
/// BUILD_SPEC.md §5.14).
///
/// An organisational tag the caregiver picks when logging a cost — it
/// drives the kind chip on each row and nothing clinical. One token per
/// value so the JSON name matches the enum name exactly
/// (`json_serializable` serialises enums by `.name`).
enum ExpenseKind {
  meds,
  groceries,
  transport,
  equipment,
  aide,
  other,
}

/// One shared cost logged on the Care Team expenses ledger (TASKS.md
/// Phase 14.33, BUILD_SPEC.md §5.14).
///
/// A caregiver records an [amountCents] (integer cents to dodge floating
/// point) in a [currency] (defaults to `USD`), a [description], the
/// [kind] of expense, who paid it ([paidByCaregiverId]), and when
/// ([paidAt]). An optional [receiptPath] points at an on-disk receipt
/// image/scan. The ledger groups rows by `YYYY-MM` and shows a per-month
/// total.
///
/// [patientId] is a logical link to the single-row patients table, carried
/// explicitly so a future multi-patient model lands without a migration —
/// mirroring the care-event + care-task + care-shift models.
@freezed
abstract class Expense with _$Expense {
  const factory Expense({
    required String id,
    required int amountCents,
    @Default('USD') String currency,
    required String description,

    /// The caregiver who paid — resolved softly to a care-circle row at
    /// read time for the row's initials avatar.
    required String paidByCaregiverId,
    required DateTime paidAt,
    required ExpenseKind kind,

    /// Optional on-disk pointer to a receipt image/scan; null when none
    /// was attached.
    String? receiptPath,
    required String patientId,
  }) = _Expense;

  factory Expense.fromJson(Map<String, dynamic> json) =>
      _$ExpenseFromJson(json);
}

/// Grouping helpers for [Expense], kept off the freezed factory so the
/// generated model stays a pure data class.
extension ExpenseX on Expense {
  /// The `YYYY-MM` bucket this expense sorts into — the key the ledger
  /// groups + totals by (BUILD_SPEC.md §5.14).
  String get monthKey =>
      '${paidAt.year.toString().padLeft(4, '0')}-'
      '${paidAt.month.toString().padLeft(2, '0')}';
}
