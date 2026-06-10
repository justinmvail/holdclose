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
