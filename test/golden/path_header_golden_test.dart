import 'package:alchemist/alchemist.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/path_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wraps a [PathHeader] in the minimum a golden render needs: a brand-
/// background [Material] (for the InkWell tap targets) at a fixed width.
/// No theme is passed — per `flutter_test_config.dart`, goldens avoid
/// dragging google_fonts through the framework; the widget re-applies
/// its brand colors directly.
Widget _host(PathHeader header) => Container(
      width: 360,
      color: holdcloseColors.background,
      child: Material(
        color: holdcloseColors.background,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: header,
        ),
      ),
    );

void main() {
  group('PathHeader golden', () {
    goldenTest(
      'renders three-crumb feature page + single-crumb hub landing',
      fileName: 'path_header',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'three-crumb feature page',
            child: _host(const PathHeader(
              breadcrumbs: <PathHeaderCrumb>[
                PathHeaderCrumb(label: 'Home', route: '/'),
                PathHeaderCrumb(label: 'Medical', route: '/medical'),
                PathHeaderCrumb(label: 'Medications'),
              ],
              title: 'Medications',
              backLabel: 'Back to Medical',
              leadingIcon: Icons.medication_outlined,
            )),
          ),
          GoldenTestScenario(
            name: 'single-crumb hub landing',
            child: _host(const PathHeader(
              breadcrumbs: <PathHeaderCrumb>[
                PathHeaderCrumb(label: 'Medical'),
              ],
              title: 'Medical',
              backLabel: 'Back to Home',
              leadingIcon: Icons.medical_services_outlined,
            )),
          ),
        ],
      ),
    );
  });
}
