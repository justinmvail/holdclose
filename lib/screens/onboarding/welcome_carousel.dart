import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme.dart';

/// Three-page welcome carousel (BUILD_SPEC.md §5.11).
///
/// Each page renders the verbatim copy locked in §5.11 — the strings
/// are exposed as a const list on [WelcomeCarousel.pages] so screen
/// tests assert against the same source the widget reads.
///
/// Both the top-right "Skip" and the bottom CTA hand off to `/sign-in`.
/// On page 3 the CTA reads "Get started" and additionally flips
/// [onboardingCompletedProvider] true so task 31's router redirect
/// stops bouncing the caregiver back here on the next launch.
class WelcomeCarousel extends ConsumerStatefulWidget {
  const WelcomeCarousel({super.key});

  /// Widget keys for tests. Tests address by key (not by visible copy)
  /// so a wording edit doesn't ripple into a test rewrite.
  static const Key pageViewKey = Key('welcome-carousel-pageview');
  static const Key skipButtonKey = Key('welcome-carousel-skip');
  static const Key primaryCtaKey = Key('welcome-carousel-cta');
  static const Key dotIndicatorKey = Key('welcome-carousel-dots');

  /// The three pages' copy, locked verbatim against BUILD_SPEC.md
  /// §5.11. Exposed so screen tests compare against the same source.
  static const List<WelcomeCarouselPage> pages = <WelcomeCarouselPage>[
    WelcomeCarouselPage(
      glyph: 'H',
      title: 'Holdclose',
      body: 'We make caring for someone you love a little easier.',
    ),
    WelcomeCarouselPage(
      glyph: '📱',
      title: 'Your pocket coach for the hard moments.',
      body:
          'When the day turns hard, when you don\'t know what to say, '
          'when you just need someone who gets it — a coach who knows '
          'your loved one\'s situation, any hour.',
    ),
    WelcomeCarouselPage(
      glyph: '📔',
      title: 'A journal that travels with you.',
      body:
          'Jot down the moments that matter, in your own words. Bring '
          "the real picture to your next doctor visit — not the 'showtime' "
          'one your loved one performs in the exam room.',
    ),
  ];

  @override
  ConsumerState<WelcomeCarousel> createState() => _WelcomeCarouselState();
}

class _WelcomeCarouselState extends ConsumerState<WelcomeCarousel> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLastPage => _page == WelcomeCarousel.pages.length - 1;

  void _onCtaPressed() {
    if (_isLastPage) {
      ref.read(onboardingCompletedProvider.notifier).complete();
      context.go('/sign-in');
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  void _onSkipPressed() {
    // Both Skip and "Get started" mark onboarding done so the task 31
    // router redirect (BUILD_SPEC.md §5.11) lets `/sign-in` through —
    // without the flip, the strict "onboarding incomplete → /onboarding"
    // gate would bounce Skip's `context.go('/sign-in')` back to the
    // carousel. Skip = "I've seen enough of the intro, take me to the
    // app."
    ref.read(onboardingCompletedProvider.notifier).complete();
    context.go('/sign-in');
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: context.hc.background,
      appBar: AppBar(
        backgroundColor: context.hc.background,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Semantics(
              button: true,
              label: l10n.welcomeSkipSemantics,
              child: TextButton(
                key: WelcomeCarousel.skipButtonKey,
                onPressed: _onSkipPressed,
                child: Text(
                  l10n.commonSkip,
                  style: textTheme.labelLarge?.copyWith(
                    color: context.hc.primarySoft,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: PageView.builder(
                key: WelcomeCarousel.pageViewKey,
                controller: _controller,
                itemCount: WelcomeCarousel.pages.length,
                onPageChanged: (int index) => setState(() => _page = index),
                itemBuilder: (BuildContext context, int index) {
                  return _PageBody(page: WelcomeCarousel.pages[index]);
                },
              ),
            ),
            _DotIndicator(
              key: WelcomeCarousel.dotIndicatorKey,
              count: WelcomeCarousel.pages.length,
              active: _page,
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: WelcomeCarousel.primaryCtaKey,
                  onPressed: _onCtaPressed,
                  style: FilledButton.styleFrom(
                    backgroundColor: context.hc.ctaFilled,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: Text(
                    _isLastPage
                        ? l10n.welcomeGetStartedCta
                        : l10n.welcomeNextCta,
                    style: textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageBody extends StatelessWidget {
  const _PageBody({required this.page});

  final WelcomeCarouselPage page;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // Page 1 ('H' glyph) renders the brand "Hc" split mark —
          // navy left / white "H", white right / navy "c" — matching
          // the AppIcon + LaunchImage. Pages 2 & 3 keep their emoji
          // glyphs in a plain navy block since they're feature
          // illustrations, not brand marks. Centralizing the mark here
          // means future icon updates only need a Flutter-side change
          // here PLUS the PNG regen for AppIcon / LaunchImage
          // (tools: scratchpad gen_brand_assets.py recipe — Montserrat
          // 700 at 0.6× the canvas, letters layout-centered per half).
          if (page.glyph == 'H')
            const _HcBrandMark()
          else
            Container(
              width: 120,
              height: 120,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.hc.primary,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Text(
                page.glyph,
                style: textTheme.displayLarge?.copyWith(
                  color: Colors.white,
                  fontSize: 56,
                ),
              ),
            ),
          const SizedBox(height: 32),
          Text(
            page.title,
            style: textTheme.headlineLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            page.body,
            style: textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _DotIndicator extends StatelessWidget {
  const _DotIndicator({
    super.key,
    required this.count,
    required this.active,
  });

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (int i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: i == active ? 24 : 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              // Navy active dot, dimmed navy for inactive. Orange is
              // reserved for the CTA button below — using it here
              // doubled the orange surface area on the carousel.
              color: i == active
                  ? context.hc.primary
                  : context.hc.primarySoft.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

/// One page in the welcome carousel — glyph + title + body. Top-level
/// so the screen test asserts against the same const list the widget
/// reads. Fields map 1:1 onto BUILD_SPEC.md §5.11's locked copy;
/// changes here are spec changes.
@immutable
class WelcomeCarouselPage {
  const WelcomeCarouselPage({
    required this.glyph,
    required this.title,
    required this.body,
  });

  final String glyph;
  final String title;
  final String body;
}

/// The brand "Hc" split mark: navy left / white capital H, white
/// right / navy lowercase c. Same design as the iOS AppIcon and
/// LaunchImage so onboarding page 1 matches the icon the user tapped
/// to launch the app. Sized at 120×120 to drop into the carousel's
/// logo slot.
///
/// Letter glyphs use the same Montserrat 700 the type ramp + the
/// LaunchImage master use (BUILD_SPEC.md §3.2 + §3.4).
class _HcBrandMark extends StatelessWidget {
  const _HcBrandMark();

  @override
  Widget build(BuildContext context) {
    final TextStyle letter = Theme.of(context).textTheme.displayLarge!.copyWith(
          fontSize: 72,
          fontWeight: FontWeight.w700,
          height: 1.0,
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        width: 120,
        height: 120,
        child: Row(
          children: <Widget>[
            Expanded(
              child: ColoredBox(
                color: context.hc.primary,
                child: Center(
                  child: Text(
                    'H',
                    style: letter.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: context.hc.background,
                child: Center(
                  child: Text(
                    'c',
                    style: letter.copyWith(color: context.hc.primary),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
