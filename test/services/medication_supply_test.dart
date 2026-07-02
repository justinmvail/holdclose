import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/models/medication.dart';
import 'package:holdclose/services/medication_supply.dart';

/// Unit coverage for the refill-runway calculator — pure arithmetic on the
/// captured label fields, degrading to [SupplyStatus.unknown] rather than
/// guessing. Never medical advice.
Medication _med({String? quantity, String? refills, String? dateFilled}) =>
    Medication(
      id: 'm',
      name: 'Tizanidine',
      dosage: '2 mg',
      route: MedicationRoute.oral,
      quantity: quantity,
      refills: refills,
      dateFilled: dateFilled,
    );

void main() {
  group('parseUsLabelDate', () {
    test('parses M/D/YY, M/D/YYYY, and M-D-YY', () {
      expect(parseUsLabelDate('12/3/21'), DateTime(2021, 12, 3));
      expect(parseUsLabelDate('12/03/2021'), DateTime(2021, 12, 3));
      expect(parseUsLabelDate('1-5-26'), DateTime(2026, 1, 5));
    });

    test('extracts a date embedded in text', () {
      expect(parseUsLabelDate('Filled 12/3/21 at CVS'), DateTime(2021, 12, 3));
    });

    test('null on garbage, impossible dates, and rollovers', () {
      expect(parseUsLabelDate(null), isNull);
      expect(parseUsLabelDate('no date'), isNull);
      expect(parseUsLabelDate('13/40/21'), isNull);
      expect(parseUsLabelDate('2/30/22'), isNull); // would roll to March
    });
  });

  group('computeMedicationSupply', () {
    test('days of supply = quantity ÷ doses per day; parses refills', () {
      final MedicationSupply s = computeMedicationSupply(
        _med(quantity: '180', refills: '3 by 5/27/22', dateFilled: '12/15/25'),
        scheduledDosesPerDay: 2,
        now: DateTime(2026, 1, 1),
      );
      expect(s.daysOfSupply, 90);
      expect(s.refillsRemaining, 3);
      expect(s.runOutDate, DateTime(2025, 12, 15).add(const Duration(days: 90)));
      expect(s.status, SupplyStatus.ok);
    });

    test('flags refillSoon when the run-out date is within the window', () {
      // 180 ÷ 2 = 90 days from 12/15/25 → runs out ~3/15/26.
      final MedicationSupply s = computeMedicationSupply(
        _med(quantity: '180', refills: '3', dateFilled: '12/15/25'),
        scheduledDosesPerDay: 2,
        now: DateTime(2026, 3, 10),
      );
      expect(s.status, SupplyStatus.refillSoon);
      expect(s.needsAttention, isTrue);
    });

    test('outOfRefills when refills is zero, regardless of supply', () {
      final MedicationSupply s = computeMedicationSupply(
        _med(quantity: '30', refills: '0', dateFilled: '1/1/26'),
        scheduledDosesPerDay: 1,
        now: DateTime(2026, 1, 2),
      );
      expect(s.status, SupplyStatus.outOfRefills);
      expect(s.needsAttention, isTrue);
    });

    test('as-needed (0 doses/day) leaves days/run-out null but keeps refills',
        () {
      final MedicationSupply s = computeMedicationSupply(
        _med(quantity: '30', refills: '2'),
        scheduledDosesPerDay: 0,
        now: DateTime(2026, 1, 1),
      );
      expect(s.daysOfSupply, isNull);
      expect(s.runOutDate, isNull);
      expect(s.refillsRemaining, 2);
      expect(s.status, SupplyStatus.ok);
    });

    test('unknown when there is nothing to compute from', () {
      final MedicationSupply s = computeMedicationSupply(
        _med(),
        scheduledDosesPerDay: 2,
        now: DateTime(2026, 1, 1),
      );
      expect(s.status, SupplyStatus.unknown);
      expect(s.needsAttention, isFalse);
    });

    test('unreadable refills (PRN) parse to null but supply still computes',
        () {
      final MedicationSupply s = computeMedicationSupply(
        _med(quantity: '60', refills: 'PRN', dateFilled: '12/15/25'),
        scheduledDosesPerDay: 1,
        now: DateTime(2026, 1, 1),
      );
      expect(s.refillsRemaining, isNull);
      expect(s.daysOfSupply, 60);
      expect(s.status, SupplyStatus.ok);
    });
  });
}
