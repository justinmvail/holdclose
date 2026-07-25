import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/link_launcher_provider.dart';
import '../../providers/loved_one_lookup_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/settings_provider.dart' show demoModeEnabled;
import '../../theme.dart';

/// Sign-in (BUILD_SPEC.md §5.12).
///
/// Two OAuth buttons (Apple iOS-only, Google both platforms) plus a
/// DEMO_MODE-only "Skip — explore as Mary's caregiver" affordance that
/// the pitch demo uses to land straight on Home without touching a
/// system OAuth sheet.
///
/// Routing on success is driven by a subscription to
/// [AuthProvider.watchAuthState] — the moment the state machine flips
/// to [AuthStateSignedIn], we `context.go('/')`. The OAuth sheet
/// throwing or being cancelled settles the machine back to signedOut
/// without leaving the screen, so the caregiver can retry.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, bool? alphaMode, bool? showGoogleInAlpha})
      : alphaMode = alphaMode ?? alphaAuthEnabled,
        showGoogleInAlpha = showGoogleInAlpha ?? googleSignInConfigured;

  /// Alpha-tester mode: Google-ONLY (user decision). Shows just the
  /// "Continue with Google" button so every tester becomes a real,
  /// backend-verified account. There is no local "just start" bypass.
  /// Defaults to the `ALPHA_AUTH` build flag; tests pass it explicitly.
  final bool alphaMode;

  /// Whether the alpha build baked in a Google Web client id. Defaults to
  /// [googleSignInConfigured] (true only when the build set a
  /// `GOOGLE_SERVER_CLIENT_ID`); tests pass it explicitly. When false there
  /// is NO bypass — the screen shows a calm "sign-in isn't available"
  /// message instead (no actionable fallback).
  final bool showGoogleInAlpha;

  static const Key appleButtonKey = Key('sign-in-apple');
  static const Key googleButtonKey = Key('sign-in-google');
  static const Key alphaGoogleButtonKey = Key('sign-in-alpha-google');
  static const Key alphaUnavailableKey = Key('sign-in-alpha-unavailable');
  static const Key demoSkipButtonKey = Key('sign-in-demo-skip');
  static const Key termsLinkKey = Key('sign-in-terms');
  static const Key privacyLinkKey = Key('sign-in-privacy');
  static const Key errorBannerKey = Key('sign-in-error');
  static const Key reassuranceKey = Key('sign-in-reassurance');

  /// Tagline beneath the wordmark. Mirrors page 1 of the welcome
  /// carousel so the brand voice stays consistent across the
  /// onboarding → sign-in handoff.
  ///
  /// The rendered string is sourced from `AppLocalizations.signInTagline`
  /// (#18 localization); this const is kept as the English reference the
  /// screen test asserts the rendered text against — the two must stay in
  /// sync with the ARB entry.
  static const String tagline =
      'We make caring for someone you love a little easier.';

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  StreamSubscription<AuthState>? _sub;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final AuthProvider auth = ref.read(authProvider);
    _sub = auth.watchAuthState().listen((AuthState state) {
      if (!mounted) return;
      if (state is AuthStateSignedIn) {
        // A successful sign-in is what completes onboarding now — the
        // carousel's "Skip" deliberately no longer does (UIUX_REVIEW), and
        // a caregiver reaching sign-in via Skip could otherwise be bounced
        // back to `/onboarding` from `/` because the flag never flipped.
        ref.read(onboardingCompletedProvider.notifier).complete();
        context.go('/');
        return;
      }
      if (state is AuthStateSignedOut && _busy) {
        setState(() => _busy = false);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _runFlow(Future<void> Function() flow) async {
    // Capture the localized failure message before the await — reading
    // AppLocalizations.of(context) after an async gap risks a disposed
    // context. The message is only consumed in the catch branch.
    final String failureMessage = AppLocalizations.of(context).signInError;
    // Capture the notifier up front so the `finally` can release the gate
    // even if the redirect tears this screen down first (it's keepAlive).
    final LovedOneLookup lookup = ref.read(lovedOneLookupProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    // Engage the loved-one gate BEFORE the OAuth round-trip, so the router
    // holds on this screen (not the setup wizard) the instant auth flips to
    // signed-in. After sign-in, adopt any loved one the account ALREADY
    // owns off the backend before the gate decides — otherwise a returning
    // caregiver is forced to re-create their person, and sync then shadows
    // it with their original as the active one (fb 2026-06-13). `adopt()`
    // is fail-safe + bounded, so it never blocks a successful sign-in.
    lookup.begin();
    try {
      await flow();
      await lookup.adopt();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failureMessage;
      });
    } finally {
      lookup.end();
    }
  }

  void _onApplePressed() {
    final AuthProvider auth = ref.read(authProvider);
    _runFlow(auth.signInWithApple);
  }

  void _onGooglePressed() {
    final AuthProvider auth = ref.read(authProvider);
    _runFlow(auth.signInWithGoogle);
  }

  /// Alpha "Continue with Google": run the REAL Google sign-in →
  /// backend-verify round-trip. Cancellation settles back to signedOut
  /// (no error); a failure surfaces the error banner.
  void _onAlphaGooglePressed() {
    final AuthProvider auth = ref.read(authProvider);
    _runFlow(auth.signInWithGoogle);
  }

  void _onDemoSkipPressed() {
    // In DEMO_MODE the riverpod selector resolves [authProvider] to
    // [FakeAuthProvider]; either sign-in method flips it to signedIn
    // with the canned Sarah Henderson user (BUILD_SPEC.md §6.4 + §9.1).
    final AuthProvider auth = ref.read(authProvider);
    _runFlow(auth.signInWithGoogle);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool showApple =
        Theme.of(context).platform == TargetPlatform.iOS;

    return Scaffold(
      backgroundColor: context.hc.background,
      appBar: AppBar(
        backgroundColor: context.hc.background,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Spacer(),
              Text(
                l10n.signInTitle,
                style: textTheme.displayLarge?.copyWith(
                  color: context.hc.primary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.signInTagline,
                style: textTheme.bodyLarge?.copyWith(
                  color: context.hc.text,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              if (_error != null) ...<Widget>[
                _ErrorBanner(
                  key: SignInScreen.errorBannerKey,
                  message: _error!,
                ),
                const SizedBox(height: 16),
              ],
              // Plain-language reassurance at the moment trust matters most:
              // the caregiver is about to hand over their identity and then
              // enter their loved one's PHI. Say why sign-in is needed and
              // that the data stays private — the vendor stays invisible per
              // the brand rule (no "Google"/model names in the copy).
              Text(
                l10n.signInReassurance,
                key: SignInScreen.reassuranceKey,
                style: textTheme.bodyMedium?.copyWith(
                  color: context.hc.primarySoft,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (widget.alphaMode) ...<Widget>[
                if (widget.showGoogleInAlpha) ...<Widget>[
                  // Google-ONLY: REAL Google sign-in, verified by the
                  // backend — a real account that survives reinstall.
                  // There is no local "just start" bypass.
                  _GoogleButton(
                    buttonKey: SignInScreen.alphaGoogleButtonKey,
                    busy: _busy,
                    onPressed: _busy ? null : _onAlphaGooglePressed,
                  ),
                  const SizedBox(height: 16),
                  _TermsLine(textTheme: textTheme),
                ] else ...<Widget>[
                  // Google isn't configured in this build. There is NO
                  // bypass — show a calm message, not an actionable
                  // fallback (the local "just start" path was removed).
                  Text(
                    key: SignInScreen.alphaUnavailableKey,
                    "Sign-in isn't available in this build.",
                    style: textTheme.bodyLarge?.copyWith(
                      color: context.hc.text.withValues(alpha: 0.7),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ] else ...<Widget>[
                if (showApple) ...<Widget>[
                  _AppleButton(
                    buttonKey: SignInScreen.appleButtonKey,
                    busy: _busy,
                    onPressed: _busy ? null : _onApplePressed,
                  ),
                  const SizedBox(height: 12),
                ],
                _GoogleButton(
                  buttonKey: SignInScreen.googleButtonKey,
                  busy: _busy,
                  onPressed: _busy ? null : _onGooglePressed,
                ),
                const SizedBox(height: 16),
                _TermsLine(textTheme: textTheme),
                if (demoModeEnabled) ...<Widget>[
                  const SizedBox(height: 20),
                  _DemoSkipButton(
                    buttonKey: SignInScreen.demoSkipButtonKey,
                    onPressed: _busy ? null : _onDemoSkipPressed,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AppleButton extends StatelessWidget {
  const _AppleButton({
    required this.buttonKey,
    required this.busy,
    required this.onPressed,
  });

  final Key buttonKey;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AppLocalizations l10n = AppLocalizations.of(context);
    return SizedBox(
      height: 52,
      child: Semantics(
        button: true,
        label: l10n.signInContinueWithAppleSemantics,
        child: FilledButton.icon(
          key: buttonKey,
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.black.withValues(alpha: 0.6),
            disabledForegroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Icon(Icons.apple, size: 22),
          label: Text(
            l10n.signInContinueWithApple,
            style: textTheme.labelLarge?.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({
    required this.buttonKey,
    required this.busy,
    required this.onPressed,
  });

  final Key buttonKey;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AppLocalizations l10n = AppLocalizations.of(context);
    return SizedBox(
      height: 52,
      child: Semantics(
        button: true,
        label: l10n.signInContinueWithGoogleSemantics,
        child: OutlinedButton.icon(
          key: buttonKey,
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: context.hc.background,
            foregroundColor: context.hc.primary,
            side: BorderSide(
              color: context.hc.primary.withValues(alpha: 0.2),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(context.hc.primary),
                  ),
                )
              : const _GoogleGlyph(),
          label: Text(
            l10n.signInContinueWithGoogle,
            style: textTheme.labelLarge?.copyWith(
              color: context.hc.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimal "G" glyph used in lieu of the Google-branded mark. Avoids
/// shipping the Google logo asset (which carries brand-usage rules we
/// don't want to negotiate in v1) while still giving the button a
/// visual anchor distinct from a plain text label.
class _GoogleGlyph extends StatelessWidget {
  const _GoogleGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.hc.surfaceWarm,
        shape: BoxShape.circle,
        border: Border.all(
          color: context.hc.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Text(
        'G',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: context.hc.primary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _DemoSkipButton extends StatelessWidget {
  const _DemoSkipButton({
    required this.buttonKey,
    required this.onPressed,
  });

  final Key buttonKey;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AppLocalizations l10n = AppLocalizations.of(context);
    return SizedBox(
      height: 48,
      child: Semantics(
        button: true,
        label: l10n.signInDemoSkipSemantics,
        child: TextButton(
          key: buttonKey,
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: context.hc.primarySoft,
          ),
          child: Text(
            l10n.signInDemoSkip,
            style: textTheme.labelLarge?.copyWith(
              color: context.hc.primarySoft,
            ),
          ),
        ),
      ),
    );
  }
}

class _TermsLine extends ConsumerWidget {
  const _TermsLine({required this.textTheme});

  final TextTheme textTheme;

  // The canonical Terms + Privacy pages live on the Juno Code Studio site
  // (junocode.studio/holdclose), deployed via Cloudflare Pages.
  static final Uri _termsUrl =
      Uri.parse('https://junocode.studio/holdclose/terms');
  static final Uri _privacyUrl =
      Uri.parse('https://junocode.studio/holdclose/privacy');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TextStyle? base = textTheme.bodyMedium?.copyWith(
      color: context.hc.text.withValues(alpha: 0.7),
      fontSize: 13,
    );
    final TextStyle? link = base?.copyWith(
      color: context.hc.link,
      decoration: TextDecoration.underline,
    );
    return Text.rich(
      TextSpan(
        style: base,
        children: <InlineSpan>[
          TextSpan(text: l10n.signInTermsPrefix),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: InkWell(
              key: SignInScreen.termsLinkKey,
              onTap: () => ref.read(linkLauncherProvider).launch(_termsUrl),
              child: Text(l10n.signInTermsLink, style: link),
            ),
          ),
          TextSpan(text: l10n.signInTermsConjunction),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: InkWell(
              key: SignInScreen.privacyLinkKey,
              onTap: () => ref.read(linkLauncherProvider).launch(_privacyUrl),
              child: Text(l10n.signInPrivacyLink, style: link),
            ),
          ),
          TextSpan(text: l10n.signInTermsSuffix),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.hc.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: context.hc.error.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.hc.error,
            ),
      ),
    );
  }
}
