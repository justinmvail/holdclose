import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Word-by-word fade-in caption used by the streaming coach reply
/// (BUILD_SPEC.md §5.4) and the library card detail screen (§5.8).
///
/// Renders [text] — overridden by [stream] emissions when one is
/// supplied — with each new word fading from transparent to opaque over
/// [wordDuration]. Within a single burst of new words (e.g. several
/// tokens landing on one stream emission), fades are staggered by
/// [wordDuration] so the reveal stays paced at the per-word rate even
/// when the model emits multiple words in a single chunk.
///
/// Respects iOS Reduce Motion (BUILD_SPEC.md §11.6) — when
/// `MediaQuery.disableAnimations` or `MediaQuery.accessibleNavigation`
/// is set, the widget skips animation entirely and renders the current
/// text as a plain [Text].
class CaptionFade extends StatefulWidget {
  const CaptionFade({
    super.key,
    required this.text,
    this.stream,
    this.style,
    this.textAlign,
    this.wordDuration = const Duration(milliseconds: 120),
  });

  /// Initial text. When [stream] is null this is rendered as the final
  /// content; otherwise it's the seed the stream will overwrite as it
  /// emits accumulated partials.
  final String text;

  /// Optional stream of accumulated text. Each emission replaces the
  /// current text; only words newly appearing in the latest emission
  /// run through the fade-in animation.
  final Stream<String>? stream;

  /// Style override applied to every word. The widget modulates alpha
  /// on the resolved colour to drive the fade, so a non-null `color`
  /// here produces the most predictable result across themes.
  final TextStyle? style;

  final TextAlign? textAlign;

  /// How long each individual word takes to fade from opacity 0 → 1,
  /// and also the minimum stagger between consecutive new words landing
  /// in the same burst.
  final Duration wordDuration;

  @override
  State<CaptionFade> createState() => _CaptionFadeState();
}

class _CaptionFadeState extends State<CaptionFade>
    with SingleTickerProviderStateMixin {
  /// One token per match: an optional whitespace prefix, a run of
  /// non-whitespace, an optional whitespace suffix. Joining the tokens
  /// reproduces the input verbatim.
  static final RegExp _tokenPattern = RegExp(r'\s*\S+\s*');

  late final Ticker _ticker;
  StreamSubscription<String>? _subscription;

  // The ticker resets its `elapsed` parameter on every `start()`, so we
  // track the cumulative elapsed time across stop/start cycles ourselves
  // — `_elapsed = _elapsedBeforeRun + tickerElapsed`. This keeps a word's
  // [startedAt] timestamp meaningful even if the ticker was paused
  // between bursts.
  Duration _elapsedBeforeRun = Duration.zero;
  Duration _elapsed = Duration.zero;

  /// The earliest start time the *next* new word may take. Holds the
  /// stagger when a burst of multiple words lands simultaneously.
  Duration _nextEligibleStart = Duration.zero;

  String _currentText = '';
  List<_FadeWord> _words = const <_FadeWord>[];
  bool _reduceMotion = false;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _currentText = widget.text;
    _ticker = createTicker(_onTick);
    _subscription = widget.stream?.listen(_onStreamData);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MediaQueryData mq = MediaQuery.of(context);
    final bool next = mq.disableAnimations || mq.accessibleNavigation;
    if (!_seeded) {
      _seeded = true;
      _reduceMotion = next;
      _resyncWords(notify: false);
    } else if (next != _reduceMotion) {
      _reduceMotion = next;
      _resyncWords();
    }
  }

  @override
  void didUpdateWidget(covariant CaptionFade old) {
    super.didUpdateWidget(old);
    if (widget.stream != old.stream) {
      _subscription?.cancel();
      _subscription = widget.stream?.listen(_onStreamData);
    }
    if (widget.stream == null && widget.text != old.text) {
      _onStreamData(widget.text);
    }
  }

  void _onStreamData(String text) {
    if (!mounted) return;
    _currentText = text;
    _resyncWords();
  }

  void _resyncWords({bool notify = true}) {
    final List<String> tokens = _tokenize(_currentText);

    // Find the prefix of words whose core (whitespace-trimmed) text
    // matches what we already had. A trailing space appearing on the
    // last reused word as the next word lands is expected — preserve
    // the fade timing, but adopt the freshly tokenised string so the
    // rendered whitespace stays accurate.
    int reuseCount = 0;
    while (reuseCount < _words.length &&
        reuseCount < tokens.length &&
        _wordCore(tokens[reuseCount]) ==
            _wordCore(_words[reuseCount].text)) {
      reuseCount++;
    }

    final List<_FadeWord> next = <_FadeWord>[];
    for (int i = 0; i < reuseCount; i++) {
      next.add(_FadeWord(
        text: tokens[i],
        startedAt: _words[i].startedAt,
      ));
    }

    bool anyNew = false;
    for (int i = reuseCount; i < tokens.length; i++) {
      anyNew = true;
      final Duration startAt =
          _elapsed > _nextEligibleStart ? _elapsed : _nextEligibleStart;
      _nextEligibleStart = startAt + widget.wordDuration;
      next.add(_FadeWord(text: tokens[i], startedAt: startAt));
    }

    _words = next;

    if (_reduceMotion) {
      if (_ticker.isActive) {
        _elapsedBeforeRun = _elapsed;
        _ticker.stop();
      }
    } else if (anyNew && !_ticker.isActive) {
      _ticker.start();
    }

    if (notify) setState(() {});
  }

  void _onTick(Duration tickerElapsed) {
    final Duration nextElapsed = _elapsedBeforeRun + tickerElapsed;
    setState(() {
      _elapsed = nextElapsed;
    });
    if (_isFullyRendered()) {
      _elapsedBeforeRun = nextElapsed;
      _ticker.stop();
    }
  }

  bool _isFullyRendered() {
    for (final _FadeWord w in _words) {
      if ((_elapsed - w.startedAt) < widget.wordDuration) return false;
    }
    return true;
  }

  double _opacityFor(_FadeWord w) {
    final Duration since = _elapsed - w.startedAt;
    if (since <= Duration.zero) return 0.0;
    if (since >= widget.wordDuration) return 1.0;
    return since.inMicroseconds / widget.wordDuration.inMicroseconds;
  }

  static String _wordCore(String token) => token.trim();

  List<String> _tokenize(String text) {
    if (text.isEmpty) return const <String>[];
    return _tokenPattern
        .allMatches(text)
        .map((Match m) => m.group(0)!)
        .toList(growable: false);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion || _words.isEmpty) {
      return Text(
        _currentText,
        style: widget.style,
        textAlign: widget.textAlign,
      );
    }

    final TextStyle baseStyle =
        widget.style ?? DefaultTextStyle.of(context).style;
    final Color baseColor = baseStyle.color ?? const Color(0xFF000000);

    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          for (final _FadeWord w in _words)
            TextSpan(
              text: w.text,
              style: baseStyle.copyWith(
                color: baseColor.withValues(alpha: _opacityFor(w)),
              ),
            ),
        ],
      ),
      style: baseStyle.copyWith(color: baseColor),
      textAlign: widget.textAlign,
    );
  }
}

@immutable
class _FadeWord {
  const _FadeWord({required this.text, required this.startedAt});

  final String text;
  final Duration startedAt;
}
