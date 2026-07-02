import 'package:flutter/material.dart';
// `Provider` (models/appointment.dart) collides with riverpod's `Provider`.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;

import '../../models/appointment.dart' show Provider, ProviderRole;
import '../../models/provider_search_result.dart';
import '../../providers/npi_provider_provider.dart';
import '../../services/npi_provider_service.dart';
import '../../services/provider_repository.dart';
import '../../theme.dart';
import '../../widgets/form/id_factory.dart';
import '../../widgets/form/labelled_field.dart';
import '../../widgets/path_header.dart';

/// Find a clinician via the free NPI Registry, then save a match to the
/// caregiver's providers (so it's pickable when booking an appointment).
/// Closes the "finding providers" pain point.
class FindProviderScreen extends ConsumerStatefulWidget {
  const FindProviderScreen({super.key});

  static const Key lastNameKey = Key('find-provider-lastname');
  static const Key specialtyKey = Key('find-provider-specialty');
  static const Key stateKey = Key('find-provider-state');
  static const Key searchButtonKey = Key('find-provider-search');
  static Key saveKey(String id) => Key('find-provider-save-$id');

  @override
  ConsumerState<FindProviderScreen> createState() =>
      _FindProviderScreenState();
}

class _FindProviderScreenState extends ConsumerState<FindProviderScreen> {
  final TextEditingController _lastName = TextEditingController();
  final TextEditingController _specialty = TextEditingController();
  final TextEditingController _state = TextEditingController();
  bool _searching = false;
  bool _searched = false;
  List<ProviderSearchResult> _results = <ProviderSearchResult>[];
  final Set<String> _saved = <String>{};

  @override
  void dispose() {
    _lastName.dispose();
    _specialty.dispose();
    _state.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_searching) return;
    if (_lastName.text.trim().isEmpty &&
        _specialty.text.trim().isEmpty &&
        _state.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter a name, specialty, or state to search.'),
      ));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    final NpiProviderService service = ref.read(npiProviderServiceProvider);
    List<ProviderSearchResult>? results;
    try {
      results = await service.search(
        name: _lastName.text.trim(),
        specialty: _specialty.text.trim(),
        state: _state.text.trim(),
      );
    } catch (_) {
      results = null;
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searched = true;
      _results = results ?? <ProviderSearchResult>[];
    });
    if (results == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Search failed — check your connection and try again.'),
      ));
    }
  }

  Future<void> _save(ProviderSearchResult r) async {
    final ProviderRepository repo =
        ref.read(providerRepositoryBackendProvider);
    final Provider provider = Provider(
      id: 'prov-${mintId('')}',
      name: r.displayName,
      role: _roleFor(r.specialty),
      phone: r.phone ?? '',
      address: r.fullAddress,
      notes: r.specialty,
    );
    await repo.upsertProvider(provider);
    if (!mounted) return;
    setState(() => _saved.add(r.npi ?? r.name));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Saved ${r.name} to your providers.'),
    ));
  }

  static ProviderRole _roleFor(String? specialty) {
    final String s = (specialty ?? '').toLowerCase();
    if (s.contains('neuro')) return ProviderRole.neurologist;
    if (s.contains('social')) return ProviderRole.socialWorker;
    if (s.isEmpty) return ProviderRole.other;
    return ProviderRole.doctor;
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: context.cb.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Find a provider'),
                ],
                title: 'Find a provider',
                backLabel: 'Back to Care',
                leadingIcon: Icons.person_search_outlined,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: <Widget>[
                  LabelledField(
                    label: 'Last name',
                    child: TextField(
                      key: FindProviderScreen.lastNameKey,
                      controller: _lastName,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(hintText: 'e.g. Berger'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LabelledField(
                    label: 'Specialty',
                    child: TextField(
                      key: FindProviderScreen.specialtyKey,
                      controller: _specialty,
                      textCapitalization: TextCapitalization.words,
                      decoration:
                          const InputDecoration(hintText: 'e.g. Neurology'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LabelledField(
                    label: 'State',
                    child: TextField(
                      key: FindProviderScreen.stateKey,
                      controller: _state,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(hintText: 'e.g. SC'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    key: FindProviderScreen.searchButtonKey,
                    onPressed: _searching ? null : _search,
                    icon: const Icon(Icons.search),
                    label: Text(_searching ? 'Searching…' : 'Search'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: context.cb.cta,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Results come from the public NPI Registry of U.S. '
                    'clinicians. Tap Save to add one to your providers.',
                    style: tt.bodySmall
                        ?.copyWith(color: context.cb.primarySoft),
                  ),
                  if (_searched && _results.isEmpty && !_searching)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Text('No matches. Try a broader search.',
                          style: tt.bodyMedium),
                    ),
                  for (final ProviderSearchResult r in _results)
                    _ResultCard(
                      result: r,
                      saved: _saved.contains(r.npi ?? r.name),
                      onSave: () => _save(r),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.saved,
    required this.onSave,
  });

  final ProviderSearchResult result;
  final bool saved;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: context.cb.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(result.displayName,
                    style: tt.titleMedium?.copyWith(
                        color: context.cb.primary,
                        fontWeight: FontWeight.w700)),
                if ((result.specialty ?? '').isNotEmpty)
                  Text(result.specialty!,
                      style:
                          tt.bodyMedium?.copyWith(color: context.cb.text)),
                if (result.displayLocation.isNotEmpty)
                  Text(result.displayLocation,
                      style: tt.bodyMedium
                          ?.copyWith(color: context.cb.primarySoft)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          saved
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.check_circle, color: context.cb.success),
                )
              : TextButton(
                  key: FindProviderScreen.saveKey(result.npi ?? result.name),
                  onPressed: onSave,
                  style: TextButton.styleFrom(foregroundColor: context.cb.cta),
                  child: const Text('Save'),
                ),
        ],
      ),
    );
  }
}
