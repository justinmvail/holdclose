import 'package:flutter/material.dart';

/// Sign-in — placeholder for Task 30 (BUILD_SPEC.md §5.12).
class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: const SizedBox.shrink(),
    );
  }
}
