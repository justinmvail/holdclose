// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Holdclose';

  @override
  String get commonSave => 'Save';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonBack => 'Back';

  @override
  String get commonNext => 'Next';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonDone => 'Done';

  @override
  String get commonContinue => 'Continue';

  @override
  String get commonSkip => 'Skip';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonRemove => 'Remove';

  @override
  String get commonTryAgain => 'Try again';

  @override
  String get navHome => 'Home';

  @override
  String get navCommunity => 'Community';

  @override
  String get communityGuidelinesTitle => 'Community guidelines';

  @override
  String get communityGuidelinesBack => 'Back to Community';

  @override
  String get communityGuidelinesHeadline => 'The four agreements.';

  @override
  String get communityGuidelinesSubtitle =>
      'A two-minute read. These are the lines we hold each other to.';

  @override
  String get welcomeNextCta => 'Next →';

  @override
  String get welcomeGetStartedCta => 'Get started';

  @override
  String get welcomeSkipSemantics => 'Skip onboarding and go to sign-in.';

  @override
  String get signInTitle => 'Holdclose';

  @override
  String get signInTagline =>
      'We make caring for someone you love a little easier.';

  @override
  String get signInError => 'Couldn\'t sign in. Try again.';

  @override
  String get signInContinueWithApple => 'Continue with Apple';

  @override
  String get signInContinueWithAppleSemantics => 'Continue with Apple.';

  @override
  String get signInContinueWithGoogle => 'Continue with Google';

  @override
  String get signInContinueWithGoogleSemantics => 'Continue with Google.';

  @override
  String get signInDemoSkip => 'Skip — explore as Mary\'s caregiver';

  @override
  String get signInDemoSkipSemantics =>
      'Skip sign-in and explore as Mary\'s caregiver.';

  @override
  String get signInTermsPrefix => 'By continuing, you agree to our ';

  @override
  String get signInTermsLink => 'Terms';

  @override
  String get signInTermsConjunction => ' and ';

  @override
  String get signInPrivacyLink => 'Privacy Policy';

  @override
  String get signInTermsSuffix => '.';

  @override
  String get lovedOneSetupTitle => 'Let\'s set up your person';

  @override
  String get lovedOneSetupIntro =>
      'Just the essentials for now — the name is all we truly need. You can add or change anything later from the Emergency Card.';

  @override
  String get lovedOneSetupNameLabel => 'Their name';

  @override
  String get lovedOneSetupNameHint => 'e.g. Mom';

  @override
  String get lovedOneSetupNameError => 'Please enter their name.';

  @override
  String get lovedOneSetupAgeLabel => 'Age (optional)';

  @override
  String get lovedOneSetupAgeHint => 'e.g. 78';

  @override
  String get lovedOneSetupAgeError => 'Enter an age between 0 and 130.';

  @override
  String get lovedOneSetupDobLabel => 'Date of birth (optional)';

  @override
  String get lovedOneSetupDobNotSet => 'Not set';

  @override
  String get lovedOneSetupDobHint =>
      'Fills in their age for you — and it\'s what doctors and EMS ask for.';

  @override
  String get lovedOneSetupDobClear => 'Clear date of birth';

  @override
  String get lovedOneSetupDiagnosisLabel => 'Diagnosis (optional)';

  @override
  String get lovedOneSetupDiagnosisHint =>
      'e.g. Parkinson\'s, stroke recovery, a diagnosis';

  @override
  String get lovedOneSetupAllergiesLabel => 'Allergies (optional)';

  @override
  String get lovedOneSetupAllergiesHint => 'e.g. Penicillin';

  @override
  String get lovedOneSetupOnePerLine => 'One per line.';

  @override
  String get lovedOneSetupSave => 'Save and continue';

  @override
  String get lovedOneSetupSaving => 'Saving…';

  @override
  String get lovedOneSetupSaveSemantics =>
      'Save your person and continue to the app.';
}
