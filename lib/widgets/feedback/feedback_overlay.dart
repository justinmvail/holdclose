import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/feedback_service.dart';
import '../../theme.dart';
import 'feedback_sheet.dart';

/// Wraps the routed app content with the alpha feedback affordance: a
/// **draggable** floating "Report" button that screenshots the current
/// screen and opens [FeedbackSheet]. Testers drag it out of the way; it
/// snaps to the nearest side, dims slightly when idle, and remembers where
/// it was left (across launches) via [FeedbackButtonStore].
///
/// Inert unless enabled — when off it returns [child] verbatim (no
/// [Stack], no [RepaintBoundary], no button), so production, `flutter
/// test`, and every golden render exactly as before. [enabled] defaults to
/// [alphaFeedbackEnabled]; tests pass it explicitly to drive the on-path.
class FeedbackOverlay extends ConsumerStatefulWidget {
  const FeedbackOverlay({
    super.key,
    required this.child,
    required this.currentRoute,
    this.navigatorContext,
    bool? enabled,
    this.captureOverride,
  }) : enabled = enabled ?? alphaFeedbackEnabled;

  final Widget child;

  /// Reads the active go_router location at capture time. Injected from
  /// the app root, which holds the GoRouter directly — reliable from
  /// inside MaterialApp.router's `builder`, where InheritedGoRouter
  /// lookups are flaky.
  final String Function() currentRoute;

  /// Returns the router's **root navigator** context, used to host the
  /// modal report sheet. The overlay lives in MaterialApp.router's
  /// `builder`, which is ABOVE GoRouter's Navigator — so the overlay's own
  /// context has no Navigator to push a modal onto. The app root passes
  /// `_router.routerDelegate.navigatorKey.currentContext`. Falls back to
  /// the overlay's context when null (e.g. a `MaterialApp(home:)` test
  /// that already has a Navigator above).
  final BuildContext? Function()? navigatorContext;

  final bool enabled;

  /// Test seam: stubs the screenshot capture so widget tests don't drive
  /// the real `RenderRepaintBoundary.toImage` path (which needs the engine
  /// and `runAsync`). Null in production — the real capture runs.
  final Future<Uint8List?> Function()? captureOverride;

  /// Tap target + test handle.
  static const Key reportButtonKey = Key('alpha-feedback-report-button');

  @override
  ConsumerState<FeedbackOverlay> createState() => _FeedbackOverlayState();
}

class _FeedbackOverlayState extends ConsumerState<FeedbackOverlay> {
  final GlobalKey _repaintKey = GlobalKey();
  final GlobalKey _btnKey = GlobalKey();

  bool _capturing = false;
  bool _sheetOpen = false;

  // Resting position: a snapped horizontal edge + a vertical fraction
  // (0 = top, 1 = bottom). While the tester drags, [_dragAbs] holds the
  // live top-left and takes over; on release we snap back to an edge.
  bool _rightEdge = true;
  double _vFrac = 0.78;
  bool _dragging = false;
  Offset? _dragAbs;
  Size _buttonSize = const Size(116, 46); // estimate until measured

