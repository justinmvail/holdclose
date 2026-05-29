import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';
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
  const SignInScreen({super.key});

  static const Key appleButtonKey = Key('sign-in-apple');
  static const Key googleButtonKey = Key('sign-in-google');
  static const Key demoSkipButtonKey = Key('sign-in-demo-skip');
  static const Key termsLinkKey = Key('sign-in-terms');
  static const Key privacyLinkKey = Key('sign-in-privacy');
  static const Key errorBannerKey = Key('sign-in-error');

  /// Tagline beneath the wordmark. Mirrors page 1 of the welcome
  /// carousel so the brand voice stays consistent across the
  /// onboarding → sign-in handoff.
  static const String tagline =
      'We make caregiving for someone with dementia easier.';

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
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await flow();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't sign in. Try again.";
      });
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
    final bool showApple =
        Theme.of(context).platform == TargetPlatform.iOS;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        backgroundColor: careblazersColors.background,
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
                'Careblazers',
                style: textTheme.displayLarge?.copyWith(
                  color: careblazersColors.primary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                SignInScreen.tagline,
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
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
    return SizedBox(
      height: 52,
      child: Semantics(
        button: true,
        label: 'Continue with Apple.',
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
            'Continue with Apple',
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
    return SizedBox(
      height: 52,
      child: Semantics(
        button: true,
        label: 'Continue with Google.',
        child: OutlinedButton.icon(
          key: buttonKey,
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: careblazersColors.background,
            foregroundColor: careblazersColors.primary,
            side: BorderSide(
              color: careblazersColors.primary.withValues(alpha: 0.2),
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
                        AlwaysStoppedAnimation<Color>(careblazersColors.primary),
                  ),
                )
              : const _GoogleGlyph(),
          label: Text(
            'Continue with Google',
            style: textTheme.labelLarge?.copyWith(
              color: careblazersColors.primary,
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
        color: careblazersColors.surfaceWarm,
        shape: BoxShape.circle,
        border: Border.all(
          color: careblazersColors.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Text(
        'G',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: careblazersColors.primary,
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
    return SizedBox(
      height: 48,
      child: Semantics(
        button: true,
        label: "Skip sign-in and explore as Mary's caregiver.",
        child: TextButton(
          key: buttonKey,
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: careblazersColors.primarySoft,
          ),
          child: Text(
            "Skip — explore as Mary's caregiver",
            style: textTheme.labelLarge?.copyWith(
              color: careblazersColors.primarySoft,
            ),
          ),
        ),
      ),
    );
  }
}

class _TermsLine extends StatelessWidget {
  const _TermsLine({required this.textTheme});

  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    // TODO(decision): Terms / Privacy Policy land on a TBD screen once
    // §13.2 picks a host. Until then the inline links render as
    // tappable text that no-ops — visible commitment to the policy
    // without scaffolding a dead route.
    final TextStyle? base = textTheme.bodyMedium?.copyWith(
      color: careblazersColors.text.withValues(alpha: 0.7),
      fontSize: 13,
    );
    final TextStyle? link = base?.copyWith(
      color: careblazersColors.link,
      decoration: TextDecoration.underline,
    );
    return Text.rich(
      TextSpan(
        style: base,
        children: <InlineSpan>[
          const TextSpan(text: 'By continuing, you agree to our '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: InkWell(
              key: SignInScreen.termsLinkKey,
              onTap: () {},
              child: Text('Terms', style: link),
            ),
          ),
          const TextSpan(text: ' and '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: InkWell(
              key: SignInScreen.privacyLinkKey,
              onTap: () {},
              child: Text('Privacy Policy', style: link),
            ),
          ),
          const TextSpan(text: '.'),
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
        color: careblazersColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: careblazersColors.error.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: careblazersColors.error,
            ),
      ),
    );
  }
}
