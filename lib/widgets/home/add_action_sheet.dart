import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../routing/router.dart';
import '../../theme.dart';
import '../voice_button.dart';

/// The Add-sheet's teal accent. The brand palette (BUILD_SPEC.md §3.1)
/// carries no teal token, but the dashboard cards already use this exact
/// teal for the "done/taken" status dot
/// (`MedicationsTodayCard.takenColor`); the quick-add FAB reuses it so
/// "add something" reads as the same calm, affirmative color family.
const Color addSheetTeal = Color(0xFF1F8A70);

/// Which quick-add the caregiver chose from the Add sheet. Rides along
/// with a captured transcript (see [AddSheetTranscript]) so the
/// destination screen knows which field to pre-fill — Phase 14.14 owns
/// that downstream wiring.
enum AddSheetKind { journalEntry, medDose, appointment, quickNote }

/// Nav-`extra` payload handed to a quick-add destination when the row's
/// [VoiceButton] captured a transcript. A plain immutable value (mirrors
/// `JournalWizardArgs`) — not a freezed model, since it never persists or
/// serializes; it only rides a single `push`.
@immutable
class AddSheetTranscript {
  const AddSheetTranscript({required this.text, required this.kind});

  final String text;
  final AddSheetKind kind;

  @override
  bool operator ==(Object other) =>
      other is AddSheetTranscript &&
      other.text == text &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(text, kind);
}

/// Static description of one Add-sheet row: its label, leading glyph, and
/// the destination route a tap (or a captured transcript) pushes.
@immutable
class _AddRowSpec {
  const _AddRowSpec({
    required this.kind,
    required this.label,
    required this.icon,
    required this.routeName,
    this.queryParameters = const <String, String>{},
  });

  final AddSheetKind kind;
  final String label;
  final IconData icon;
  final String routeName;
  final Map<String, String> queryParameters;

  /// Stable key suffix for tests/goldens — the enum's wire name.
  String get id => kind.name;
}

/// The four quick-add rows, in display order (BUILD_SPEC.md Phase 14.13).
const List<_AddRowSpec> _rowSpecs = <_AddRowSpec>[
  _AddRowSpec(
    kind: AddSheetKind.journalEntry,
    label: 'Journal entry',
    icon: Icons.menu_book_outlined,
    routeName: CareblazersRoutes.journalNew,
  ),
  _AddRowSpec(
    kind: AddSheetKind.medDose,
    label: 'Med dose',
    icon: Icons.medication_outlined,
    routeName: CareblazersRoutes.medicationDoseLog,
  ),
  _AddRowSpec(
    kind: AddSheetKind.appointment,
    label: 'Appointment',
    icon: Icons.calendar_today_outlined,
    routeName: CareblazersRoutes.appointmentForm,
  ),
  _AddRowSpec(
    kind: AddSheetKind.quickNote,
    label: 'Quick note',
    icon: Icons.note_outlined,
    routeName: CareblazersRoutes.journalNew,
    queryParameters: <String, String>{'kind': 'note'},
  ),
];

/// The floating quick-add button anchored bottom-right of the Home
/// dashboard (BUILD_SPEC.md Phase 14.13): a 58px teal circle with a white
/// `+` glyph. Sits in the Home [Scaffold]'s `floatingActionButton` slot,
/// so the framework keeps it clear of the safe-area inset, and — because
/// Home's scaffold body ends at the top of the shell's tab bar — clear of
/// the tab bar too.
class AddActionFab extends StatelessWidget {
  const AddActionFab({super.key});

  /// Tap target + golden/test handle.
  static const Key fabKey = Key('home-add-fab');

  static const double _diameter = 58;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _diameter,
      height: _diameter,
      child: FloatingActionButton(
        key: fabKey,
        backgroundColor: addSheetTeal,
        foregroundColor: careblazersColors.background,
        shape: const CircleBorder(),
        tooltip: 'Add',
        elevation: 3,
        onPressed: () => showAddActionSheet(context),
        child: const Icon(Icons.add, size: 30),
      ),
    );
  }
}

/// Opens the multi-kind Add sheet (BUILD_SPEC.md Phase 14.13). Exposed so
/// the FAB — and tests — share one entry point.
Future<void> showAddActionSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: careblazersColors.background,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => const AddActionSheet(),
  );
}

/// Body of the multi-kind Add sheet — four word-labeled rows, each with a
/// leading glyph, a tappable label that pushes the row's destination, and
/// a trailing [VoiceButton] that captures a transcript and forwards it to
/// the same destination as an [AddSheetTranscript].
class AddActionSheet extends StatelessWidget {
  const AddActionSheet({super.key});

  /// Golden/test handle for the sheet body.
  static const Key sheetKey = Key('home-add-action-sheet');

  /// Pop the sheet, then push [spec]'s destination on the root navigator.
  /// The router is resolved before the pop so the push doesn't lean on a
  /// context that's about to be torn down. [transcript] is null for a
  /// plain row tap and an [AddSheetTranscript] for a voice capture.
  static void _go(
    BuildContext context,
    _AddRowSpec spec, {
    AddSheetTranscript? transcript,
  }) {
    final GoRouter router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.pushNamed(
      spec.routeName,
      queryParameters: spec.queryParameters,
      extra: transcript,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final TextStyle labelStyle =
        (textTheme.titleLarge ?? const TextStyle()).copyWith(
      fontSize: 18,
      color: careblazersColors.primary,
    );

    return SafeArea(
      key: sheetKey,
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final _AddRowSpec spec in _rowSpecs)
            ListTile(
              key: Key('add-row-${spec.id}'),
              leading: Icon(spec.icon, color: careblazersColors.primarySoft),
              title: Text(spec.label, style: labelStyle),
              trailing: VoiceButton(
                key: Key('add-row-voice-${spec.id}'),
                semanticLabel: '${spec.label} by voice',
                onTranscript: (String text) => _go(
                  context,
                  spec,
                  transcript:
                      AddSheetTranscript(text: text, kind: spec.kind),
                ),
              ),
              onTap: () => _go(context, spec),
            ),
        ],
      ),
    );
  }
}
