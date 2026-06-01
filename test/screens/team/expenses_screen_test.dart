import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/models/expense.dart';
import 'package:careblazers/providers/care_circle_provider.dart';
import 'package:careblazers/providers/care_tasks_provider.dart'
    show currentCaregiverIdProvider;
import 'package:careblazers/providers/expenses_provider.dart';
import 'package:careblazers/screens/team/expenses_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';
const String _me = 'demo-caregiver-me';
final DateTime _clock = DateTime.utc(2026, 6, 15, 12);

Expense _expense({
  required String id,
  int amountCents = 1000,
  String description = 'Pharmacy copay',
  String paidByCaregiverId = _me,
  DateTime? paidAt,
  ExpenseKind kind = ExpenseKind.meds,
  String? receiptPath,
}) =>
    Expense(
      id: id,
      amountCents: amountCents,
      description: description,
      paidByCaregiverId: paidByCaregiverId,
      paidAt: paidAt ?? DateTime.utc(2026, 6, 1, 9),
      kind: kind,
      receiptPath: receiptPath,
      patientId: _patientId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareblazersDatabase db;
  late ExpensesRepository expensesRepo;
  late CareCircleRepository circleRepo;
  int ids = 0;

  setUp(() {
    db = CareblazersDatabase(NativeDatabase.memory());
    expensesRepo = ExpensesRepository(db);
    circleRepo = CareCircleRepository(db);
    ids = 0;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(460, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          expensesRepositoryProvider.overrideWithValue(expensesRepo),
          careCircleRepositoryProvider.overrideWithValue(circleRepo),
          expensesClockProvider.overrideWithValue(() => _clock),
          currentCaregiverIdProvider.overrideWithValue(_me),
          expenseIdFactoryProvider.overrideWithValue(() => 'new-${ids++}'),
        ],
        child: const MaterialApp(home: ExpensesScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ExpensesScreen — ledger', () {
    testWidgets('empty ledger shows the sticky total card and empty state',
        (tester) async {
      await pump(tester);

      expect(find.byKey(ExpensesScreen.monthlyTotalCardKey), findsOneWidget);
      expect(find.byKey(ExpensesScreen.emptyStateKey), findsOneWidget);
      // No expenses this month → $0.00.
      expect(find.text(r'$0.00'), findsOneWidget);
      expect(find.text('Spent in June 2026'), findsOneWidget);
    });

    testWidgets('groups expenses by month with a per-month total',
        (tester) async {
      await expensesRepo.upsertExpense(_expense(
          id: 'june1', amountCents: 1200, paidAt: DateTime.utc(2026, 6, 3)));
      await expensesRepo.upsertExpense(_expense(
          id: 'may1', amountCents: 800, paidAt: DateTime.utc(2026, 5, 9)));

      await pump(tester);

      expect(find.byKey(ExpensesScreen.rowKey('june1')), findsOneWidget);
      expect(find.byKey(ExpensesScreen.rowKey('may1')), findsOneWidget);
      expect(find.byKey(ExpensesScreen.monthHeaderKey('2026-06')),
          findsOneWidget);
      expect(find.byKey(ExpensesScreen.monthHeaderKey('2026-05')),
          findsOneWidget);
    });

    testWidgets('sticky card totals only the current month', (tester) async {
      // Two in June (the clock's month), one in May.
      await expensesRepo.upsertExpense(_expense(
          id: 'june1', amountCents: 1000, paidAt: DateTime.utc(2026, 6, 3)));
      await expensesRepo.upsertExpense(_expense(
          id: 'june2', amountCents: 2500, paidAt: DateTime.utc(2026, 6, 20)));
      await expensesRepo.upsertExpense(_expense(
          id: 'may1', amountCents: 9999, paidAt: DateTime.utc(2026, 5, 9)));

      await pump(tester);

      // $35.00 = the two June rows, not the May one.
      final Finder card = find.byKey(ExpensesScreen.monthlyTotalCardKey);
      expect(
        find.descendant(of: card, matching: find.text(r'$35.00')),
        findsOneWidget,
      );
    });

    testWidgets('row shows the resolved payer name; "You" for the signed-in me',
        (tester) async {
      await circleRepo.upsertCaregiver(const Caregiver(
        id: 'maria',
        displayName: 'Maria Lopez',
        role: CaregiverRole.aide,
      ));
      await expensesRepo.upsertExpense(
          _expense(id: 'mine', paidByCaregiverId: _me));
      await expensesRepo.upsertExpense(
          _expense(id: 'hers', paidByCaregiverId: 'maria'));

      await pump(tester);

      expect(find.text('You'), findsOneWidget);
      expect(find.text('Maria Lopez'), findsOneWidget);
    });
  });

  group('ExpensesScreen — create sheet', () {
    testWidgets('FAB opens the create sheet', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ExpensesScreen.fabKey));
      await tester.pumpAndSettle();
      expect(find.byKey(ExpensesScreen.createSheetKey), findsOneWidget);
    });

    testWidgets('saving with no amount or description shows errors and saves '
        'nothing', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ExpensesScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ExpensesScreen.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(ExpensesScreen.amountErrorKey), findsOneWidget);
      expect(find.byKey(ExpensesScreen.descriptionErrorKey), findsOneWidget);
      expect(await expensesRepo.listExpenses(), isEmpty);
    });

    testWidgets('a complete expense is created and lands on the ledger',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ExpensesScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(ExpensesScreen.amountFieldKey), '42.50');
      await tester.enterText(
          find.byKey(ExpensesScreen.descriptionFieldKey), 'New walker');
      await tester.tap(find.byKey(
          ExpensesScreen.kindOptionKey(ExpenseKind.equipment)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ExpensesScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Sheet closed, the row is on the ledger.
      expect(find.byKey(ExpensesScreen.createSheetKey), findsNothing);
      expect(find.text('New walker'), findsOneWidget);

      final List<Expense> all = await expensesRepo.listExpenses();
      expect(all.single.amountCents, 4250);
      expect(all.single.description, 'New walker');
      expect(all.single.kind, ExpenseKind.equipment);
      // Defaults the payer to the signed-in caregiver.
      expect(all.single.paidByCaregiverId, _me);
    });

    testWidgets('an optional receipt path is persisted', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ExpensesScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(ExpensesScreen.amountFieldKey), '10');
      await tester.enterText(
          find.byKey(ExpensesScreen.descriptionFieldKey), 'Taxi');
      await tester.enterText(
          find.byKey(ExpensesScreen.receiptFieldKey), '/r/taxi.jpg');
      await tester.tap(find.byKey(ExpensesScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<Expense> all = await expensesRepo.listExpenses();
      expect(all.single.receiptPath, '/r/taxi.jpg');
    });
  });
}
