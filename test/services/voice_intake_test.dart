import 'package:careblazers/screens/journal/journal_wizard_screen.dart';
import 'package:careblazers/services/voice_intake.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceIntake.transcriptFor', () {
    test('returns the trimmed text for a matching kind', () {
      const AddSheetTranscript extra = AddSheetTranscript(
        text: '  gave the 8pm pill  ',
        kind: AddSheetKind.medDose,
      );
      expect(
        VoiceIntake.transcriptFor(extra, AddSheetKind.medDose),
        'gave the 8pm pill',
      );
    });

    test('returns null when the kind does not match', () {
      const AddSheetTranscript extra = AddSheetTranscript(
        text: 'gave the 8pm pill',
        kind: AddSheetKind.medDose,
      );
      expect(
        VoiceIntake.transcriptFor(extra, AddSheetKind.appointment),
        isNull,
      );
    });

    test('returns null for a non-transcript extra', () {
      expect(VoiceIntake.transcriptFor(null, AddSheetKind.medDose), isNull);
      expect(
        VoiceIntake.transcriptFor('some string', AddSheetKind.medDose),
        isNull,
      );
      expect(
        VoiceIntake.transcriptFor(
          const JournalWizardArgs(situationText: 'x'),
          AddSheetKind.journalEntry,
        ),
        isNull,
      );
    });

    test('returns null for a blank / whitespace transcript', () {
      const AddSheetTranscript extra = AddSheetTranscript(
        text: '   ',
        kind: AddSheetKind.medDose,
      );
      expect(VoiceIntake.transcriptFor(extra, AddSheetKind.medDose), isNull);
    });
  });

  group('VoiceIntake.journalTranscript', () {
    test('matches the journal-entry kind', () {
      const AddSheetTranscript extra = AddSheetTranscript(
        text: 'she kept asking for her mother',
        kind: AddSheetKind.journalEntry,
      );
      expect(
        VoiceIntake.journalTranscript(extra),
        'she kept asking for her mother',
      );
    });

    test('matches the quick-note kind', () {
      const AddSheetTranscript extra = AddSheetTranscript(
        text: 'remember the keys',
        kind: AddSheetKind.quickNote,
      );
      expect(VoiceIntake.journalTranscript(extra), 'remember the keys');
    });

    test('does not match a med-dose or appointment transcript', () {
      expect(
        VoiceIntake.journalTranscript(
          const AddSheetTranscript(
            text: 'gave the pill',
            kind: AddSheetKind.medDose,
          ),
        ),
        isNull,
      );
      expect(
        VoiceIntake.journalTranscript(
          const AddSheetTranscript(
            text: 'neuro follow-up',
            kind: AddSheetKind.appointment,
          ),
        ),
        isNull,
      );
    });
  });

  group('VoiceIntake.appointmentNotes / doseNote', () {
    test('appointmentNotes reads only the appointment kind', () {
      expect(
        VoiceIntake.appointmentNotes(
          const AddSheetTranscript(
            text: 'ask about evening agitation',
            kind: AddSheetKind.appointment,
          ),
        ),
        'ask about evening agitation',
      );
      expect(
        VoiceIntake.appointmentNotes(
          const AddSheetTranscript(
            text: 'gave the pill',
            kind: AddSheetKind.medDose,
          ),
        ),
        isNull,
      );
    });

    test('doseNote reads only the med-dose kind', () {
      expect(
        VoiceIntake.doseNote(
          const AddSheetTranscript(
            text: 'took it with breakfast',
            kind: AddSheetKind.medDose,
          ),
        ),
        'took it with breakfast',
      );
      expect(
        VoiceIntake.doseNote(
          const AddSheetTranscript(
            text: 'ask about agitation',
            kind: AddSheetKind.appointment,
          ),
        ),
        isNull,
      );
    });
  });

  group('AddSheetTranscript value semantics', () {
    test('equal text + kind compare equal and hash the same', () {
      const AddSheetTranscript a =
          AddSheetTranscript(text: 'hi', kind: AddSheetKind.medDose);
      const AddSheetTranscript b =
          AddSheetTranscript(text: 'hi', kind: AddSheetKind.medDose);
      const AddSheetTranscript c =
          AddSheetTranscript(text: 'hi', kind: AddSheetKind.quickNote);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('showVoiceCapturePermissionDeniedSnackBar', () {
    testWidgets('surfaces the permission copy on the ScaffoldMessenger',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () =>
                    showVoiceCapturePermissionDeniedSnackBar(context),
                child: const Text('tap'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('tap'));
      await tester.pump(); // let the snackbar animate in

      expect(find.text(voiceCapturePermissionDeniedMessage), findsOneWidget);
    });
  });
}
