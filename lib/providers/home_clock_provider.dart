import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'home_clock_provider.g.dart';

/// Wall clock the Home dashboard greeting reads to pick
/// morning / afternoon / evening (BUILD_SPEC.md Phase 14.7).
///
/// Exposed as an overridable `DateTime Function()` so widget + golden
/// tests pin a deterministic hour without touching system time —
/// mirrors the [quietHoursClockProvider] pattern in
/// `quiet_hours_provider.dart`. Unlike the quiet-hours clock the
/// greeting doesn't poll on a timer: it only needs to be correct each
/// time Home rebuilds, which a tab switch or app resume already
/// triggers.
@Riverpod(keepAlive: true)
DateTime Function() homeClock(Ref ref) => DateTime.now;
