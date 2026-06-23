import 'package:alchemist/alchemist.dart';
import 'package:holdclose/theme.dart';
import 'package:holdclose/widgets/holdclose_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _noop(bool _) {}

/// Preview of [HoldcloseSwitch] (fb 2026-06-14 — clearer on/off toggles):
/// the two standalone states up top, then two settings rows showing it in
/// context.
Widget _preview() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Material(
      color: holdcloseColors.surfaceWarm,
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
                  HoldcloseSwitch(value: false, onChanged: _noop),
                  SizedBox(width: 24),
                  HoldcloseSwitch(value: true, onChanged: _noop),
                ],
              ),
              const SizedBox(height: 22),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: holdcloseColors.background,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: const <Widget>[
                    HoldcloseSwitchListTile(
                      value: true,
                      onChanged: _noop,
                      title: Text('Read scripts aloud'),
                      subtitle: Text('Hear each coaching script spoken.'),
                    ),
                    HoldcloseSwitchListTile(
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
  group('HoldcloseSwitch golden', () {
    goldenTest(
      'on/off states + in settings rows',
      fileName: 'holdclose_switch',
      builder: () => GoldenTestGroup(
        columns: 1,
        children: <Widget>[
          GoldenTestScenario(name: 'toggle + rows', child: _preview()),
        ],
      ),
    );
  });
}
