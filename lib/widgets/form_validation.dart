import 'package:flutter/material.dart';

/// Form-validation helpers that enforce the app-wide rule: a caregiver must
/// always be able to tell WHY a form won't submit.
///
/// The pattern, per alpha feedback (fb_1780933601768901 / fb_1780932583896469):
///   * Keep the submit button TAPPABLE even when fields are empty — never
///     leave a greyed-out button with no explanation.
///   * On press, validate. If anything is invalid, the field-level errors
///     show (red border + inline message) AND the view scrolls to / focuses
///     the first offending field so the caregiver sees what to fix.
///
/// Use [validateAndScrollToFirstError] for any [Form]-based screen. It runs
/// `FormState.validate()` and, on failure, brings the first errored field
/// into view. Returns true when the form is valid (safe to persist), false
/// when it isn't (caller should bail before writing anything).
bool validateAndScrollToFirstError(GlobalKey<FormState> formKey) {
  final FormState? form = formKey.currentState;
  if (form == null) return false;
  final bool valid = form.validate();
  if (!valid) {
    scrollToFirstInvalidField(form.context);
  }
  return valid;
}

/// Walk the [formContext] subtree for the first [FormField] whose
/// [FormFieldState.hasError] is set and scroll it into view, focusing it when
/// it carries a focusable input. Best-effort: a form with no scrollable
/// ancestor (rare) simply no-ops the scroll but still focuses.
void scrollToFirstInvalidField(BuildContext formContext) {
  final BuildContext? target = _firstInvalidFieldContext(formContext);
  if (target == null) return;
  // ensureVisible walks up to the nearest Scrollable; harmless when there
  // isn't one. The eased curve keeps the jump gentle for the audience.
  Scrollable.ensureVisible(
    target,
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeInOut,
    alignment: 0.1,
  );
}

/// Depth-first search for the first errored [FormFieldState] under [context].
BuildContext? _firstInvalidFieldContext(BuildContext context) {
  BuildContext? found;
  void visit(Element element) {
    if (found != null) return;
    final State? state = element is StatefulElement ? element.state : null;
    if (state is FormFieldState && state.hasError) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  (context as Element).visitChildren(visit);
  return found;
}
