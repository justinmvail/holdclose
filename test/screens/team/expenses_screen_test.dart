import 'package:holdclose/db/database.dart';
import 'package:holdclose/models/caregiver.dart';
import 'package:holdclose/models/expense.dart';
import 'package:holdclose/providers/care_circle_provider.dart';
import 'package:holdclose/providers/care_tasks_provider.dart'
    show currentCaregiverIdProvider;
import 'package:holdclose/providers/expenses_provider.dart';
import 'package:holdclose/providers/photo_attacher_provider.dart';
import 'package:holdclose/providers/storage_provider.dart';
import 'package:holdclose/screens/team/expenses_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';
const String _me = 'demo-caregiver-me';
final DateTime _clock = DateTime.utc(2026, 6, 15, 12);

/// Stand-in [PhotoAttacher] that returns a deterministic path and tracks
/// how many times the picker was invoked — same seam the journal entry's
/// photo attach uses.
class _FakePhotoAttacher implements PhotoAttacher {
  _FakePhotoAttacher(this.path);

  final String? path;
  int calls = 0;

  @override
  Future<String?> pickPhoto({
    PhotoSource source = PhotoSource.library,
    int maxSide = 2048,
    int quality = 80,
  }) async {
    calls++;
    return path;
  }
}

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

  late HoldcloseDatabase db;
  late ExpensesRepository expensesRepo;
  late CareCircleRepository circleRepo;
  int ids = 0;

  setUp(() {
    db = HoldcloseDatabase(NativeDatabase.memory());
    expensesRepo = ExpensesRepository(db);
    circleRepo = CareCircleRepository(db);
    ids = 0;
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {PhotoAttacher? attacher}) async {
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
          if (attacher != null)
            photoAttacherProvider.overrideWithValue(attacher),
          // Creating an expense now resolves the active loved one via
          // activePatientIdProvider → storageProvider; an empty in-memory
          // store keeps the test off the on-device sqlite file and falls
          // back to 'demo-patient-mary' (== _patientId), so the stamped
          // patientId is unchanged.
          storageBackendProvider.overrideWithValue(InMemoryStorageProvider()),
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

    testWidgets('attaching a receipt photo shows a thumbnail and persists '
        'the path', (tester) async {
      final _FakePhotoAttacher attacher =
          _FakePhotoAttacher('/r/grocery.jpg');
      await pump(tester, attacher: attacher);
      await tester.tap(find.byKey(ExpensesScreen.fabKey));
      await tester.pumpAndSettle();

      // No thumbnail until a receipt is attached.
      expect(find.byKey(ExpensesScreen.receiptThumbnailKey), findsNothing);

      await tester.enterText(find.byKey(ExpensesScreen.amountFieldKey), '24');
      await tester.enterText(
          find.byKey(ExpensesScreen.descriptionFieldKey), 'Groceries');
      await tester.tap(find.byKey(ExpensesScreen.receiptButtonKey));
      await tester.pumpAndSettle();

      // Picker was invoked once and a thumbnail preview now shows.
      expect(attacher.calls, 1);
      expect(find.byKey(ExpensesScreen.receiptThumbnailKey), findsOneWidget);

      await tester.tap(find.byKey(ExpensesScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<Expense> all = await expensesRepo.listExpenses();
      expect(all.single.receiptPath, '/r/grocery.jpg');
    });

    testWidgets('cancelling the receipt picker leaves the path null',
        (tester) async {
      final _FakePhotoAttacher attacher = _FakePhotoAttacher(null);
      await pump(tester, attacher: attacher);
      await tester.tap(find.byKey(ExpensesScreen.fabKey));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(ExpensesScreen.amountFieldKey), '24');
      await tester.enterText(
          find.byKey(ExpensesScreen.descriptionFieldKey), 'Groceries');
      await tester.tap(find.byKey(ExpensesScreen.receiptButtonKey));
      await tester.pumpAndSettle();

      expect(attacher.calls, 1);
      expect(find.byKey(ExpensesScreen.receiptThumbnailKey), findsNothing);

      await tester.tap(find.byKey(ExpensesScreen.saveButtonKey));
      await tester.pumpAndSettle();

      final List<Expense> all = await expensesRepo.listExpenses();
      expect(all.single.receiptPath, isNull);
    });
  });

  group('ExpensesScreen — edit + delete a row', () {
    testWidgets('tapping a row opens the create sheet prefilled for editing',
        (tester) async {
      await expensesRepo.upsertExpense(_expense(
        id: 'e1',
        amountCents: 1299,
        description: 'Pharmacy copay',
      ));
      await pump(tester);

      await tester.tap(find.byKey(ExpensesScreen.rowKey('e1')));
      await tester.pumpAndSettle();

      // The sheet opened in edit mode with the fields seeded.
      expect(find.byKey(ExpensesScreen.createSheetKey), findsOneWidget);
      expect(find.text('Edit expense'), findsOneWidget);
      final TextField amountField =
          tester.widget<TextField>(find.byKey(ExpensesScreen.amountFieldKey));
      expect(amountField.controller!.text, '12.99');
      final TextField descField = tester
          .widget<TextField>(find.byKey(ExpensesScreen.descriptionFieldKey));
      expect(descField.controller!.text, 'Pharmacy copay');
    });

    testWidgets('editing a row updates it in place — same id, no duplicate',
        (tester) async {
      await expensesRepo.upsertExpense(_expense(
        id: 'e1',
        amountCents: 1299,
        description: 'Pharmacy copay',
      ));
      await pump(tester);

      await tester.tap(find.byKey(ExpensesScreen.rowKey('e1')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(ExpensesScreen.amountFieldKey), '20.00');
      await tester.enterText(
          find.byKey(ExpensesScreen.descriptionFieldKey), 'Pharmacy copay x2');
      await tester.tap(find.byKey(ExpensesScreen.saveButtonKey));
      await tester.pumpAndSettle();

      // Exactly one expense, same id, new amount + description.
      final List<Expense> all = await expensesRepo.listExpenses();
      expect(all, hasLength(1));
      expect(all.single.id, 'e1');
      expect(all.single.amountCents, 2000);
      expect(all.single.description, 'Pharmacy copay x2');
      // The updated row renders on the ledger.
      expect(find.byKey(ExpensesScreen.rowKey('e1')), findsOneWidget);
      expect(find.text('Pharmacy copay x2'), findsOneWidget);
    });

    testWidgets('long-press then confirm deletes the row and persists it',
        (tester) async {
      await expensesRepo.upsertExpense(_expense(id: 'e1'));
      await pump(tester);

      await tester.longPress(find.byKey(ExpensesScreen.rowKey('e1')));
      await tester.pumpAndSettle();

      // Confirm dialog appears; confirm the delete.
      expect(find.byKey(ExpensesScreen.deleteDialogKey), findsOneWidget);
      await tester.tap(find.byKey(ExpensesScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      // Gone from the ledger and from the in-memory repo.
      expect(find.byKey(ExpensesScreen.rowKey('e1')), findsNothing);
      expect(await expensesRepo.listExpenses(), isEmpty);
    });

    testWidgets('cancelling the delete keeps the row', (tester) async {
      await expensesRepo.upsertExpense(_expense(id: 'e1'));
      await pump(tester);

      await tester.longPress(find.byKey(ExpensesScreen.rowKey('e1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ExpensesScreen.deleteCancelKey));
      await tester.pumpAndSettle();

      // Still on disk after a cancelled delete.
      expect((await expensesRepo.listExpenses()).single.id, 'e1');
    });
  });
}
