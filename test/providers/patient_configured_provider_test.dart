import 'package:careblazers/providers/patient_configured_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/seed/mary_henderson.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Build a container backed by [storage] so the provider's `getPatient()`
/// resolve reads a known store.
ProviderContainer _container(InMemoryStorageProvider storage) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      storageBackendProvider.overrideWithValue(storage),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('patientConfiguredProvider', () {
    test('starts false, then resolves false when no patient is on file',
        () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final ProviderContainer container = _container(storage);

      // The synchronous initial value the redirect reads is false — a
      // fresh real-mode install holds the caregiver on the setup wizard.
      expect(container.read(patientConfiguredProvider), isFalse);

      // The async resolve lands on false too (still no patient).
      await container.read(patientConfiguredProvider.notifier).reload();
      expect(container.read(patientConfiguredProvider), isFalse);
    });

    test('resolves true when a patient is already on file (DEMO_MODE case)',
        () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      await storage.upsertPatient(maryHenderson());
      final ProviderContainer container = _container(storage);

      // Force the async resolve to settle, then the gate reads true so
      // the wizard is skipped — the same condition DEMO_MODE produces by
      // seeding Mary before the first frame.
      await container.read(patientConfiguredProvider.notifier).reload();
      expect(container.read(patientConfiguredProvider), isTrue);
    });

    test('reload() flips false → true after a patient is saved', () async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      addTearDown(storage.dispose);
      final ProviderContainer container = _container(storage);

      await container.read(patientConfiguredProvider.notifier).reload();
      expect(container.read(patientConfiguredProvider), isFalse);

      // The setup wizard upserts a patient then calls reload — the gate
      // must now read true so the redirect lets the caregiver through.
      await storage.upsertPatient(maryHenderson());
      await container.read(patientConfiguredProvider.notifier).reload();

      expect(container.read(patientConfiguredProvider), isTrue);
    });
  });
}
