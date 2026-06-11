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
        Text(
          label,
          style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
