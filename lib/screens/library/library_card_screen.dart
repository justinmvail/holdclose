import 'package:flutter/material.dart';

/// Library card detail — placeholder for Task 23 (BUILD_SPEC.md §5.8).
class LibraryCardScreen extends StatelessWidget {
  const LibraryCardScreen({super.key, required this.cardId});

  final String cardId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Library card')),
      body: const SizedBox.shrink(),
    );
  }
}
