import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/insurance_appeal_provider.dart';
import '../../providers/visit_prep_provider.dart' show careContextTextProvider;
import '../../services/insurance_appeal_service.dart';
import '../../theme.dart';
import '../../widgets/form/labelled_field.dart';
import '../../widgets/path_header.dart';

/// AI insurance-appeal helper (`/insurance-appeal`). The caregiver describes
/// what was denied and why; a grounded coach drafts an appeal letter they can
/// edit and copy. The draft is explicitly NOT legal or medical advice — it's
/// a starting point the caregiver personalizes and sends.
class InsuranceAppealScreen extends ConsumerStatefulWidget {
  const InsuranceAppealScreen({super.key, this.carrier});

  /// Optional carrier name (passed from the emergency card's insurance
  /// block) so the draft can address it; a placeholder is used otherwise.
  final String? carrier;

  static const Key claimFieldKey = Key('appeal-claim');
  static const Key denialFieldKey = Key('appeal-denial');
  static const Key draftButtonKey = Key('appeal-draft');
  static const Key letterFieldKey = Key('appeal-letter');
  static const Key copyButtonKey = Key('appeal-copy');

  @override
  ConsumerState<InsuranceAppealScreen> createState() =>
      _InsuranceAppealScreenState();
}

class _InsuranceAppealScreenState
    extends ConsumerState<InsuranceAppealScreen> {
  final TextEditingController _claim = TextEditingController();
  final TextEditingController _denial = TextEditingController();
  final TextEditingController _letter = TextEditingController();
  bool _drafting = false;
  bool _hasLetter = false;

  @override
  void dispose() {
    _claim.dispose();
    _denial.dispose();
    _letter.dispose();
    super.dispose();
  }

  Future<void> _draft() async {
    if (_drafting) return;
    if (_claim.text.trim().isEmpty || _denial.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tell me what was denied and the reason first.'),
      ));
      return;
    }
    setState(() => _drafting = true);
    final InsuranceAppealService service =
        ref.read(insuranceAppealServiceProvider);
    String careContext = '';
    try {
      careContext = await ref.read(careContextTextProvider.future);
    } catch (_) {
      careContext = '';
    }
    String? letter;
    try {
      letter = await service.draftAppeal(
        denialReason: _denial.text.trim(),
        claimDetails: _claim.text.trim(),
        carrier: widget.carrier,
        careContext: careContext,
      );
    } catch (_) {
      letter = null;
    }
    if (!mounted) return;
    setState(() => _drafting = false);
    if (letter == null || letter.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't draft a letter right now. Try again."),
      ));
      return;
    }
    setState(() {
      _letter.text = letter!;
      _hasLetter = true;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _letter.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Draft copied — paste it into an email or document.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme tt = theme.textTheme;
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
                  PathHeaderCrumb(label: 'Insurance appeal'),
                ],
                title: 'Insurance appeal',
                backLabel: 'Back to Care',
                leadingIcon: Icons.description_outlined,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: context.hc.surfaceWarm,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'This drafts an appeal letter for you to review, edit, '
                      'and send. It is a starting point — not legal or medical '
                      'advice. Check every detail before you send it.',
                      style: tt.bodyMedium?.copyWith(color: context.hc.text),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'What was denied?',
                    child: TextField(
                      key: InsuranceAppealScreen.claimFieldKey,
                      controller: _claim,
                      maxLines: 2,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Physical therapy sessions, MRI, a med',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabelledField(
                    label: 'Reason given for the denial',
                    child: TextField(
                      key: InsuranceAppealScreen.denialFieldKey,
                      controller: _denial,
                      maxLines: 3,
                      minLines: 2,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Copy the reason from the denial letter',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    key: InsuranceAppealScreen.draftButtonKey,
                    onPressed: _drafting ? null : _draft,
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text(_drafting ? 'Drafting…' : 'Draft appeal letter'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: context.hc.cta,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  if (_hasLetter) ...<Widget>[
                    const SizedBox(height: 24),
                    Text(
                      'Your draft',
                      style: tt.titleMedium?.copyWith(
                        color: context.hc.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: InsuranceAppealScreen.letterFieldKey,
                      controller: _letter,
                      maxLines: null,
                      minLines: 8,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: InsuranceAppealScreen.copyButtonKey,
                      onPressed: _copy,
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('Copy draft'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.hc.primary,
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
