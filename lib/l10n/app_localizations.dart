import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es')
  ];

  /// The application's name, shown as the MaterialApp title.
  ///
  /// In en, this message translates to:
  /// **'Holdclose'**
  String get appTitle;

  /// Generic confirm/save button label, reused across forms.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// Generic dismiss/cancel button label, reused across forms and dialogs.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// Generic back navigation label.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get commonBack;

  /// Generic advance/next button label, reused across multi-step flows.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get commonNext;

  /// Generic destructive delete button label, reused across lists and detail screens.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// Generic add/create button label, reused across managers and lists.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get commonAdd;

  /// Generic completion/dismiss button label, reused across modals and editors.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get commonDone;

  /// Generic continue/proceed button label, reused across flows.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get commonContinue;

  /// Generic skip button label, reused across onboarding and optional steps.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get commonSkip;

  /// Generic edit button label, reused across detail and manager screens.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get commonEdit;

  /// Generic remove button label, reused across editable lists (distinct from Delete).
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get commonRemove;

  /// Generic retry call-to-action shown after a recoverable failure.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get commonTryAgain;

  /// Home destination label, used in breadcrumbs and the bottom tab bar.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// Community destination label, used in breadcrumbs and the bottom tab bar.
  ///
  /// In en, this message translates to:
  /// **'Community'**
  String get navCommunity;

  /// Title of the community guidelines screen and its terminal breadcrumb crumb.
  ///
  /// In en, this message translates to:
  /// **'Community guidelines'**
  String get communityGuidelinesTitle;

  /// Word-labeled back affordance on the community guidelines path header.
  ///
  /// In en, this message translates to:
  /// **'Back to Community'**
  String get communityGuidelinesBack;

  /// Section headline introducing the four community guideline cards.
  ///
  /// In en, this message translates to:
  /// **'The four agreements.'**
  String get communityGuidelinesHeadline;

  /// Supporting subtitle under the community guidelines headline.
  ///
  /// In en, this message translates to:
  /// **'A two-minute read. These are the lines we hold each other to.'**
  String get communityGuidelinesSubtitle;

  /// Bottom call-to-action on welcome-carousel pages 1-2 that advances to the next page. Carries a trailing arrow glyph, so it is screen-specific rather than the shared commonNext label.
  ///
  /// In en, this message translates to:
  /// **'Next →'**
  String get welcomeNextCta;

  /// Bottom call-to-action on the final welcome-carousel page that hands off to sign-in.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get welcomeGetStartedCta;

  /// Screen-reader (Semantics) label for the welcome-carousel Skip button.
  ///
  /// In en, this message translates to:
  /// **'Skip onboarding and go to sign-in.'**
  String get welcomeSkipSemantics;

  /// Brand wordmark shown at the top of the sign-in screen.
  ///
  /// In en, this message translates to:
  /// **'Holdclose'**
  String get signInTitle;

  /// Tagline beneath the wordmark on the sign-in screen; mirrors welcome-carousel page 1.
  ///
  /// In en, this message translates to:
  /// **'We make caring for someone you love a little easier.'**
  String get signInTagline;

  /// Error banner message shown when an OAuth sign-in flow fails or is cancelled.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t sign in. Try again.'**
  String get signInError;

  /// Plain-language privacy-reassurance line shown just above the sign-in buttons: why sign in, and that data stays private. Keeps the vendor invisible per the brand rule.
  ///
  /// In en, this message translates to:
  /// **'Signing in keeps your notes safe and in sync across your devices. We never post anything, and your loved one\'s information stays private.'**
  String get signInReassurance;

  /// Label on the Sign in with Apple button (iOS only).
  ///
  /// In en, this message translates to:
  /// **'Continue with Apple'**
  String get signInContinueWithApple;

  /// Screen-reader (Semantics) label for the Sign in with Apple button.
  ///
  /// In en, this message translates to:
  /// **'Continue with Apple.'**
  String get signInContinueWithAppleSemantics;

  /// Label on the Sign in with Google button (both platforms).
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get signInContinueWithGoogle;

  /// Screen-reader (Semantics) label for the Sign in with Google button.
  ///
  /// In en, this message translates to:
  /// **'Continue with Google.'**
  String get signInContinueWithGoogleSemantics;

  /// Label on the DEMO_MODE-only button that bypasses OAuth and lands on Home as the seeded caregiver.
  ///
  /// In en, this message translates to:
  /// **'Skip — explore as Mary\'s caregiver'**
  String get signInDemoSkip;

  /// Screen-reader (Semantics) label for the DEMO_MODE-only skip-sign-in button.
  ///
  /// In en, this message translates to:
  /// **'Skip sign-in and explore as Mary\'s caregiver.'**
  String get signInDemoSkipSemantics;

  /// Leading text of the terms-and-privacy consent line on the sign-in screen, before the Terms link.
  ///
  /// In en, this message translates to:
  /// **'By continuing, you agree to our '**
  String get signInTermsPrefix;

  /// Tappable 'Terms' link text within the sign-in consent line.
  ///
  /// In en, this message translates to:
  /// **'Terms'**
  String get signInTermsLink;

  /// Connecting text between the Terms and Privacy Policy links on the sign-in consent line.
  ///
  /// In en, this message translates to:
  /// **' and '**
  String get signInTermsConjunction;

  /// Tappable 'Privacy Policy' link text within the sign-in consent line.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get signInPrivacyLink;

  /// Trailing punctuation that closes the sign-in consent line after the Privacy Policy link.
  ///
  /// In en, this message translates to:
  /// **'.'**
  String get signInTermsSuffix;

  /// Light overline cue above the setup heading letting a tired caregiver know the onboarding finish line is near.
  ///
  /// In en, this message translates to:
  /// **'Last step'**
  String get lovedOneSetupLastStep;

  /// Heading on the new-user loved-one setup wizard.
  ///
  /// In en, this message translates to:
  /// **'Let\'s set up your person'**
  String get lovedOneSetupTitle;

  /// Warm introductory paragraph under the loved-one setup heading.
  ///
  /// In en, this message translates to:
  /// **'Just the essentials for now — the name is all we truly need. You can add or change anything later from the Emergency Card.'**
  String get lovedOneSetupIntro;

  /// Field label for the required loved-one name input.
  ///
  /// In en, this message translates to:
  /// **'Their name'**
  String get lovedOneSetupNameLabel;

  /// Placeholder hint for the loved-one name field.
  ///
  /// In en, this message translates to:
  /// **'e.g. Mom'**
  String get lovedOneSetupNameHint;

  /// Validation message shown when the required loved-one name field is left blank.
  ///
  /// In en, this message translates to:
  /// **'Please enter their name.'**
  String get lovedOneSetupNameError;

  /// Field label for the optional loved-one age input.
  ///
  /// In en, this message translates to:
  /// **'Age (optional)'**
  String get lovedOneSetupAgeLabel;

  /// Placeholder hint for the loved-one age field.
  ///
  /// In en, this message translates to:
  /// **'e.g. 78'**
  String get lovedOneSetupAgeHint;

  /// Validation message shown when the loved-one age is out of the accepted range.
  ///
  /// In en, this message translates to:
  /// **'Enter an age between 0 and 130.'**
  String get lovedOneSetupAgeError;

  /// Field label for the optional loved-one date-of-birth picker.
  ///
  /// In en, this message translates to:
  /// **'Date of birth (optional)'**
  String get lovedOneSetupDobLabel;

  /// Placeholder shown in the date-of-birth field before a date is picked.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get lovedOneSetupDobNotSet;

  /// Hint under the date-of-birth label explaining why it's worth setting.
  ///
  /// In en, this message translates to:
  /// **'Fills in their age for you — and it\'s what doctors and EMS ask for.'**
  String get lovedOneSetupDobHint;

  /// Tooltip on the affordance that clears a picked date of birth.
  ///
  /// In en, this message translates to:
  /// **'Clear date of birth'**
  String get lovedOneSetupDobClear;

  /// Field label for the optional loved-one diagnosis input.
  ///
  /// In en, this message translates to:
  /// **'Diagnosis (optional)'**
  String get lovedOneSetupDiagnosisLabel;

  /// Placeholder hint for the loved-one diagnosis field.
  ///
  /// In en, this message translates to:
  /// **'e.g. Parkinson\'s, stroke recovery, a diagnosis'**
  String get lovedOneSetupDiagnosisHint;

  /// Field label for the optional loved-one allergies input.
  ///
  /// In en, this message translates to:
  /// **'Allergies (optional)'**
  String get lovedOneSetupAllergiesLabel;

  /// Placeholder hint for the loved-one allergies field.
  ///
  /// In en, this message translates to:
  /// **'e.g. Penicillin'**
  String get lovedOneSetupAllergiesHint;

  /// Hint reminding the caregiver to enter one item per line in the allergies field.
  ///
  /// In en, this message translates to:
  /// **'One per line.'**
  String get lovedOneSetupOnePerLine;

  /// Primary submit button label on the loved-one setup wizard.
  ///
  /// In en, this message translates to:
  /// **'Save and continue'**
  String get lovedOneSetupSave;

  /// Busy-state label shown on the setup wizard submit button while the save is in flight.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get lovedOneSetupSaving;

  /// Screen-reader (Semantics) label for the loved-one setup submit button.
  ///
  /// In en, this message translates to:
  /// **'Save your person and continue to the app.'**
  String get lovedOneSetupSaveSemantics;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
