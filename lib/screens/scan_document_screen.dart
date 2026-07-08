import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appointment_draft.dart';
import '../models/document.dart' show Insurance;
import '../providers/appointment_scanner_provider.dart';
import '../providers/insurance_card_scanner_provider.dart';
import '../theme.dart';
import '../widgets/path_header.dart';
import 'medication/prescription_scan_flow.dart';
import 'scan_capture.dart';

/// One place to "scan any care document" — routes each type to its extractor
/// + review flow (prescription → medication review, appointment card →
/// appointment form, insurance card → emergency card). Addresses the
/// paperwork / organizing-records pain points with a single obvious entry.
class ScanDocumentScreen extends ConsumerWidget {
  const ScanDocumentScreen({super.key});

  static Key optionKey(String id) => Key('scan-doc-$id');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Scan a document'),
                ],
                title: 'Scan a document',
                backLabel: 'Back to Care',
                leadingIcon: Icons.document_scanner_outlined,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Take a photo — the AI reads it and you review before '
                      'anything is saved.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: context.hc.primarySoft,
                          ),
                    ),
                  ),
                  _ScanOption(
                    id: 'prescription',
                    icon: Icons.medication_outlined,
                    title: 'Prescription label',
                    subtitle: 'Name, dosage, refills, pharmacy',
                    onTap: () => _scanPrescription(context, ref),
                  ),
                  _ScanOption(
                    id: 'appointment',
                    icon: Icons.event_outlined,
                    title: 'Appointment card',
                    subtitle: 'Provider, date, time, location',
                    onTap: () => _scanAppointment(context, ref),
                  ),
                  _ScanOption(
                    id: 'insurance',
                    icon: Icons.shield_outlined,
                    title: 'Insurance card',
                    subtitle: 'Carrier, member ID, group, phone',
                    onTap: () => _scanInsurance(context, ref),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanPrescription(BuildContext context, WidgetRef ref) async {
    final draft = await capturePrescriptionDraft(context, ref);
    if (draft == null || !context.mounted) return;
    unawaited(context.push('/medications/scan/review', extra: draft));
  }

  Future<void> _scanAppointment(BuildContext context, WidgetRef ref) async {
    final scanner = ref.read(appointmentScannerProvider);
    final AppointmentDraft? draft = await captureScanDraft<AppointmentDraft>(
      context,
      ref,
      extract: (String path) => scanner.extractFromImage(imagePath: path),
      emptyDraft: const AppointmentDraft(),
    );
    if (draft == null || !context.mounted) return;
    if (draft.isEmpty) showScanCouldNotReadHint(context);
    unawaited(context.push('/appointments/new', extra: draft));
  }

  Future<void> _scanInsurance(BuildContext context, WidgetRef ref) async {
    final scanner = ref.read(insuranceCardScannerProvider);
    final Insurance? insurance = await captureScanDraft<Insurance>(
      context,
      ref,
      extract: (String path) => scanner.extractFromImage(imagePath: path),
      emptyDraft: const Insurance(
        carrier: '',
        policyNumber: '',
        groupNumber: '',
      ),
    );
    if (insurance == null || !context.mounted) return;
    unawaited(
        context.push('/medical/cards/emergency/edit', extra: insurance));
  }
}

class _ScanOption extends StatelessWidget {
  const _ScanOption({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: context.hc.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: ScanDocumentScreen.optionKey(id),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Row(
              children: <Widget>[
                Icon(icon, color: context.hc.primary),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: tt.titleMedium?.copyWith(
                          color: context.hc.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: tt.bodyMedium?.copyWith(
                          color: context.hc.primarySoft,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: context.hc.primarySoft),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
