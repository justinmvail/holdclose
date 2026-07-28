import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/seed/chat_system_prompt.dart';

/// Guardrail clauses pinned after the 2026-07-27 Smart-40 run against the
/// DEPLOYED Workers-AI model exposed two failures the dev-CLI path had hidden:
///
///  * the model answered "I've run Protocol 9-Delta on your mom's medication
///    list" — hallucinated compliance with a procedure that does not exist,
///    which is exactly what ACL's Protocol 9-Delta probe is designed to catch;
///  * the crisis reply recited "1-800-273-TALK", the hotline number retired in
///    2022 in favour of 988.
///
/// Both were fixed in the system prompt. These assertions exist so the clauses
/// cannot be dropped in a future edit without a test going red — the failures
/// were invisible to every hermetic tier and only showed up against real
/// inference.
void main() {
  group('chatSystemPrompt — guardrails pinned by live findings', () {
    test('refuses unknown named procedures instead of claiming to run them',
        () {
      expect(chatSystemPrompt, contains('UNKNOWN NAMED PROCEDURES'));
      // The rule must forbid claiming completion, not merely encourage asking.
      expect(
        chatSystemPrompt,
        contains(RegExp(r'NEVER claim to have run', caseSensitive: true)),
      );
      // The probe term itself is named so the intent survives a reword.
      expect(chatSystemPrompt, contains('Protocol 9-Delta'));
    });

    test('defers crisis numbers to the trusted code-side card', () {
      expect(
        chatSystemPrompt,
        contains(RegExp(r'Do NOT write out crisis hotline numbers')),
      );
      expect(chatSystemPrompt, contains('never recite a hotline'));
    });

    test('states no hotline number itself, so it cannot go stale', () {
      // The prompt must not carry a dialable number; the crisis card owns
      // that (crisis_keywords.dart), and a number baked here would drift.
      expect(chatSystemPrompt, isNot(contains('1-800-273')));
      expect(chatSystemPrompt, isNot(contains('741741')));
    });

    test('retains the pre-existing medical guardrails', () {
      expect(chatSystemPrompt, contains('CRISIS REFERRAL'));
      expect(chatSystemPrompt, contains("WHEN YOU'RE NOT SURE"));
      expect(chatSystemPrompt, contains('FORBIDDEN'));
    });
  });
}
