import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/npi_provider_service.dart';

/// The provider-search service. Real (NPI Registry) in the app; tests
/// override this with [FakeNpiProviderService] so they never hit the
/// network. The NPI API is free + keyless, so demo builds use the real one.
final npiProviderServiceProvider =
    Provider<NpiProviderService>((ref) => const RealNpiProviderService());
