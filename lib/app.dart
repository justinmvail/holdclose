import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'routing/router.dart';
import 'theme.dart';

/// Root widget. Wires MaterialApp.router to `careblazersLightTheme`
/// + `careblazersDarkTheme` with system-mode fallback.
///
/// Stateful so the GoRouter is constructed once and survives rebuilds
/// — GoRouter holds navigation state internally.
class CareblazersApp extends StatefulWidget {
  const CareblazersApp({super.key, this.router});

  /// Optional injected router for tests. Defaults to `buildRouter()`.
  final GoRouter? router;

  @override
  State<CareblazersApp> createState() => _CareblazersAppState();
}

class _CareblazersAppState extends State<CareblazersApp> {
  late final GoRouter _router = widget.router ?? buildRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Careblazers',
      debugShowCheckedModeBanner: false,
      theme: careblazersLightTheme,
      darkTheme: careblazersDarkTheme,
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
  }
}
