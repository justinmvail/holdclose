import 'package:alchemist/alchemist.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/add_action_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hosts a widget at a phone width on the warm-white field, inside a
/// [ProviderScope] (the rows' [VoiceButton]s read the voice-capture seam)
/// + a [Material] ancestor. No `theme:` — per `flutter_test_config.dart`
/// goldens avoid dragging google_fonts through the framework; the sheet
/// pulls its brand colors directly off `careblazersColors`.
Widget _host(Widget child) => ProviderScope(
      child: Container(
        width: 390,
        color: careblazersColors.background,
        child: Material(color: careblazersColors.background, child: child),
      ),
    );

void main() {
  group('Add sheet golden', () {
    goldenTest(
      'renders the FAB and the four-row Add sheet',
      fileName: 'add_action_sheet',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(
            name: 'fab',
            child: _host(
              const Padding(
                padding: EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: AddActionFab(),
                ),
              ),
            ),
          ),
          GoldenTestScenario(
            name: 'sheet',
            child: _host(const AddActionSheet()),
          ),
        ],
      ),
    );
  });
}
