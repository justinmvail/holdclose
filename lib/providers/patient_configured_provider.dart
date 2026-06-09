import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/patient.dart';
import 'storage_provider.dart';

part 'patient_configured_provider.g.dart';

/// "Is a loved one ('your person') on file yet?" (new-user setup gate).
///
/// The first-run flow is onboarding carousel → sign-in → **loved-one
/// setup**. Until the caregiver saves a [Patient], the app has no
/// "your person" to anchor the Emergency Card, the Medical header, or
/// the decoder context on, so the router redirect (see
/// `careblazersRedirect`) funnels every authenticated location to
/// `/setup`.
///
/// Mirrors [OnboardingCompleted]: a `keepAlive` notifier exposing a
/// plain `bool` the go_router redirect reads synchronously on every
/// evaluation. The difference is the source of truth — onboarding is an
/// in-memory flag, whereas "patient configured" is derived from the
/// persisted [StorageProvider.getPatient]. `build()` therefore starts
/// optimistic-false and resolves the real value off the first
/// `getPatient()` await, flipping the notifier (and waking the router's
/// refresh listenable) once the answer lands.
///
/// After the setup wizard saves, it calls [reload] — which re-reads
/// storage and flips the flag true — so the redirect lets the caregiver
/// through to Home. In `DEMO_MODE` the seeded `maryHenderson` profile
/// means the very first resolve already returns true, so the wizard is
/// skipped and the demo boots straight to Home.
///
/// `keepAlive: true` so the resolved value survives the screen rebuilds
/// the setup → Home transition triggers (a non-keepAlive notifier would
/// rebuild back to the optimistic `false` mid-redirect and bounce the
/// caregiver back to `/setup`).
@Riverpod(keepAlive: true)
class PatientConfigured extends _$PatientConfigured {
  @override
  bool build() {
    // Kick off the async resolve; until it lands the redirect sees
    // `false`. Starting false (not true) keeps a fresh real-mode install
    // — where no patient exists — on the setup wizard rather than
    // briefly flashing Home before the load resolves.
    _resolve();
    return false;
  }

  Future<void> _resolve() async {
    final StorageProvider storage = ref.read(storageProvider);
    final Patient? patient = await storage.getPatient();
    final bool configured = patient != null;
    // The notifier may have been disposed mid-await (router torn down in
    // a test); guard the state write the same way an async notifier
    // would.
    if (ref.mounted && state != configured) {
      state = configured;
    }
  }

  /// Re-read storage and flip the flag. Called by the loved-one setup
  /// wizard immediately after it upserts the [Patient], so the router's
  /// refresh listenable fires and the `/setup` gate opens on the next
  /// evaluation.
  Future<void> reload() => _resolve();
}
