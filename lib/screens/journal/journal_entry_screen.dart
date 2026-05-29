import 'package:flutter/material.dart';

/// Journal entry detail — placeholder for Task 19 (BUILD_SPEC.md §5.6).
class JournalEntryScreen extends StatelessWidget {
  const JournalEntryScreen({super.key, required this.entryId});

  final String entryId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Journal entry')),
      body: const SizedBox.shrink(),
    );
  }
}
