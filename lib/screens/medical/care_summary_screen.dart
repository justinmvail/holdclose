import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/care_summary_provider.dart';
import '../../services/pdf_exporter.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// "Share a care summary" (`/care-summary`) — builds a one-page PDF of the
/// loved one's current conditions, allergies, medications, and upcoming
/// appointments, and hands it to the OS share sheet. The same current
/// picture for every clinician (coordinating between doctors).
class CareSummaryScreen extends ConsumerStatefulWidget {
  const CareSummaryScreen({super.key});

  static const Key shareButtonKey = Key('care-summary-share');

  @override
  ConsumerState<CareSummaryScreen> createState() => _CareSummaryScreenState();
}

class _CareSummaryScreenState extends ConsumerState<CareSummaryScreen> {
  bool _sharing = false;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final PdfExporter exporter = ref.read(pdfExporterProvider);
    Uint8List? bytes;
    try {
      bytes = await ref.read(careSummaryPdfProvider.future);
    } catch (_) {
      bytes = null;
    }
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _sharing = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't build the summary. Try again."),
      ));
      return;
    }
    await exporter.sharePdf(bytes, filename: 'care-summary.pdf');
    if (!mounted) return;
    setState(() => _sharing = false);
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
                  PathHeaderCrumb(label: 'Care summary'),
                ],
                title: 'Care summary',
                backLabel: 'Back to Care',
                leadingIcon: Icons.summarize_outlined,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: context.cb.surfaceWarm,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      "Share a one-page summary of your loved one's current "
                      'conditions, allergies, medications, and upcoming '
                      'appointments — the same picture for every clinician.',
                      style: tt.bodyMedium?.copyWith(color: context.cb.text),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    key: CareSummaryScreen.shareButtonKey,
                    onPressed: _sharing ? null : _share,
                    icon: const Icon(Icons.ios_share),
                    label: Text(
                        _sharing ? 'Preparing…' : 'Share care summary'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: context.cb.cta,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                    ),
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
