import 'package:flutter/material.dart';

/// Journal tab root — placeholder for Task 17 (BUILD_SPEC.md §5.5).
class JournalScreen extends StatelessWidget {
  const JournalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Journal')),
      body: const SizedBox.shrink(),
    );
  }
}
