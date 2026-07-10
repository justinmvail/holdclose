import 'package:flutter/material.dart';

/// A bold word label sitting 4px above its form input — the standard
/// "label over field" unit the form screens share (appointment +
/// medication forms; previously a per-screen `_LabelledField` copy).
class LabelledField extends StatelessWidget {
  const LabelledField({super.key, required this.label, required this.child});

  /// Word label rendered `bodyMedium` w700 above the input.
  final String label;

  /// The input itself (text field, picker button, chip row, …).
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // The label is a sibling `Text` above a bare field, so once the
        // caregiver types a value a screen reader announces only the typed
        // text — an AT user can't tell "Dosage" from "Frequency". Attach
        // the label to the FIELD's semantics (so it's spoken with the
        // field on focus) and hide the visual Text from AT to avoid a
        // double read. Visuals are unchanged — Semantics/ExcludeSemantics
        // add no layout. (UIUX_REVIEW: one change fixes ~34 form fields.)
        ExcludeSemantics(
          child: Text(
            label,
            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 4),
        Semantics(label: label, child: child),
      ],
    );
  }
}
