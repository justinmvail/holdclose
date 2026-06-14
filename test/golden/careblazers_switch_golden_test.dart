import 'package:alchemist/alchemist.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/careblazers_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _noop(bool _) {}

/// Preview of [CareblazersSwitch] (fb 2026-06-14 — clearer on/off toggles):
/// the two standalone states up top, then two settings rows showing it in
/// context.
Widget _preview() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Material(
      color: careblazersColors.surfaceWarm,
      child: SizedBox(
        width: 440,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: const <Widget>[
                  CareblazersSwitch(value: false, onChanged: _noop),
                  SizedBox(width: 24),
                  CareblazersSwitch(value: true, onChanged: _noop),
                ],
              ),
              const SizedBox(height: 22),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: careblazersColors.background,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: const <Widget>[
                    CareblazersSwitchListTile(
                      value: true,
                      onChanged: _noop,
                      title: Text('Read scripts aloud'),
                      subtitle: Text('Hear each coaching script spoken.'),
                    ),
                    CareblazersSwitchListTile(
                      value: false,
                      onChanged: _noop,
                      title: Text('Quiet hours'),
                      subtitle: Text('Mute audio during set hours.'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('CareblazersSwitch golden', () {
    goldenTest(
      'on/off states + in settings rows',
      fileName: 'careblazers_switch',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(name: 'toggle + rows', child: _preview()),
        ],
      ),
    );
  });
}
