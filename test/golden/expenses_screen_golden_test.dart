import 'package:alchemist/alchemist.dart';
import 'package:careblazers/models/caregiver.dart';
import 'package:careblazers/models/expense.dart';
import 'package:careblazers/providers/care_tasks_provider.dart'
    show currentCaregiverIdProvider;
import 'package:careblazers/providers/expenses_provider.dart';
import 'package:careblazers/screens/team/expenses_screen.dart';
import 'package:careblazers/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

const String _patientId = 'demo-patient-mary';
const String _me = 'demo-caregiver-me';
final DateTime _clock = DateTime.utc(2026, 6, 15, 12);

const Caregiver _maria = Caregiver(
  id: 'maria',
  displayName: 'Maria Lopez',
  role: CaregiverRole.aide,
);

Expense _expense({
  required String id,
  required int amountCents,
  required String description,
  required String paidByCaregiverId,
  required DateTime paidAt,
  required ExpenseKind kind,
  String? receiptPath,
}) =>
    Expense(
      id: id,
      amountCents: amountCents,
      description: description,
      paidByCaregiverId: paidByCaregiverId,
      paidAt: paidAt,
      kind: kind,
      receiptPath: receiptPath,
      patientId: _patientId,
    );

List<ExpenseMonthGroup> _groups() {
  final List<ExpenseRow> june = <ExpenseRow>[
    ExpenseRow(
      expense: _expense(
        id: 'j2',
        amountCents: 2500,
        description: 'Grocery run for the week',
        paidByCaregiverId: 'maria',
        paidAt: DateTime(2026, 6, 12),
        kind: ExpenseKind.groceries,
      ),
      payer: _maria,
    ),
    ExpenseRow(
      expense: _expense(
        id: 'j1',
        amountCents: 1299,
        description: 'Pharmacy copay',
        paidByCaregiverId: _me,
        paidAt: DateTime(2026, 6, 3),
        kind: ExpenseKind.meds,
        receiptPath: '/r/pharmacy.jpg',
      ),
    ),
  ];
  final List<ExpenseRow> may = <ExpenseRow>[
    ExpenseRow(
      expense: _expense(
        id: 'm1',
        amountCents: 8000,
        description: 'Adjustable bed rail',
        paidByCaregiverId: _me,
        paidAt: DateTime(2026, 5, 20),
        kind: ExpenseKind.equipment,
      ),
    ),
  ];
  return <ExpenseMonthGroup>[
    ExpenseMonthGroup(monthKey: '2026-06', totalCents: 3799, rows: june),
    ExpenseMonthGroup(monthKey: '2026-05', totalCents: 8000, rows: may),
  ];
}

Widget _host({required List<ExpenseMonthGroup> groups}) {
  return ProviderScope(
    overrides: <Override>[
      expensesViewProvider.overrideWith((Ref ref) async => groups),
      expensesClockProvider.overrideWithValue(() => _clock),
      currentCaregiverIdProvider.overrideWithValue(_me),
    ],
    child: SizedBox(
      width: 460,
      height: 900,
      child: MaterialApp(
        home: const ExpensesScreen(),
        builder: (BuildContext context, Widget? child) => ColoredBox(
          color: careblazersColors.background,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

void main() {
  group('ExpensesScreen golden', () {
    goldenTest(
      'ledger — grouped months with kind chips + payer initials',
      fileName: 'expenses_screen_ledger',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'ledger (Phase 14.33)',
            child: _host(groups: _groups()),
          ),
        ],
      ),
    );

    goldenTest(
      'empty — sticky total card over the empty state',
      fileName: 'expenses_screen_empty',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'empty (Phase 14.33)',
            child: _host(groups: <ExpenseMonthGroup>[]),
          ),
        ],
      ),
    );
  });
}
