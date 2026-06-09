import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/caregiver.dart';
import '../models/expense.dart';
import '../services/sync_sink.dart';
import 'care_circle_provider.dart';
import 'care_events_provider.dart' show fallbackPatientId;

part 'expenses_provider.g.dart';

/// Logical patient id new expenses are stamped with (TASKS.md Phase 14.33)
/// — the single-install loved one. Aliases the shared neutral
/// [fallbackPatientId] so there's one source of truth for the value.
const String expensesPatientId = fallbackPatientId;

/// Persistence for the Care Team expenses ledger (TASKS.md Phase 14.33).
///
/// Same blob-with-lifted-keys pattern [CareTasksRepository] uses — the
/// freezed [Expense] serialises into the row's `payload`, with
/// [ExpensesTable.paidAtMs] lifted out so the ledger can order newest-first
/// without decoding every blob. Tests build a repository directly against
/// `CareblazersDatabase(NativeDatabase.memory())` so each test gets an
/// isolated DB.
class ExpensesRepository with SyncSinkHost {
  ExpensesRepository(this._db);

  final CareblazersDatabase _db;

  /// Close the underlying database. The riverpod provider wires this to
  /// `ref.onDispose`.
  Future<void> close() => _db.close();

  /// Insert-or-replace [expense] by id.
  Future<void> upsertExpense(Expense expense) async {
    await _db.into(_db.expensesTable).insertOnConflictUpdate(
          ExpensesTableCompanion.insert(
            id: expense.id,
            patientId: expense.patientId,
            paidAtMs: expense.paidAt.millisecondsSinceEpoch,
            payload: jsonEncode(expense.toJson()),
          ),
        );
    emitUpsert('expenses', expense.id, expense.toJson());
  }

  /// Drop the expense with this id. No-op if absent.
  Future<void> deleteExpense(String id) async {
    await (_db.delete(_db.expensesTable)..where((t) => t.id.equals(id))).go();
    emitDelete('expenses', id);
  }

