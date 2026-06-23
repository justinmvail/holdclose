import 'package:holdclose/models/expense.dart';
import 'package:flutter_test/flutter_test.dart';

Expense _expense({
  String id = 'e1',
  int amountCents = 1299,
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
      patientId: 'demo-patient-mary',
    );

void main() {
  group('ExpenseKind', () {
    test('exposes the six spec values', () {
      expect(ExpenseKind.values, hasLength(6));
      expect(
        ExpenseKind.values,
        containsAll(<ExpenseKind>[
          ExpenseKind.meds,
          ExpenseKind.groceries,
          ExpenseKind.transport,
          ExpenseKind.equipment,
          ExpenseKind.aide,
          ExpenseKind.other,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final ExpenseKind kind in ExpenseKind.values) {
        expect(_expense(kind: kind).toJson()['kind'], kind.name);
      }
    });
  });

  group('Expense defaults', () {
    test('currency defaults to USD', () {
      final Expense e = Expense(
        id: 'e1',
        amountCents: 500,
        description: 'Bus fare',
        paidByCaregiverId: 'me',
        paidAt: DateTime.utc(2026, 6, 1),
        kind: ExpenseKind.transport,
        patientId: 'p',
      );
      expect(e.currency, 'USD');
    });

    test('receiptPath defaults to null', () {
      expect(_expense().receiptPath, isNull);
    });
  });

  group('Expense round-trip', () {
    test('a fully populated expense survives toJson -> fromJson unchanged', () {
      final Expense expense = _expense(
        amountCents: 4250,
        currency: 'EUR',
        receiptPath: '/receipts/r1.jpg',
        kind: ExpenseKind.equipment,
      );
      expect(Expense.fromJson(expense.toJson()), equals(expense));
    });

    test('the default-currency expense survives the round-trip', () {
      final Expense expense = _expense();
      final Expense restored = Expense.fromJson(expense.toJson());
      expect(restored, equals(expense));
      expect(restored.currency, 'USD');
      expect(restored.receiptPath, isNull);
    });
  });

  group('ExpenseX.monthKey', () {
    test('buckets by YYYY-MM, zero-padding the month', () {
      expect(_expense(paidAt: DateTime.utc(2026, 1, 31)).monthKey, '2026-01');
      expect(_expense(paidAt: DateTime.utc(2026, 12, 1)).monthKey, '2026-12');
      expect(_expense(paidAt: DateTime.utc(2025, 6, 15)).monthKey, '2025-06');
    });
  });
}