  static const double _margin = 12;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Flush anything queued on a previous run (laptop/shim down or the
        // tester was offline). Fire-and-forget.
        ref.read(feedbackControllerProvider).flush();
        _loadPosition();
        _measure();
      });
    }
  }

  Future<void> _loadPosition() async {
    final ({bool rightEdge, double vFrac})? saved =
        await ref.read(feedbackButtonStoreProvider).get();
    if (saved != null && mounted) {
      setState(() {
        _rightEdge = saved.rightEdge;
        _vFrac = saved.vFrac;
      });
    }
  }

  void _measure() {
    final Size? s = _btnKey.currentContext?.size;
    if (s != null && s != _buttonSize && mounted) {
      setState(() => _buttonSize = s);
    }
  }

  Future<void> _onReport() async {
    // Toggle: the button floats above the sheet's modal barrier, so it
    // stays tappable while the sheet is open. A repeat tap closes the
    // sheet instead of stacking another.
    if (_sheetOpen) {
      final BuildContext? navCtx = widget.navigatorContext?.call();
      if (navCtx != null && navCtx.mounted) {
        Navigator.of(navCtx).pop();
      } else if (mounted) {
        Navigator.of(context).pop();
      }
      return;
    }
    if (_capturing) return;
    _capturing = true;
    // Capture BEFORE the sheet opens so the sheet isn't in the shot.
    final Uint8List? shot = await (widget.captureOverride ?? _capture)();
    _capturing = false;
    if (!mounted) return;
    final String route = widget.currentRoute();
    // Host the sheet on the router's root navigator — the overlay sits
    // above GoRouter's Navigator, so its own context can't push a modal.
    final BuildContext? navCtx = widget.navigatorContext?.call();
    _sheetOpen = true;
    try {
      if (navCtx != null && navCtx.mounted) {
        await showFeedbackSheet(navCtx, route: route, screenshot: shot);
      } else if (mounted) {
        await showFeedbackSheet(context, route: route, screenshot: shot);
      }
    } finally {
      _sheetOpen = false;
    }
  }

  Future<Uint8List?> _capture() async {
    try {
      final RenderObject? ro = _repaintKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return null;
      final double dpr = MediaQuery.of(context).devicePixelRatio;
      final ui.Image image =
          await ro.toImage(pixelRatio: dpr > 2.0 ? 2.0 : dpr);
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes?.buffer.asUint8List();
    } catch (_) {
      // Never block a report on a failed capture — send it without one.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size area = Size(constraints.maxWidth, constraints.maxHeight);
        final EdgeInsets pad = MediaQuery.of(context).padding;
        final double minTop = pad.top + 8;
        final double maxTopRaw = area.height - _buttonSize.height - 8;
        final double maxTop = maxTopRaw < minTop ? minTop : maxTopRaw;

        double restingLeft() => _rightEdge
            ? area.width - _buttonSize.width - _margin
            : _margin;
        double restingTop() =>
            (_vFrac * (area.height - _buttonSize.height)).clamp(minTop, maxTop);

        final bool live = _dragging && _dragAbs != null;
        final double left = live ? _dragAbs!.dx : restingLeft();
        final double top = live ? _dragAbs!.dy : restingTop();

        return Stack(
          children: <Widget>[
            RepaintBoundary(key: _repaintKey, child: widget.child),
            Positioned(
              left: left,
              top: top,
              child: GestureDetector(
                key: FeedbackOverlay.reportButtonKey,
                behavior: HitTestBehavior.opaque,
                onTap: _onReport,
                onPanStart: (DragStartDetails _) {
                  setState(() {
                    _dragging = true;
                    _dragAbs = Offset(restingLeft(), restingTop());
                  });
                },
                onPanUpdate: (DragUpdateDetails d) {
                  setState(() {
                    final Offset base =
                        _dragAbs ?? Offset(restingLeft(), restingTop());
                    final Offset next = base + d.delta;
                    _dragAbs = Offset(
                      next.dx.clamp(
                          _margin, area.width - _buttonSize.width - _margin),
                      next.dy.clamp(minTop, maxTop),
                    );
                  });
                },
                onPanEnd: (DragEndDetails _) {
                  final Offset abs =
                      _dragAbs ?? Offset(restingLeft(), restingTop());
                  final bool right =
                      abs.dx + _buttonSize.width / 2 > area.width / 2;
                  final double denom = area.height - _buttonSize.height;
                  final double vf = denom > 0
                      ? (abs.dy / denom).clamp(0.0, 1.0)
                      : _vFrac;
                  setState(() {
                    _rightEdge = right;
                    _vFrac = vf;
                    _dragging = false;
                    _dragAbs = null;
                  });
                  ref
                      .read(feedbackButtonStoreProvider)
                      .set(rightEdge: right, vFrac: vf);
                },
                child: Opacity(
                  // Dim slightly at rest so it's less intrusive; full while
                  // the tester is moving it.
                  opacity: _dragging ? 1.0 : 0.9,
                  child: _ReportButton(measureKey: _btnKey),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReportButton extends StatelessWidget {
  const _ReportButton({required this.measureKey});

  /// Key on the painted button so the overlay can measure it for drag
  /// clamping. (The tap/drag gestures live on the parent GestureDetector.)
  final Key measureKey;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: measureKey,
      color: context.cb.cta,
      elevation: 4,
      borderRadius: BorderRadius.circular(24),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.bug_report_outlined, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text(
              'Report',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
