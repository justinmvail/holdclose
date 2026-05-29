import 'package:flutter/material.dart';

/// Home tab root — placeholder for Task 11.
///
/// BUILD_SPEC.md §5.1 specifies the giant tap target, gear icon, and
/// secondary rows. Task 11 will replace this stub.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Careblazers')),
      body: const SizedBox.shrink(),
    );
  }
}
