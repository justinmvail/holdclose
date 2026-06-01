import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/models/expense.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/expenses_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';

Expense _expense({
  required String id,
  int amountCents = 1000,
  String currency = 'USD',
  String description = 'Pharmacy copay',
  String paidByCaregiverId = 'me',
  DateTime? paidAt,
  ExpenseKind kind = ExpenseKind.meds,
  String? receiptPath,
}) =>
    Expense(
      id: id,
      amountCents: amountCents,
      currency: currency,
      description: description,
      paidByCaregiverId: paidByCaregiverId,
      paidAt: paidAt ?? DateTime.utc(2026, 6, 1, 9),
      kind: kind,
      receiptPath: receiptPath,
      patientId: _patientId,
    );

void main() {
  group('monthlyTotals selector', () {
    test('sums amountCents into YYYY-MM buckets', () {
      final Map<String, int> totals = monthlyTotals(<Expense>[
        _expense(id: 'a', amountCents: 1000, paidAt: DateTime.utc(2026, 6, 2)),
        _expense(id: 'b', amountCents: 2500, paidAt: DateTime.utc(2026, 6, 20)),
        _expense(id: 'c', amountCents: 700, paidAt: DateTime.utc(2026, 5, 9)),
      ]);

      expect(totals['2026-06'], 3500);
      expect(totals['2026-05'], 700);
      expect(totals.keys, hasLength(2));
    });

    test('is empty for no expenses', () {
      expect(monthlyTotals(<Expense>[]), isEmpty);
    });
  });

  group('ExpensesRepository — CRUD', () {
    late CareblazersDatabase db;
    late ExpensesRepository repo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = ExpensesRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('expense round-trips through the payload blob', () async {
      await repo.upsertExpense(_expense(
        id: 'e1',
        amountCents: 4250,
        currency: 'EUR',
        receiptPath: '/r/1.jpg',
        kind: ExpenseKind.equipment,
      ));

      final Expense? loaded = await repo.getExpense('e1');
      expect(loaded, isNotNull);
      expect(loaded!.amountCents, 4250);
      expect(loaded.currency, 'EUR');
      expect(loaded.receiptPath, '/r/1.jpg');
      expect(loaded.kind, ExpenseKind.equipment);
    });

    test('listExpenses orders newest paid first', () async {
      await repo.upsertExpense(
          _expense(id: 'old', paidAt: DateTime.utc(2026, 1, 1)));
      await repo.upsertExpense(
          _expense(id: 'new', paidAt: DateTime.utc(2026, 6, 1)));
      await repo.upsertExpense(
          _expense(id: 'mid', paidAt: DateTime.utc(2026, 3, 1)));

      final List<Expense> all = await repo.listExpenses();
      expect(all.map((Expense e) => e.id), <String>['new', 'mid', 'old']);
    });

    test('deleteExpense removes the row; wipeAll truncates the table',
        () async {
      await repo.upsertExpense(_expense(id: 'e1'));
      await repo.deleteExpense('e1');
      expect(await repo.getExpense('e1'), isNull);

      await repo.upsertExpense(_expense(id: 'e2'));
      await db.wipeAll();
      expect(await repo.listExpenses(), isEmpty);
    });
  });

  group('Expenses notifier — CRUD', () {
    late CareblazersDatabase db;
    late ExpensesRepository repo;

    ProviderContainer makeContainer() {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          expensesRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      repo = ExpensesRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('addExpense lands an expense in the ledger', () async {
      final ProviderContainer container = makeContainer();
      await container.read(expensesProvider.future);

      await container
          .read(expensesProvider.notifier)
          .addExpense(_expense(id: 'e1'));

      final List<Expense> expenses =
          await container.read(expensesProvider.future);
      expect(expenses.single.id, 'e1');
    });

    test('updateExpense replaces an existing row by id', () async {
      await repo.upsertExpense(_expense(id: 'e1', amountCents: 1000));
      final ProviderContainer container = makeContainer();
      await container.read(expensesProvider.future);

      await container.read(expensesProvider.notifier).updateExpense(
            _expense(id: 'e1', amountCents: 5000, description: 'Updated'),
          );

      final Expense updated = (await container.read(expensesProvider.future))
          .firstWhere((Expense e) => e.id == 'e1');
      expect(updated.amountCents, 5000);
      expect(updated.description, 'Updated');
    });

    test('removeExpense deletes the expense', () async {
      await repo.upsertExpense(_expense(id: 'e1'));
      final ProviderContainer container = makeContainer();
      await container.read(expensesProvider.future);

      await container.read(expensesProvider.notifier).removeExpense('e1');

      expect(await container.read(expensesProvider.future), isEmpty);
    });
  });

  group('expensesView — grouping + payer join', () {
    late CareblazersDatabase db;
    late ExpensesRepository expensesRepo;
    late CareCircleRepository circleRepo;

    setUp(() {
      db = CareblazersDatabase(NativeDatabase.memory());
      expensesRepo = ExpensesRepository(db);
      circleRepo = CareCircleRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    ProviderContainer makeContainer() {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          expensesRepositoryProvider.overrideWithValue(expensesRepo),
          careCircleRepositoryProvider.overrideWithValue(circleRepo),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('groups newest month first, each carrying its summed total',
        () async {
      await expensesRepo.upsertExpense(_expense(
          id: 'june1', amountCents: 1000, paidAt: DateTime.utc(2026, 6, 2)));
      await expensesRepo.upsertExpense(_expense(
          id: 'june2', amountCents: 2500, paidAt: DateTime.utc(2026, 6, 20)));
      await expensesRepo.upsertExpense(_expense(
          id: 'may1', amountCents: 700, paidAt: DateTime.utc(2026, 5, 9)));

      final List<ExpenseMonthGroup> groups =
          await makeContainer().read(expensesViewProvider.future);

      expect(groups.map((ExpenseMonthGroup g) => g.monthKey),
          <String>['2026-06', '2026-05']);
      expect(groups.first.totalCents, 3500);
      // Rows within the month are newest-first.
      expect(groups.first.rows.map((ExpenseRow r) => r.expense.id),
          <String>['june2', 'june1']);
      expect(groups[1].totalCents, 700);
    });

    test('resolves the payer caregiver when they are on the roster', () async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'c1',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await expensesRepo
          .upsertExpense(_expense(id: 'e1', paidByCaregiverId: 'c1'));
      await expensesRepo
          .upsertExpense(_expense(id: 'e2', paidByCaregiverId: 'ghost'));

      final List<ExpenseRow> rows =
          (await makeContainer().read(expensesViewProvider.future))
              .expand((ExpenseMonthGroup g) => g.rows)
              .toList();

      final ExpenseRow resolved =
          rows.firstWhere((ExpenseRow r) => r.expense.id == 'e1');
      final ExpenseRow unresolved =
          rows.firstWhere((ExpenseRow r) => r.expense.id == 'e2');
      expect(resolved.payer?.displayName, 'Maria Lopez');
      expect(unresolved.payer, isNull);
    });
  });
}
