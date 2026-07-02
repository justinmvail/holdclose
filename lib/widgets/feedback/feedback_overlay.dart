import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/feedback_service.dart';
import 'feedback_sheet.dart';

/// Headless host for the alpha feedback flow. It no longer paints a button
/// of its own — the report affordance lives in the top-right of every
/// [PathHeader]. This widget just (a) wraps the routed content in a
/// `RepaintBoundary` so the current screen can be screenshotted, and (b)
/// listens for [feedbackTriggerProvider] (fired by that header button) to
/// run the capture + open [FeedbackSheet] (which also attaches a log
/// snapshot).
///
/// Inert unless enabled — when off it returns [child] verbatim (no
/// [RepaintBoundary], no listener), so production, `flutter test`, and
/// every golden render exactly as before. [enabled] defaults to
/// [feedbackUiEnabled]; tests pass it explicitly to drive the on-path.
class FeedbackOverlay extends ConsumerStatefulWidget {
  const FeedbackOverlay({
    super.key,
    required this.child,
    required this.currentRoute,
    this.navigatorContext,
    bool? enabled,
    this.captureOverride,
  }) : enabled = enabled ?? feedbackUiEnabled;

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

  @override
  ConsumerState<FeedbackOverlay> createState() => _FeedbackOverlayState();
}

class _FeedbackOverlayState extends ConsumerState<FeedbackOverlay> {
  final GlobalKey _repaintKey = GlobalKey();

  bool _capturing = false;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Flush anything queued on a previous run (laptop/shim down or the
        // tester was offline). Fire-and-forget.
        ref.read(feedbackControllerProvider).flush();
      });
    }
  }

  Future<void> _onReport() async {
    // Toggle: the tab floats above the sheet's modal barrier, so it stays
    // tappable while the sheet is open. A repeat tap closes the sheet
    // instead of stacking another.
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
    // The header's report button fires this; capture the screen + open the
    // sheet. (listen never fires on first build, only on a real change.)
    ref.listen<int>(feedbackTriggerProvider, (int? _, int __) => _onReport());
    // RepaintBoundary so the current screen can be screenshotted on report.
    return RepaintBoundary(key: _repaintKey, child: widget.child);
  }
}
