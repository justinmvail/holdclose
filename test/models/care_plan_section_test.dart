import 'package:careblazers/models/care_plan_section.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---- CarePlanSlot enum ------------------------------------------------

  group('CarePlanSlot', () {
    test('exposes the five spec values', () {
      expect(CarePlanSlot.values, hasLength(5));
      expect(
        CarePlanSlot.values,
        containsAll(<CarePlanSlot>[
          CarePlanSlot.morning,
          CarePlanSlot.afternoon,
          CarePlanSlot.evening,
          CarePlanSlot.night,
          CarePlanSlot.asNeeded,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final CarePlanSlot slot in CarePlanSlot.values) {
        final CarePlanSection s = CarePlanSection(
          id: 'cp-${slot.name}',
          patientId: 'mary',
          slot: slot,
          title: 'Routine',
          body: 'Do the thing.',
          order: 0,
          appliesInStage: CareStage.anyStage,
        );
        expect(s.toJson()['slot'], slot.name);
      }
    });
  });

  // ---- CareStage enum ---------------------------------------------------

  group('CareStage', () {
    test('exposes the four spec values', () {
      expect(CareStage.values, hasLength(4));
      expect(
        CareStage.values,
        containsAll(<CareStage>[
          CareStage.early,
          CareStage.middle,
          CareStage.late,
          CareStage.anyStage,
        ]),
      );
    });

    test('serialises each value to its string name on the parent model', () {
      for (final CareStage stage in CareStage.values) {
        final CarePlanSection s = CarePlanSection(
          id: 'cp-${stage.name}',
          patientId: 'mary',
          slot: CarePlanSlot.morning,
          title: 'Routine',
          body: 'Do the thing.',
          order: 0,
          appliesInStage: stage,
        );
        expect(s.toJson()['appliesInStage'], stage.name);
      }
    });
  });

  // ---- fromJson / toJson round-trip -------------------------------------

  group('CarePlanSection round-trip', () {
    test('a fully populated section survives toJson -> fromJson unchanged',
        () {
      const CarePlanSection section = CarePlanSection(
        id: 'cp-1',
        patientId: 'mary',
        slot: CarePlanSlot.evening,
        title: 'Sundowning wind-down',
        body: '- Dim the lights\n- Put on **calm** music',
        order: 2,
        appliesInStage: CareStage.middle,
      );

      final CarePlanSection restored =
          CarePlanSection.fromJson(section.toJson());

      expect(restored, equals(section));
    });

    test('markdown body round-trips verbatim', () {
      const String markdown =
          '# Morning\n\n1. Coffee\n2. Meds with breakfast\n\n_Stay patient._';
      const CarePlanSection section = CarePlanSection(
        id: 'cp-2',
        patientId: 'mary',
        slot: CarePlanSlot.morning,
        title: 'Wake up',
        body: markdown,
        order: 0,
        appliesInStage: CareStage.early,
      );

      expect(CarePlanSection.fromJson(section.toJson()).body, markdown);
    });
  });
}
