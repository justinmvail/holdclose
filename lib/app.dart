import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'models/settings.dart';
import 'providers/settings_provider.dart';
import 'routing/router.dart';
import 'theme.dart';

/// Root widget. Wires MaterialApp.router to `careblazersLightTheme`
/// + `careblazersDarkTheme` with system-mode fallback.
///
/// Stateful so the GoRouter is constructed once and survives rebuilds
/// — GoRouter holds navigation state internally.
class CareblazersApp extends ConsumerStatefulWidget {
  const CareblazersApp({super.key, this.router});

  /// Optional injected router for tests. Defaults to `buildRouter()`.
  final GoRouter? router;

  @override
  ConsumerState<CareblazersApp> createState() => _CareblazersAppState();
}

class _CareblazersAppState extends ConsumerState<CareblazersApp> {
  late final GoRouter _router = widget.router ?? buildRouter();

  @override
  Widget build(BuildContext context) {
    final FontSizeMultiplier fontSize =
        ref.watch(settingsProvider.select((AppSettings s) => s.fontSize));
    return MaterialApp.router(
      title: 'Careblazers',
      debugShowCheckedModeBanner: false,
      theme: careblazersLightTheme,
      darkTheme: careblazersDarkTheme,
      themeMode: ThemeMode.system,
      routerConfig: _router,
      // BUILD_SPEC.md §11.3 — apply the user's font multiplier to every
      // routed screen by wrapping the router's child in a MediaQuery
      // whose `textScaler` reflects `state.fontSize.scale`. The settings
      // screen mutates the notifier and the change propagates here on
      // the next frame without any per-screen plumbing.
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData base = MediaQuery.of(context);
        return MediaQuery(
          data: base.copyWith(
            textScaler: TextScaler.linear(fontSize.scale),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
