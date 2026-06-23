import 'dart:async';

import 'package:holdclose/services/sync_sink.dart';
import 'package:flutter_test/flutter_test.dart';

class _Host with SyncSinkHost {}

/// The applyingRemote echo guard is ZONE-scoped (2026-06-11). The old
/// instance-bool guard had a real data-loss window: while a pull was
/// applying a remote doc (awaiting DB writes inside applyingRemote), a
/// user save to the same repository could interleave on the event loop,
/// see the flag up, and silently skip its enqueue — the local edit then
/// never reached the circle until the row was edited again.
void main() {
  test('a write INSIDE applyingRemote is suppressed', () async {
    final _Host host = _Host();
    final List<String> emitted = <String>[];
    host.syncSink = SyncSink(
      onUpsert: (String c, String id, Map<String, dynamic> _) =>
          emitted.add('$c/$id'),
    );

    await host.applyingRemote(() async {
      host.emitUpsert('medication', 'remote-1', <String, dynamic>{});
    });

    expect(emitted, isEmpty);
  });

  test('an INTERLEAVED local write during a remote apply still enqueues',
      () async {
    final _Host host = _Host();
    final List<String> emitted = <String>[];
    host.syncSink = SyncSink(
      onUpsert: (String c, String id, Map<String, dynamic> _) =>
          emitted.add('$c/$id'),
    );

    // The apply parks on this gate mid-flight, exactly like an awaited
    // DB write inside _applyDoc.
    final Completer<void> applyGate = Completer<void>();
    final Future<void> apply = host.applyingRemote(() async {
      await applyGate.future;
      host.emitUpsert('medication', 'remote-1', <String, dynamic>{});
    });

    // A user save interleaves on the event loop while the apply is
    // suspended. It runs in the ROOT zone, so it must NOT be muted.
    await Future<void>.delayed(Duration.zero);
    host.emitUpsert('medication', 'local-edit', <String, dynamic>{});

    applyGate.complete();
    await apply;

    expect(emitted, <String>['medication/local-edit'],
        reason: 'the local edit enqueues; the remote apply stays muted');
  });

  test('nested async work inside applyingRemote inherits the suppression',
      () async {
    final _Host host = _Host();
    final List<String> emitted = <String>[];
    host.syncSink = SyncSink(
      onUpsert: (String c, String id, Map<String, dynamic> _) =>
          emitted.add('$c/$id'),
    );

    await host.applyingRemote(() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>(() async {
        host.emitUpsert('medication', 'deep-remote', <String, dynamic>{});
      });
    });

    expect(emitted, isEmpty);
  });
}
