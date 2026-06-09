import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'l10n/app_localizations.dart';
import 'models/settings.dart';
import 'providers/auth_provider.dart';
import 'providers/quiet_hours_provider.dart';
import 'providers/settings_provider.dart';
import 'routing/router.dart';
import 'services/circle_deep_link_handler.dart';
import 'theme.dart';
import 'widgets/feedback/feedback_overlay.dart';

/// Root widget. Wires MaterialApp.router to `careblazersLightTheme`
/// + `careblazersDarkTheme` with system-mode fallback.
///
/// Stateful so the GoRouter is constructed once and survives rebuilds
/// — GoRouter holds navigation state internally.
class CareblazersApp extends ConsumerStatefulWidget {
  const CareblazersApp({super.key, this.router});

  /// Optional injected router for tests. Defaults to the production
  /// `careblazersRouterProvider`, which wires the auth + onboarding
  /// redirect (BUILD_SPEC.md §5.11 + §5.12).
  final GoRouter? router;

  @override
  ConsumerState<CareblazersApp> createState() => _CareblazersAppState();
}

class _CareblazersAppState extends ConsumerState<CareblazersApp> {
  late final GoRouter _router =
      widget.router ?? ref.read(careblazersRouterProvider);

  // Care Circle invite LINKS (2026-06-08). Listens for incoming
  // `careblazers://join/<token>` deep links (cold-start + warm) and a
  // sign-in transition that replays a token stashed while signed out. All
  // fail-safe — any wiring error is swallowed so a deep-link plugin hiccup
  // can never block app launch.
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    // Wire deep links after the first frame so the router's navigator
    // exists before we try to navigate / show a SnackBar from a link.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initDeepLinks());
  }

  Future<void> _initDeepLinks() async {
    try {
      final AppLinks appLinks = AppLinks();
      // Cold start: the URI that launched the app, if any.
      final Uri? initial = await appLinks.getInitialLink();
      if (initial != null) {
        unawaited(_handleIncomingUri(initial));
      }
      // Warm: every subsequent inbound URI while the app is alive.
      _linkSub = appLinks.uriLinkStream.listen(
        (Uri uri) => unawaited(_handleIncomingUri(uri)),
        onError: (Object _) {/* never let a link error crash the app */},
      );
      // Replay a token stashed while signed out, once sign-in lands.
      _authSub = ref.read(authProvider).watchAuthState().listen(
        (AuthState state) {
          if (state is AuthStateSignedIn) {
            unawaited(_processPendingJoin());
          }
        },
        onError: (Object _) {/* never let an auth error crash the app */},
      );
    } catch (_) {
      // Deep-link wiring is additive — a failure must never affect launch.
    }
  }

  Future<void> _handleIncomingUri(Uri uri) async {
    if (!mounted) return;
    final CircleDeepLinkHandler handler =
        ref.read(circleDeepLinkHandlerProvider);
    final CircleJoinOutcome outcome = await handler.handleUri(uri.toString());
    _applyOutcome(outcome);
  }

  Future<void> _processPendingJoin() async {
    final CircleDeepLinkHandler handler =
        ref.read(circleDeepLinkHandlerProvider);
    if (!handler.hasPending) return;
    final CircleJoinOutcome? outcome = await handler.processPending();
    if (outcome != null) _applyOutcome(outcome);
  }

  /// React to a join outcome on the router's root navigator: success →
  /// go to Care Circle + "Joined <name>"; failure → friendly SnackBar.
  /// Stashed / not-a-link outcomes are silent.
  void _applyOutcome(CircleJoinOutcome outcome) {
    final BuildContext? navContext =
        _router.routerDelegate.navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    switch (outcome) {
      case CircleJoinSucceeded(:final circle):
        _router.go('/team');
        ScaffoldMessenger.of(navContext).showSnackBar(
          SnackBar(content: Text('Joined ${circle.name}.')),
        );
      case CircleJoinFailed(:final message):
        ScaffoldMessenger.of(navContext).showSnackBar(
          SnackBar(content: Text(message)),
        );
      case CircleJoinStashed():
      case CircleJoinNotALink():
        break;
    }
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FontSizeMultiplier fontSize =
        ref.watch(settingsProvider.select((AppSettings s) => s.fontSize));
    return MaterialApp.router(
      title: 'Careblazers',
      debugShowCheckedModeBanner: false,
      theme: careblazersLightTheme,
      darkTheme: careblazersDarkTheme,
      // Driven by the user's dark-mode preference via
      // `nightThemeModeProvider`: follow the phone (system) by default,
      // or always-on / always-off / scheduled per the Appearance
      // setting. Brand colors are theme-aware (`context.cb` reads the
      // active CareblazersColors extension), so both palettes render the
      // same screens correctly.
      themeMode: ref.watch(nightThemeModeProvider),
      // Localization / i18n (#18). Registers the generated
      // AppLocalizations delegate alongside the Global Material /
      // Cupertino / Widgets delegates so `AppLocalizations.of(context)`
      // resolves on every routed screen. `en` is the only shipped
      // locale today (`supportedLocales`); adding more is translation
      // work — see BUILD_SPEC.md §1. Widget/golden tests that pump a
      // screen reading `.of(context)` must register these same two
      // fields on their MaterialApp.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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
          // Alpha-testing feedback affordance. Inert (returns the child
          // verbatim) unless the build set `--dart-define=ALPHA_FEEDBACK
          // =true`, so production + tests + goldens are unaffected. Reads
          // the live route straight off the GoRouter instance.
          child: FeedbackOverlay(
            currentRoute: () =>
                _router.routerDelegate.currentConfiguration.uri.toString(),
            // The overlay is above GoRouter's Navigator, so the report
            // sheet must be hosted on the router's root navigator.
            navigatorContext: () =>
                _router.routerDelegate.navigatorKey.currentContext,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}
