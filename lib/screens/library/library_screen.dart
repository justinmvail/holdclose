import 'package:flutter/material.dart';

/// Library tab root — placeholder for Task 22 (BUILD_SPEC.md §5.7).
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: const SizedBox.shrink(),
    );
  }
}
