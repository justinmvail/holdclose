import 'package:alchemist/alchemist.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/emergency_card_pin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `theme.dart`'s private `_darkSurface` — the scaffold color the
/// Home dashboard paints in dark mode. Duplicated here (the token is
/// private to the theme) so the dark scenario renders the card on the
/// same field a real device would.
const Color _darkSurface = Color(0xFF0F1422);

/// Hosts a single [EmergencyCardPin] at a phone width on [background], in
/// a [Material] so the InkWell has an ancestor. No `theme:` is passed —
/// per `flutter_test_config.dart` goldens avoid dragging google_fonts
/// through the framework; the card pulls its brand colors directly, and
/// its orange gradient is identical in light and dark.
Widget _host(Color background) => Container(
      width: 390,
      color: background,
      child: Material(
        color: background,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: EmergencyCardPin(),
        ),
      ),
    );

void main() {
  group('EmergencyCardPin golden', () {
    goldenTest(
      'renders the pinned emergency card on light and dark fields',
      fileName: 'emergency_card_pin',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'light',
            child: _host(careblazersColors.surfaceWarm),
          ),
          GoldenTestScenario(
            name: 'dark',
            child: _host(_darkSurface),
          ),
        ],
      ),
    );
  });
}
