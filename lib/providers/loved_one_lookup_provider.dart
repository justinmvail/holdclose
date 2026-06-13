import 'package:flutter/foundation.dart' show debugPrint;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/sync_service.dart';
import 'patient_configured_provider.dart';

part 'loved_one_lookup_provider.g.dart';

/// Gates the first-run `/setup` redirect on a one-time backend lookup, so a
/// returning caregiver isn't forced to re-create the loved one they already
/// have.
///
/// On a fresh sign-in (new install / new device) the local database has no
/// loved one yet, but the account may already own one on the backend — a
/// caregiver's circle survives reinstall (the verified Google `sub` is the
/// account spine). The `/setup` gate keys off the LOCAL
/// [patientConfiguredProvider] only, so without this it funnels the
/// caregiver straight into the setup wizard, they create a DUPLICATE
/// person, and sync then pulls their real loved one down and shadows the
/// duplicate as inactive (fb 2026-06-13: "logging in made me add who I'm
/// caring for, then my previous person came back and was the active one,
/// not the one I just added").
///
/// This notifier exposes a plain `bool` — `true` while the post-sign-in
/// lookup is IN FLIGHT — that the router redirect reads synchronously (the
/// same shape as [PatientConfigured] / `OnboardingCompleted`). The sign-in
/// flow [begin]s it before the OAuth round-trip (so the gate is already
/// engaged the instant auth flips to signed-in and the redirect first
/// re-evaluates), [adopt]s any existing loved one off the backend, then
/// [end]s it — at which point the redirect makes the real home-vs-setup
/// decision. Defaults `false` so local-only / demo / test flows never
/// stall on the gate.
///
/// `keepAlive: true` so the gate survives the sign-in → home/setup screen
/// rebuilds (a non-keepAlive notifier would rebuild back to `false`
/// mid-flow) and so [adopt] keeps running even if the sign-in screen that
/// kicked it off is torn down by the redirect.
@Riverpod(keepAlive: true)
class LovedOneLookup extends _$LovedOneLookup {
  @override
  bool build() => false;

  /// Engage the gate — called at the START of the sign-in flow, BEFORE the
  /// OAuth round-trip, so it's already held by the time auth flips to
  /// signed-in and the redirect first re-evaluates (otherwise the redirect
  /// would flash the `/setup` wizard in the window before [adopt] runs).
  void begin() {
    if (!state) state = true;
  }

  /// Release the gate — the redirect now decides home-vs-setup off
  /// [patientConfiguredProvider].
  void end() {
    if (state) state = false;
  }

  /// Consult the backend for a loved one the just-signed-in account already
  /// owns and, if found, adopt them onto this device (so the `/setup` gate
  /// opens to Home rather than the wizard). A NO-OP when a loved one is
  /// already on file locally (a returning caregiver with local data, or the
  /// demo's seeded Mary). NEVER throws and is time-bounded — a backend that
  /// is offline, unreachable, or hung leaves the app on the setup path
  /// exactly as before this lookup existed, so sign-in always completes.
  Future<void> adopt() async {
    try {
      // Already have a loved one on THIS device — nothing to adopt.
      if (ref.read(patientConfiguredProvider)) return;
      final SyncController sync = ref.read(syncControllerProvider);
      // Adopt the account's existing circle (if any) + apply its loved
      // one, then pull the rest of their shared data down. Bounded so a
      // hung backend can't strand the caregiver on the sign-in spinner —
      // on timeout we fall through to the setup wizard.
      await sync
          .bootstrapCircle()
          .then((_) => sync.syncNow())
          .timeout(const Duration(seconds: 12));
      // Re-read storage so the gate opens if a loved one came down.
      await ref.read(patientConfiguredProvider.notifier).reload();
    } catch (e) {
      // Fail-safe: offline / no backend / no circle / timeout → fall
      // through to the setup wizard, exactly as before this lookup existed.
      debugPrint('lovedOneLookup: adopt failed (continuing to setup): $e');
    }
  }
}
