import 'package:flutter/material.dart';

/// Crisis card tab root — placeholder for Task 24 (BUILD_SPEC.md §5.9).
class CrisisCardScreen extends StatelessWidget {
  const CrisisCardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hospital handoff card')),
      body: const SizedBox.shrink(),
    );
  }
}
