import 'package:flutter/foundation.dart';

/// A small in-memory ring buffer of recent log lines + errors, snapshotted
/// into a bug report so the operator gets on-device context (what the app
/// was doing right before the report) — not just the screenshot + message.
///
/// Wired in `main()`: it tees `debugPrint`, `FlutterError.onError`, and the
/// platform dispatcher's uncaught-async-error hook into [add], WITHOUT
/// changing the normal console output. Capped at [maxLines] so it can never
/// grow unbounded; a multi-line entry (e.g. a stack trace) is split so one
/// trace doesn't evict everything else as a single "line".
///
/// Process-wide singleton because the capture points (debugPrint, the error
/// handlers) are global and the report sheet reads the same buffer.
class LogBuffer {
  LogBuffer._();

  /// The shared buffer the app captures into and the report sheet reads.
  static final LogBuffer instance = LogBuffer._();

  /// Hard cap on retained lines — the buffer stays bounded forever.
  static const int maxLines = 300;

  final List<String> _lines = <String>[];

  /// Append [message] (split on newlines), evicting the oldest lines once
  /// the cap is reached. Blank input is ignored.
  void add(String message) {
    if (message.isEmpty) return;
    for (final String line in message.split('\n')) {
      _lines.add(line);
    }
    final int overflow = _lines.length - maxLines;
    if (overflow > 0) _lines.removeRange(0, overflow);
  }

  /// The current buffer as plain text, oldest line first. Empty string when
  /// nothing has been captured yet.
  String snapshot() => _lines.join('\n');

  @visibleForTesting
  void clear() => _lines.clear();

  @visibleForTesting
  int get length => _lines.length;
}

/// Record a caught, non-fatal error so it leaves a trace.
///
/// The app tees [debugPrint] into [LogBuffer], which rides along with "report a
/// problem". A bare `catch (_) {}` throws that trace away — and a large share of
/// the 2026-07 bug reports ("scan isn't working", "couldn't add the
/// appointment", the gibberish voice) were slow to fix precisely because the
/// error was swallowed and had to be reproduced blind. When a failure is
/// genuinely non-fatal (the caregiver still gets a graceful result or a "try
/// again"), route the caught error through here instead of dropping it: the user
/// experience is unchanged, but the next report — and the live console — now
/// carry WHY it happened.
///
/// [where] is a short, greppable site tag ("scan.prescription", "search.npi").
/// Pass [stack] only when the site is deep enough that the tag alone won't
/// locate it; a one-line `where: error` is usually enough and keeps the buffer
/// readable.
void logNonFatal(String where, Object error, [StackTrace? stack]) {
  debugPrint('[non-fatal] $where: $error');
  if (stack != null) {
    // Just the top frames — enough to place it, without flooding the 300-line
    // buffer with a full trace.
    final List<String> frames = stack.toString().split('\n');
    debugPrint(frames.take(3).join('\n'));
  }
}
