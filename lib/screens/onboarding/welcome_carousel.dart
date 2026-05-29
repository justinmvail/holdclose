import 'package:flutter/material.dart';

/// Welcome carousel — placeholder for Task 29 (BUILD_SPEC.md §5.11).
class WelcomeCarousel extends StatelessWidget {
  const WelcomeCarousel({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome')),
      body: const SizedBox.shrink(),
    );
  }
}
