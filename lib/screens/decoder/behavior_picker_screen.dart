import 'package:flutter/material.dart';

/// Behavior picker — placeholder for Task 12 (BUILD_SPEC.md §5.2).
class BehaviorPickerScreen extends StatelessWidget {
  const BehaviorPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('What\'s happening?')),
      body: const SizedBox.shrink(),
    );
  }
}
