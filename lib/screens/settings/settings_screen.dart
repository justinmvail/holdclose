import 'package:flutter/material.dart';

/// Settings — placeholder for Task 25 (BUILD_SPEC.md §5.10).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const SizedBox.shrink(),
    );
  }
}
