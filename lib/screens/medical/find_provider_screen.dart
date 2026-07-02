import 'package:flutter/material.dart';
// `Provider` (models/appointment.dart) collides with riverpod's `Provider`.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;

import '../../models/appointment.dart' show Provider, ProviderRole;
import '../../models/provider_search_result.dart';
import '../../providers/npi_provider_provider.dart';
import '../../seed/provider_search_reference.dart';
import '../../services/npi_provider_service.dart';
import '../../services/provider_repository.dart';
import '../../theme.dart';
import '../../widgets/form/id_factory.dart';
import '../../widgets/form/labelled_field.dart';
import '../../widgets/path_header.dart';

/// Find a clinician via the free NPI Registry, then save a match to the
/// caregiver's providers (so it's pickable when booking an appointment).
/// Closes the "finding providers" pain point.
///
/// Specialty, City, and State are type-ahead fields backed by
/// [provider_search_reference] — offline suggestion lists that still accept
/// free text. The typed State is normalised to a 2-letter code before it
/// hits the NPI API, and City suggestions narrow to the chosen State.
class FindProviderScreen extends ConsumerStatefulWidget {
  const FindProviderScreen({super.key});

  static const Key lastNameKey = Key('find-provider-lastname');
  static const Key specialtyKey = Key('find-provider-specialty');
  static const Key cityKey = Key('find-provider-city');
  static const Key stateKey = Key('find-provider-state');
  static const Key searchButtonKey = Key('find-provider-search');
  static Key saveKey(String id) => Key('find-provider-save-$id');

  @override
  ConsumerState<FindProviderScreen> createState() =>
      _FindProviderScreenState();
}

class _FindProviderScreenState extends ConsumerState<FindProviderScreen> {
  // Last name is a plain field we own. The three type-ahead fields are
  // driven by [Autocomplete], which owns its own controllers — we only
  // capture a reference (never dispose them) so [_search] can read them.
  final TextEditingController _lastName = TextEditingController();
  TextEditingController? _specialty;
  TextEditingController? _city;
  TextEditingController? _state;

  bool _searching = false;
  bool _searched = false;
  List<ProviderSearchResult> _results = <ProviderSearchResult>[];
  final Set<String> _saved = <String>{};

  @override
  void dispose() {
    _lastName.dispose();
    super.dispose();
  }

  String get _specialtyText => _specialty?.text.trim() ?? '';
  String get _cityText => _city?.text.trim() ?? '';
  String get _stateText => _state?.text.trim() ?? '';

  Future<void> _search() async {
    if (_searching) return;
    final String stateCode = normalizeStateCode(_stateText);
    if (_lastName.text.trim().isEmpty &&
        _specialtyText.isEmpty &&
        _cityText.isEmpty &&
        _stateText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter a name, specialty, city, or state to search.'),
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
        specialty: _specialtyText,
        city: _cityText,
        state: stateCode,
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

  // ---- suggestion sources -------------------------------------------------

  List<String> _suggestSpecialties(String q) {
    final String ql = q.toLowerCase();
    return clinicianSpecialties
        .where((String s) => s.toLowerCase().contains(ql))
        .toList();
  }

  List<String> _suggestStates(String q) {
    final String ql = q.toLowerCase();
    return usStates
        .where((UsState s) =>
            s.code.toLowerCase().startsWith(ql) ||
            s.name.toLowerCase().contains(ql))
        .map(stateLabel)
        .toList();
  }

  List<String> _suggestCities(String q) {
    final String ql = q.toLowerCase();
    // Narrow to the chosen state when one is set, so "Charleston" doesn't
    // mix SC and WV.
    final String code = normalizeStateCode(_stateText);
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    for (final UsCity c in majorUsCities) {
      if (code.isNotEmpty && c.state != code) continue;
      if (!c.name.toLowerCase().contains(ql)) continue;
      if (seen.add(c.name)) out.add(c.name);
    }
    return out;
  }

  Widget _typeAhead({
    required String label,
    required Key fieldKey,
    required String hint,
    required TextCapitalization caps,
    required List<String> Function(String) suggest,
    required void Function(TextEditingController) bind,
  }) {
    return LabelledField(
      label: label,
      child: Autocomplete<String>(
        optionsBuilder: (TextEditingValue value) {
          final String q = value.text.trim();
          if (q.isEmpty) return const Iterable<String>.empty();
          return suggest(q).take(8);
        },
        fieldViewBuilder: (BuildContext context,
            TextEditingController controller,
            FocusNode focusNode,
            VoidCallback onFieldSubmitted) {
          bind(controller);
          return TextField(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            textCapitalization: caps,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (_) => onFieldSubmitted(),
          );
        },
      ),
    );
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
                  _typeAhead(
                    label: 'Specialty',
                    fieldKey: FindProviderScreen.specialtyKey,
                    hint: 'e.g. Neurology',
                    caps: TextCapitalization.words,
                    suggest: _suggestSpecialties,
                    bind: (TextEditingController c) => _specialty = c,
                  ),
                  const SizedBox(height: 12),
                  _typeAhead(
                    label: 'City',
                    fieldKey: FindProviderScreen.cityKey,
                    hint: 'e.g. Charleston',
                    caps: TextCapitalization.words,
                    suggest: _suggestCities,
                    bind: (TextEditingController c) => _city = c,
                  ),
                  const SizedBox(height: 12),
                  _typeAhead(
                    label: 'State',
                    fieldKey: FindProviderScreen.stateKey,
                    hint: 'e.g. SC',
                    caps: TextCapitalization.words,
                    suggest: _suggestStates,
                    bind: (TextEditingController c) => _state = c,
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