  /// One expense by id, or null if absent.
  Future<Expense?> getExpense(String id) async {
    final ExpensesTableData? row = await (_db.select(_db.expensesTable)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return Expense.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
  }

  /// Every expense, newest paid first (ties broken by id so reads stay
  /// stable). The newest-first order matches how the ledger renders each
  /// month group.
  Future<List<Expense>> listExpenses() async {
    final List<ExpensesTableData> rows = await (_db.select(_db.expensesTable)
          ..orderBy(<OrderClauseGenerator<$ExpensesTableTable>>[
            (t) => OrderingTerm(
                  expression: t.paidAtMs,
                  mode: OrderingMode.desc,
                ),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
    return rows
        .map((ExpensesTableData r) =>
            Expense.fromJson(jsonDecode(r.payload) as Map<String, dynamic>))
        .toList();
  }
}

/// Sum [expenses] into `YYYY-MM` → total-cents buckets (TASKS.md Phase
/// 14.33). The ledger's per-month total and the sticky current-month card
/// both read off this selector. Amounts are summed in their integer cents;
/// the screen assumes a single currency per install (defaults to USD).
Map<String, int> monthlyTotals(Iterable<Expense> expenses) {
  final Map<String, int> totals = <String, int>{};
  for (final Expense e in expenses) {
    totals.update(
      e.monthKey,
      (int sum) => sum + e.amountCents,
      ifAbsent: () => e.amountCents,
    );
  }
  return totals;
}

/// Riverpod-wired singleton (TASKS.md Phase 14.33). The ledger reaches for
/// [expensesRepositoryProvider] and never sees the concrete drift database
/// — same indirection [careTasksRepositoryProvider] uses.
@Riverpod(keepAlive: true)
ExpensesRepository expensesRepositoryBackend(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  return ExpensesRepository(db);
}

/// Alias for consumers — matches the `expensesRepositoryProvider` name the
/// ledger reaches for.
final ExpensesRepositoryBackendProvider expensesRepositoryProvider =
    expensesRepositoryBackendProvider;

/// Wall clock used to default the create form's paid date and to resolve
/// "this month" for the sticky total. Overridable so tests pin a fixed
/// time — same pattern [careTasksClockProvider] uses.
@Riverpod(keepAlive: true)
DateTime Function() expensesClock(Ref ref) => DateTime.now;

/// The loved one's shared expenses ledger (TASKS.md Phase 14.33).
///
/// `build()` loads every expense, newest-first. The mutators ([addExpense]
/// / [updateExpense] / [removeExpense]) write through
/// [expensesRepositoryProvider] and re-read so the screen reflects the
/// change without a manual invalidate — same shape as [CareTasks].
@Riverpod(keepAlive: true)
class Expenses extends _$Expenses {
  @override
  Future<List<Expense>> build() async {
    final ExpensesRepository repo = ref.watch(expensesRepositoryProvider);
    return repo.listExpenses();
  }

  /// Create (or replace) an expense, then refresh.
  Future<void> addExpense(Expense expense) =>
      _mutate((ExpensesRepository repo) => repo.upsertExpense(expense));

  /// Replace an existing expense by id, then refresh.
  Future<void> updateExpense(Expense expense) =>
      _mutate((ExpensesRepository repo) => repo.upsertExpense(expense));

  /// Delete an expense outright, then refresh.
  Future<void> removeExpense(String id) =>
      _mutate((ExpensesRepository repo) => repo.deleteExpense(id));

  Future<void> _mutate(
    Future<void> Function(ExpensesRepository repo) op,
  ) async {
    final ExpensesRepository repo = ref.read(expensesRepositoryProvider);
    state = await AsyncValue.guard(() async {
      await op(repo);
      return repo.listExpenses();
    });
  }
}

/// Caregivers who can be named as the payer — the care circle's roster
/// (TASKS.md Phase 14.33). Drives the create form's payer picker and the
/// row's payer-initials resolution.
@riverpod
Future<List<Caregiver>> expensePayerCandidates(Ref ref) async {
  final CareCircleRepository repo = ref.watch(careCircleRepositoryProvider);
  return repo.listCaregivers();
}

/// One expense paired with its resolved payer, if any (TASKS.md Phase
/// 14.33). The ledger renders one of these per row — the expense supplies
/// the amount / kind / description, and [payer] (looked up softly from the
/// care circle) supplies the initials avatar + name.
@immutable
class ExpenseRow {
  const ExpenseRow({required this.expense, this.payer});

  final Expense expense;

  /// The caregiver who paid, when it resolves to a care-circle row; null
  /// for a payer without a roster entry (e.g. before they're listed).
  final Caregiver? payer;
}

/// One `YYYY-MM` section of the ledger — a month label, its summed total,
/// and the rows that fall in it, newest-first (TASKS.md Phase 14.33).
@immutable
class ExpenseMonthGroup {
  const ExpenseMonthGroup({
    required this.monthKey,
    required this.totalCents,
    required this.rows,
  });

  /// The `YYYY-MM` bucket key.
  final String monthKey;

  /// Sum of every row's `amountCents` in this month.
  final int totalCents;

  final List<ExpenseRow> rows;
}

/// The grouped ledger view the screen watches (TASKS.md Phase 14.33).
///
/// Watches the [Expenses] notifier (not the repository directly) so an add
/// / update / remove saved through the notifier refreshes the view without
/// a manual invalidate, joins each expense to its payer via
/// [expensePayerCandidates], and buckets the rows into newest-first
/// `YYYY-MM` groups (each carrying its [monthlyTotals] sum). Tests override
/// this provider wholesale for the display + golden cases, and drive the
/// notifier + repository for the CRUD cases.
@riverpod
Future<List<ExpenseMonthGroup>> expensesView(Ref ref) async {
  final List<Expense> expenses = await ref.watch(expensesProvider.future);
  final List<Caregiver> caregivers =
      await ref.watch(expensePayerCandidatesProvider.future);
  final Map<String, Caregiver> byId = <String, Caregiver>{
    for (final Caregiver c in caregivers) c.id: c,
  };
  final Map<String, int> totals = monthlyTotals(expenses);

  // The repository already returns expenses newest-first, so grouping in
  // encounter order yields newest-first months with newest-first rows.
  final Map<String, List<ExpenseRow>> grouped =
      <String, List<ExpenseRow>>{};
  for (final Expense e in expenses) {
    grouped.putIfAbsent(e.monthKey, () => <ExpenseRow>[]).add(
          ExpenseRow(expense: e, payer: byId[e.paidByCaregiverId]),
        );
  }

  return <ExpenseMonthGroup>[
    for (final MapEntry<String, List<ExpenseRow>> entry in grouped.entries)
      ExpenseMonthGroup(
        monthKey: entry.key,
        totalCents: totals[entry.key] ?? 0,
        rows: entry.value,
      ),
  ];
}
