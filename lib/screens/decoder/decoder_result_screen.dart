import 'package:flutter/material.dart';

/// Decoder result — placeholder for Task 14 (BUILD_SPEC.md §5.4).
class DecoderResultScreen extends StatelessWidget {
  const DecoderResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dr. Natali says')),
      body: const SizedBox.shrink(),
    );
  }
}
