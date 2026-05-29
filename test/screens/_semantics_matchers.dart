import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// True if any [Semantics] widget in [tester]'s current tree carries an
/// explicit `properties.label` matching [pattern].
///
/// Screen tests use this to assert that an interactive widget got a
/// `Semantics(label: …)` ancestor (BUILD_SPEC.md §11.5) without
/// depending on the merged SemanticsNode tree. The
/// IconButton/Tooltip/AppBar internals absorb child semantics into a
/// parent node in ways that defeat the RenderObject-based
/// `find.bySemanticsLabel`; walking the widget tree directly is
/// stable across those merge re-orderings.
bool hasSemanticsLabel(WidgetTester tester, Pattern pattern) {
  return tester.widgetList<Semantics>(find.byType(Semantics)).any(
    (Semantics s) {
      final String? label = s.properties.label;
      if (label == null) return false;
      return pattern is RegExp
          ? pattern.hasMatch(label)
          : label.contains(pattern.toString());
    },
  );
}
