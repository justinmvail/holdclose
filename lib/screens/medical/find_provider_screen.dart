import 'package:flutter/material.dart';
// `Provider` (models/appointment.dart) collides with riverpod's `Provider`.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;

import '../../models/appointment.dart' show Provider, ProviderRole;
import '../../models/provider_search_result.dart';
import '../../providers/link_launcher_provider.dart';
import '../../providers/npi_provider_provider.dart';
import '../../seed/provider_search_reference.dart';
import '../../services/npi_provider_service.dart';
import '../../services/provider_repository.dart';
import '../../theme.dart';
import '../../widgets/form/id_factory.dart';
import '../../widgets/form/labelled_field.dart';
import '../../widgets/path_header.dart';
import '../../services/log_buffer.dart';

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
  static const Key typeToggleKey = Key('find-provider-type');
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

  // Provider-type filter: 'NPI-1' (people, default), 'NPI-2' (organizations),
  // or 'ALL' (both) — maps to the NPI `enumeration_type` param.
  String _providerType = 'NPI-1';

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
        enumerationType: _providerType == 'ALL' ? null : _providerType,
      );
    } catch (e) {
      logNonFatal('search.npi', e);
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
      backgroundColor: context.hc.background,
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
                    label: 'Show',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<String>(
                        key: FindProviderScreen.typeToggleKey,
                        segments: const <ButtonSegment<String>>[
                          ButtonSegment<String>(
                              value: 'NPI-1', label: Text('People')),
                          ButtonSegment<String>(
                              value: 'NPI-2', label: Text('Clinics')),
                          ButtonSegment<String>(
                              value: 'ALL', label: Text('All')),
                        ],
                        selected: <String>{_providerType},
                        showSelectedIcon: false,
                        onSelectionChanged: (Set<String> s) =>
                            setState(() => _providerType = s.first),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
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
                      // Filled Search action → AA-contrast token for white text.
                      backgroundColor: context.hc.ctaFilled,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Results come from the official U.S. directory of '
                    'licensed doctors and clinics. Tap Save to add one to '
                    'your providers.',
                    style: tt.bodySmall
                        ?.copyWith(color: context.hc.primarySoft),
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

/// tel: URI from a free-form phone string (mirrors emergency_card_screen).
Uri _telUri(String phone) {
  final String digits =
      phone.replaceAll(RegExp(r'[^0-9+]'), '').replaceAll(RegExp(r'(?!^)\+'), '');
  return Uri(scheme: 'tel', path: digits);
}

class _ResultCard extends ConsumerWidget {
  const _ResultCard({
    required this.result,
    required this.saved,
    required this.onSave,
  });

  final ProviderSearchResult result;
  final bool saved;
  final VoidCallback onSave;

  /// A labelled "Label  value" line — returns null (omitted) when [value] is
  /// blank, so the card shows only the fields the NPI record actually has.
  Widget? _line(BuildContext context, TextTheme tt, String label, String? value) {
    final String v = (value ?? '').trim();
    if (v.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text.rich(TextSpan(
        style: tt.bodyMedium?.copyWith(color: context.hc.primarySoft),
        children: <InlineSpan>[
          if (label.isNotEmpty)
            TextSpan(
                text: '$label  ',
                style: TextStyle(
                    color: context.hc.text, fontWeight: FontWeight.w600)),
          TextSpan(text: v),
        ],
      )),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme tt = Theme.of(context).textTheme;
    // "Charleston, SC 29401" — city/state plus ZIP when present.
    final String cityStateZip = <String>[
      if (result.displayLocation.isNotEmpty) result.displayLocation,
      if ((result.postalCode ?? '').trim().isNotEmpty) result.postalCode!.trim(),
    ].join(' ');
    final String? phone =
        (result.phone ?? '').trim().isEmpty ? null : result.phone!.trim();
    final String specialties = result.specialties.isNotEmpty
        ? result.specialties.join(', ')
        : (result.specialty ?? '');

    // Every field the record carries, in order — blanks return null and are
    // filtered out below.
    final List<Widget> lines = <Widget?>[
      Text(result.displayName,
          style: tt.titleMedium
              ?.copyWith(color: context.hc.primary, fontWeight: FontWeight.w700)),
      _line(context, tt, 'Type', result.providerType),
      _line(context, tt, 'Specialty', specialties),
      _line(context, tt, 'License', result.license),
      _line(context, tt, 'Address', result.addressLine),
      _line(context, tt, '', result.addressLine2),
      _line(context, tt, '', cityStateZip),
      if (phone != null)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: InkWell(
            onTap: () => ref.read(linkLauncherProvider).launch(_telUri(phone)),
            child: Row(
              children: <Widget>[
                // Tappable call link on the light card → AA-contrast salmon.
                Icon(Icons.call, size: 16, color: context.hc.ctaFilled),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('Call  $phone',
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodyMedium?.copyWith(
                          color: context.hc.ctaFilled,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      _line(context, tt, 'Fax', result.fax),
      // "NPI" is billing jargon — surface it plainly as "Provider ID," last
      // and de-emphasized, so a family caregiver isn't asked to parse it.
      _line(context, tt, 'Provider ID', result.npi),
    ].whereType<Widget>().toList();

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: context.hc.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines,
            ),
          ),
          const SizedBox(width: 8),
          saved
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.check_circle, color: context.hc.success),
                )
              : TextButton(
                  key: FindProviderScreen.saveKey(result.npi ?? result.name),
                  onPressed: onSave,
                  // Text action on the light card → AA-contrast salmon.
                  style: TextButton.styleFrom(
                      foregroundColor: context.hc.ctaFilled),
                  child: const Text('Save'),
                ),
        ],
      ),
    );
  }
}
