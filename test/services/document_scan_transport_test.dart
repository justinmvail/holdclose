import 'package:holdclose/services/document_scan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every AI feature that returns structure — the visit-prep questions, the
/// insurance-appeal drafts, the label scanners — funnels through
/// [jsonMapFromText]. If it can't parse the reply, the feature silently
/// produces nothing, so the shapes the REAL model emits are worth pinning.
///
/// The malformed samples below are verbatim captures from the deployed model
/// (60 structured-output runs, 2026-07-29): the model reliably strays on the
/// key's closing quote. Content was correct in all of them.
void main() {
  group('jsonMapFromText — well-formed replies', () {
    test('parses a plain object', () {
      final Map<String, dynamic>? m =
          jsonMapFromText('{"summary":"all fine","needs_attention":false}');
      expect(m?['summary'], 'all fine');
      expect(m?['needs_attention'], false);
    });

    test('parses through a code fence and a prose preamble', () {
      final Map<String, dynamic>? m = jsonMapFromText(
        'Here is the structured visit note:\n\n```\n'
        '{"summary":"quick visit","needs_attention":false}\n```',
      );
      expect(m?['summary'], 'quick visit');
    });
  });

  group('jsonMapFromText — the model\'s misplaced-quote tic', () {
    test('recovers a string value whose key lost its closing quote', () {
      final Map<String, dynamic>? m = jsonMapFromText('''
Here is the structured visit note:

```
{
  "summary": "Noticed red patch on Mrs Fowler's lower back during wash",
  "tasks_done": ["helped with wash", "applied cream"],
  "concern: red patch on lower back",
  "needs_attention": true
}
```
''');
      expect(m, isNotNull);
      expect(m?['concern'], 'red patch on lower back');
      expect(m?['needs_attention'], true,
          reason: 'the escalation flag must survive the repair');
      expect(m?['tasks_done'], <String>['helped with wash', 'applied cream']);
    });

    test('recovers a list value whose first element lost its opening quote',
        () {
      final Map<String, dynamic>? m = jsonMapFromText('''
{
  "summary": "Completed care tasks, addressed gas smell in kitchen",
  "tasks_done: [did his care as normal"],
  "concern": "smell of gas in kitchen",
  "needs_attention": true
}
''');
      expect(m, isNotNull);
      expect(m?['tasks_done'], <String>['did his care as normal']);
      expect(m?['concern'], 'smell of gas in kitchen');
      expect(m?['needs_attention'], true);
    });

    test('leaves a well-formed reply untouched', () {
      const String good =
          '{"summary":"a: b","concern":"time is 8: 00","needs_attention":false}';
      final Map<String, dynamic>? m = jsonMapFromText(good);
      expect(m?['summary'], 'a: b',
          reason: 'a colon INSIDE a value must not be treated as a key');
      expect(m?['concern'], 'time is 8: 00');
    });

    test('still rejects a reply that is only prose', () {
      expect(jsonMapFromText('I could not read that, sorry.'), isNull);
    });
  });

  group('jsonMapFromResponseBody', () {
    test('unwraps the {"text": "..."} contract the Worker returns', () {
      final Map<String, dynamic>? m = jsonMapFromResponseBody(
          <String, dynamic>{'text': '{"summary":"ok"}'});
      expect(m?['summary'], 'ok');
    });

    test('returns null for an error body', () {
      expect(
          jsonMapFromResponseBody(<String, dynamic>{'error': 'bad_request'}),
          isNull);
    });
  });
}
