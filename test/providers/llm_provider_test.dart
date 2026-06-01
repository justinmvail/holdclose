import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/seed/fake_llm_seeds.dart';
import 'package:careblazers/seed/system_prompt.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

void main() {
  // Fixed triage so the call surface is identical across behaviors —
  // the fake doesn't branch on triage but the contract requires it.
  const TriageAnswers triage = TriageAnswers(
    when: TriageWhen.lateAfternoonEvening,
    whatChanged: TriageWhatChanged.nothing,
    whatTried: TriageWhatTried.talked,
  );
  const PatientContext patient = PatientContext(
    stage: 'stage 5 (moderately severe)',
    age: 78,
  );

  // Use a zero delay so the test suite stays fast — the streaming
  // semantics (chunk count + content) are independent of wall-clock
  // delay, and the production constructor defaults to 60ms.
  FakeLLMProvider buildFake() => FakeLLMProvider(
        delay: Duration.zero,
        clock: () => DateTime.utc(2026, 5, 29, 19, 42),
      );

  group('FakeLLMProvider — per-behavior stream contract', () {
    for (final Behavior b in Behavior.canonical) {
      test('${b.id} emits ≥3 partial chunks then a done', () async {
        final FakeLLMProvider fake = buildFake();
        final List<DecoderChunk> chunks = await fake
            .generateDecoderScript(
              behavior: b,
              triage: triage,
              patient: patient,
              attempt: 1,
            )
            .toList();

        // At least 3 partials + 1 done.
        expect(chunks.length, greaterThanOrEqualTo(4),
            reason: '${b.id} produced too few chunks: ${chunks.length}');

        final List<DecoderChunk> partials = chunks
            .whereType<DecoderChunkPartial>()
            .toList();
        expect(partials.length, greaterThanOrEqualTo(3),
            reason: '${b.id} produced only ${partials.length} partials');

        // Terminal chunk is a done carrying a non-empty DecoderResult.
        expect(chunks.last, isA<DecoderChunkDone>());
        final DecoderChunkDone done = chunks.last as DecoderChunkDone;
        final DecoderResult result = done.result;
        expect(result.say, isNotEmpty,
            reason: '${b.id} done.result.say was empty');
        expect(result.tweak, isNotEmpty,
            reason: '${b.id} done.result.tweak was empty');
        expect(result.dontSay, isNotEmpty,
            reason: '${b.id} done.result.dontSay was empty');
      });
    }
  });

  group('FakeLLMProvider — streaming shape', () {
    test('partials carry monotonically growing accumulated JSON', () async {
      final FakeLLMProvider fake = buildFake();
      final List<DecoderChunk> chunks = await fake
          .generateDecoderScript(
            behavior: Behavior.byId('sundowning')!,
            triage: triage,
            patient: patient,
            attempt: 1,
          )
          .toList();
      final List<String> accumulations = chunks
          .whereType<DecoderChunkPartial>()
          .map((DecoderChunkPartial p) => p.accumulatedJson)
          .toList();

      for (int i = 1; i < accumulations.length; i++) {
        expect(
          accumulations[i].startsWith(accumulations[i - 1]),
          isTrue,
          reason: 'partial #$i is not a prefix-superset of #${i - 1}',
        );
        expect(
          accumulations[i].length,
          greaterThan(accumulations[i - 1].length),
        );
      }
    });

    test(
      'final partial accumulation is parseable JSON and matches the done',
      () async {
        final FakeLLMProvider fake = buildFake();
        final List<DecoderChunk> chunks = await fake
            .generateDecoderScript(
              behavior: Behavior.byId('accusing')!,
              triage: triage,
              patient: patient,
              attempt: 1,
            )
            .toList();
        final List<DecoderChunkPartial> partials = chunks
            .whereType<DecoderChunkPartial>()
            .toList();
        final DecoderChunkDone done = chunks.last as DecoderChunkDone;

        final Map<String, dynamic> parsed =
            json.decode(partials.last.accumulatedJson)
                as Map<String, dynamic>;
        expect(parsed['say'], equals(done.result.say));
        expect(parsed['tweak'], equals(done.result.tweak));
        expect(parsed['dont_say'], equals(done.result.dontSay));
      },
    );

    test('clock stamps generatedAt on done.result', () async {
      final DateTime fixed = DateTime.utc(2026, 5, 29, 19, 42);
      final FakeLLMProvider fake = FakeLLMProvider(
        delay: Duration.zero,
        clock: () => fixed,
      );
      final List<DecoderChunk> chunks = await fake
          .generateDecoderScript(
            behavior: Behavior.byId('upset')!,
            triage: triage,
            patient: patient,
            attempt: 1,
          )
          .toList();
      final DecoderChunkDone done = chunks.last as DecoderChunkDone;
      expect(done.result.generatedAt, fixed);
    });

    test('free-text / unknown behavior id falls back gracefully',
        () async {
      final FakeLLMProvider fake = buildFake();
      const Behavior freeform = Behavior(
        id: 'freetext-something-else',
        label: 'Something else',
        glyph: '✍',
      );
      final List<DecoderChunk> chunks = await fake
          .generateDecoderScript(
            behavior: freeform,
            triage: triage,
            patient: patient,
            attempt: 1,
          )
          .toList();
      expect(chunks.last, isA<DecoderChunkDone>());
      final DecoderChunkDone done = chunks.last as DecoderChunkDone;
      expect(done.result.say, isNotEmpty);
      expect(done.result.tweak, isNotEmpty);
      expect(done.result.dontSay, isNotEmpty);
    });
  });

  group('fakeLLMSeeds — coverage of canonical behaviors', () {
    test('exposes a seed for every canonical behavior id', () {
      for (final Behavior b in Behavior.canonical) {
        expect(fakeLLMSeeds.containsKey(b.id), isTrue,
            reason: 'no fake seed for ${b.id}');
      }
    });

    test('every seed has 2–3 say + ≥1 tweak + ≥1 dont_say', () {
      for (final MapEntry<String, DecoderResult> e in fakeLLMSeeds.entries) {
        expect(e.value.say.length, inInclusiveRange(2, 3),
            reason: '${e.key} say count out of range');
        expect(e.value.tweak, isNotEmpty);
        expect(e.value.dontSay, isNotEmpty);
      }
    });

    test('no seed copy contains exclamation marks (BUILD_SPEC.md §3.3)',
        () {
      for (final MapEntry<String, DecoderResult> e in fakeLLMSeeds.entries) {
        final List<String> all = <String>[
          ...e.value.say,
          ...e.value.tweak,
          ...e.value.dontSay,
        ];
        for (final String s in all) {
          expect(s.contains('!'), isFalse,
              reason: '${e.key} contained an exclamation: $s');
        }
      }
    });
  });

  group('FakeLLMProvider — generateActivitySummary (Phase 14.12)', () {
    final List<ActivityEvent> events = <ActivityEvent>[
      ActivityEvent(
        kind: ActivityEventKind.journal,
        summary: 'Sundowning',
        occurredAt: DateTime.utc(2026, 6, 1, 17, 30),
      ),
      ActivityEvent(
        kind: ActivityEventKind.dose,
        summary: 'Gave Donepezil 10 mg',
        occurredAt: DateTime.utc(2026, 6, 1, 19),
      ),
    ];

    test('streams accumulations terminating in the canned summary',
        () async {
      final FakeLLMProvider fake = buildFake();
      final List<String> accumulations = await fake
          .generateActivitySummary(lastNHours: 24, events: events)
          .toList();

      expect(accumulations, isNotEmpty);
      // The last accumulation is the whole canned paragraph.
      expect(accumulations.last, fakeActivitySummary);
    });

    test('accumulations grow monotonically toward the full paragraph',
        () async {
      final FakeLLMProvider fake = buildFake();
      final List<String> accumulations = await fake
          .generateActivitySummary(events: events)
          .toList();

      for (int i = 1; i < accumulations.length; i++) {
        expect(accumulations[i].startsWith(accumulations[i - 1]), isTrue,
            reason: 'accumulation #$i is not a prefix-superset of #${i - 1}');
        expect(accumulations[i].length,
            greaterThan(accumulations[i - 1].length));
      }
    });

    test('the canned recap stays warm and non-clinical', () {
      // Scope guardrail: a recap, never a diagnosis or treatment plan, and
      // the brand voice carries no exclamation marks (BUILD_SPEC.md §3.3).
      expect(fakeActivitySummary, isNot(contains('!')));
      expect(fakeActivitySummary.toLowerCase(), isNot(contains('diagnos')));
      expect(fakeActivitySummary.toLowerCase(), isNot(contains('prescrib')));
      expect(fakeActivitySummary, contains('your loved one'));
    });
  });

  group('ClaudeCLIProvider — generateActivitySummary stub (Phase 14.12)', () {
    test('surfaces a deferred-stub error rather than a silent empty stream',
        () async {
      const ClaudeCLIProvider provider = ClaudeCLIProvider();
      final Stream<String> stream = provider.generateActivitySummary(
        events: const <ActivityEvent>[],
      );
      await expectLater(stream.toList(), throwsUnimplementedError);
    });
  });

  group('ActivityEvent — cache fingerprint (Phase 14.12)', () {
    test('cacheToken is content-stable and UTC-normalized', () {
      final ActivityEvent local = ActivityEvent(
        kind: ActivityEventKind.dose,
        summary: 'Gave Donepezil 10 mg',
        occurredAt: DateTime.utc(2026, 6, 1, 19).toLocal(),
      );
      final ActivityEvent utc = ActivityEvent(
        kind: ActivityEventKind.dose,
        summary: 'Gave Donepezil 10 mg',
        occurredAt: DateTime.utc(2026, 6, 1, 19),
      );
      expect(local.cacheToken, utc.cacheToken);
      expect(local.cacheToken, contains('dose'));
    });
  });

  group('llmProvider riverpod wiring', () {
    test('defaults to FakeLLMProvider under test (USE_FAKE_LLM=true)',
        () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final LLMProvider impl = container.read(llmProvider);
      expect(impl, isA<FakeLLMProvider>());
    });

    test('override hook swaps in a custom impl', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          llmProvider.overrideWithValue(
            FakeLLMProvider(
              delay: Duration.zero,
              clock: () => DateTime.utc(2026, 1, 1),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final LLMProvider impl = container.read(llmProvider);
      final List<DecoderChunk> chunks = await impl
          .generateDecoderScript(
            behavior: Behavior.byId('wants_home')!,
            triage: triage,
            patient: patient,
            attempt: 1,
          )
          .toList();
      expect(chunks.last, isA<DecoderChunkDone>());
    });
  });

  group('ClaudeCLIProvider — user message construction (§7.2)', () {
    test('canonical behavior emits behavior:<label> + verbatim §7.2 lines',
        () {
      final String msg = ClaudeCLIProvider.buildUserMessage(
        behavior: Behavior.byId('accusing')!,
        triage: const TriageAnswers(
          when: TriageWhen.lateAfternoonEvening,
          whatChanged: TriageWhatChanged.nothing,
          whatTried: TriageWhatTried.triedToExplain,
        ),
        patient: const PatientContext(
          stage: 'stage 5 (moderately severe)',
          age: 78,
        ),
        attempt: 1,
      );

      // BUILD_SPEC.md §7.2 — exact field order + line shape.
      expect(
        msg,
        equals(
          'behavior: Accusing me\n'
          'when: late afternoon / evening\n'
          'what_changed: nothing\n'
          'what_tried: tried to explain\n'
          'attempt: 1\n'
          'patient_context: stage 5 (moderately severe), age 78',
        ),
      );
    });

    test('free-text behavior swaps in behavior_freetext:<label>', () {
      const Behavior freeform = Behavior(
        id: 'freetext-something-else',
        label: 'She paces near the front door and won\'t sit',
        glyph: '✍',
      );
      final String msg = ClaudeCLIProvider.buildUserMessage(
        behavior: freeform,
        triage: const TriageAnswers(
          when: TriageWhen.morning,
          whatChanged: TriageWhatChanged.medication,
          whatTried: TriageWhatTried.walkedAway,
        ),
        patient: const PatientContext(
          stage: 'stage 4',
          age: 72,
        ),
        attempt: 2,
      );

      expect(msg.split('\n').first,
          'behavior_freetext: She paces near the front door and won\'t sit');
      expect(msg, contains('\nwhen: morning\n'));
      expect(msg, contains('\nwhat_changed: medication\n'));
      expect(msg, contains('\nwhat_tried: walked away\n'));
      expect(msg, contains('\nattempt: 2\n'));
      expect(msg, endsWith('patient_context: stage 4, age 72'));
    });

    test('every triage enum maps to its §7.1-style lowercase label', () {
      // Sanity-pin: if we ever rename one of these labels the few-shot
      // example in the system prompt diverges and the model's output
      // shape drifts.
      const PatientContext patient = PatientContext(stage: 'S', age: 1);
      const Behavior anyBehavior = Behavior(
          id: 'upset', label: 'Upset / crying', glyph: '💔');

      String fieldFor({TriageWhen? when}) =>
          ClaudeCLIProvider.buildUserMessage(
            behavior: anyBehavior,
            triage: TriageAnswers(when: when),
            patient: patient,
            attempt: 0,
          ).split('\n')[1];

      expect(fieldFor(when: TriageWhen.morning), 'when: morning');
      expect(fieldFor(when: TriageWhen.afternoon), 'when: afternoon');
      expect(fieldFor(when: TriageWhen.lateAfternoonEvening),
          'when: late afternoon / evening');
      expect(fieldFor(when: TriageWhen.night), 'when: night');
      expect(fieldFor(when: TriageWhen.justStarted),
          "when: just started — don't know yet");
    });
  });

  group('ClaudeCLIProvider — SSE streaming', () {
    const TriageAnswers callTriage = TriageAnswers(
      when: TriageWhen.lateAfternoonEvening,
      whatChanged: TriageWhatChanged.nothing,
      whatTried: TriageWhatTried.triedToExplain,
    );
    const PatientContext callPatient = PatientContext(
      stage: 'stage 5 (moderately severe)',
      age: 78,
    );
    final Behavior callBehavior = Behavior.byId('accusing')!;

    test('canned SSE assistant deltas yield partials then done', () async {
      // Split the §7.1 example output across four assistant events
      // so the test exercises the multi-chunk accumulation path.
      const String chunkA = '{"say": ["That sounds really upsetting.';
      const String chunkB = ' I\'m here with you.", "Tell me more."]';
      const String chunkC = ', "tweak": ["Sit at eye level."]';
      const String chunkD = ', "dont_say": ["Do not argue the facts."]}';

      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent(chunkA),
        _assistantEvent(chunkB),
        _assistantEvent(chunkC),
        _assistantEvent(chunkD),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(
        dio: dio,
        clock: () => DateTime.utc(2026, 5, 29, 19, 42),
      );

      final List<DecoderChunk> chunks = await provider
          .generateDecoderScript(
            behavior: callBehavior,
            triage: callTriage,
            patient: callPatient,
            attempt: 1,
          )
          .toList();

      // Four partials (one per assistant event) + one done.
      final List<DecoderChunkPartial> partials =
          chunks.whereType<DecoderChunkPartial>().toList();
      expect(partials, hasLength(4));
      expect(partials[0].accumulatedJson, chunkA);
      expect(partials[1].accumulatedJson, chunkA + chunkB);
      expect(partials[2].accumulatedJson, chunkA + chunkB + chunkC);
      expect(
        partials[3].accumulatedJson,
        chunkA + chunkB + chunkC + chunkD,
      );

      expect(chunks.last, isA<DecoderChunkDone>());
      final DecoderChunkDone done = chunks.last as DecoderChunkDone;
      expect(
        done.result.say,
        equals(<String>[
          "That sounds really upsetting. I'm here with you.",
          'Tell me more.',
        ]),
      );
      expect(done.result.tweak,
          equals(<String>['Sit at eye level.']));
      expect(done.result.dontSay,
          equals(<String>['Do not argue the facts.']));
      expect(done.result.generatedAt, DateTime.utc(2026, 5, 29, 19, 42));
    });

    test('shim POST body carries system prompt + verbatim user message',
        () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent(
            '{"say": ["a", "b"], "tweak": ["c"], "dont_say": ["d"]}'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider =
          ClaudeCLIProvider(dio: dio, clock: () => DateTime.utc(2026));

      await provider
          .generateDecoderScript(
            behavior: callBehavior,
            triage: callTriage,
            patient: callPatient,
            attempt: 1,
          )
          .toList();

      expect(adapter.lastRequest, isNotNull);
      expect(adapter.lastRequest!.uri.toString(),
          claudeShimEndpoint);
      expect(adapter.lastRequest!.method, 'POST');

      final Map<String, dynamic> sent = adapter.lastRequestBody!;
      expect(sent['system'], equals(claudeSystemPrompt));
      expect(
        sent['user'],
        equals(
          'behavior: Accusing me\n'
          'when: late afternoon / evening\n'
          'what_changed: nothing\n'
          'what_tried: tried to explain\n'
          'attempt: 1\n'
          'patient_context: stage 5 (moderately severe), age 78',
        ),
      );
    });

    test('shim error event terminates the stream with DecoderChunk.error',
        () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        'data: ${json.encode(<String, String>{'error': 'claude binary not found on PATH'})}\n\n',
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);

      final List<DecoderChunk> chunks = await provider
          .generateDecoderScript(
            behavior: callBehavior,
            triage: callTriage,
            patient: callPatient,
            attempt: 1,
          )
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.single, isA<DecoderChunkError>());
      final DecoderChunkError err = chunks.single as DecoderChunkError;
      expect(err.message, contains('claude binary not found'));
    });

    test('unparseable final JSON yields DecoderChunk.error', () async {
      // Assistant text never closes the object — final parse must fail.
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        _assistantEvent('{"say": ["a",'),
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);

      final List<DecoderChunk> chunks = await provider
          .generateDecoderScript(
            behavior: callBehavior,
            triage: callTriage,
            patient: callPatient,
            attempt: 1,
          )
          .toList();

      expect(chunks.first, isA<DecoderChunkPartial>());
      expect(chunks.last, isA<DecoderChunkError>());
      final DecoderChunkError err = chunks.last as DecoderChunkError;
      expect(err.message, contains('parse failed'));
    });

    test('empty stream (no assistant events) yields DecoderChunk.error',
        () async {
      final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
        // A system-init event the provider must ignore, then DONE.
        'data: ${json.encode(<String, dynamic>{'type': 'system', 'subtype': 'init'})}\n\n',
        'data: [DONE]\n\n',
      ]);
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);

      final List<DecoderChunk> chunks = await provider
          .generateDecoderScript(
            behavior: callBehavior,
            triage: callTriage,
            patient: callPatient,
            attempt: 1,
          )
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.single, isA<DecoderChunkError>());
      expect(
        (chunks.single as DecoderChunkError).message,
        contains('without emitting any script text'),
      );
    });

    test('transport failure surfaces as DecoderChunk.error', () async {
      final _ThrowingAdapter adapter = _ThrowingAdapter();
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final ClaudeCLIProvider provider = ClaudeCLIProvider(dio: dio);

      final List<DecoderChunk> chunks = await provider
          .generateDecoderScript(
            behavior: callBehavior,
            triage: callTriage,
            patient: callPatient,
            attempt: 1,
          )
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.single, isA<DecoderChunkError>());
      expect(
        (chunks.single as DecoderChunkError).message,
        contains('shim request failed'),
      );
    });

    test(
      'JSON arriving in one assistant event still yields partial + done',
      () async {
        // claude-CLI sometimes emits the whole result in one assistant
        // snapshot; the provider should not require multiple chunks.
        final _CannedSseAdapter adapter = _CannedSseAdapter(<String>[
          _assistantEvent(
              '{"say": ["x", "y"], "tweak": ["z"], "dont_say": ["q"]}'),
          'data: [DONE]\n\n',
        ]);
        final Dio dio = Dio()..httpClientAdapter = adapter;
        final ClaudeCLIProvider provider = ClaudeCLIProvider(
          dio: dio,
          clock: () => DateTime.utc(2026, 6, 1),
        );

        final List<DecoderChunk> chunks = await provider
            .generateDecoderScript(
              behavior: callBehavior,
              triage: callTriage,
              patient: callPatient,
              attempt: 1,
            )
            .toList();

        expect(chunks, hasLength(2));
        expect(chunks.first, isA<DecoderChunkPartial>());
        expect(chunks.last, isA<DecoderChunkDone>());
        final DecoderChunkDone done = chunks.last as DecoderChunkDone;
        expect(done.result.say, equals(<String>['x', 'y']));
        expect(done.result.generatedAt, DateTime.utc(2026, 6, 1));
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Build one SSE `data: ...\n\n` frame for a Claude-Code-style
/// `assistant` event with [text] as the sole text content block.
String _assistantEvent(String text) {
  final Map<String, dynamic> event = <String, dynamic>{
    'type': 'assistant',
    'message': <String, dynamic>{
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': text},
      ],
    },
  };
  return 'data: ${json.encode(event)}\n\n';
}

/// HTTP adapter that returns a canned SSE byte stream and records the
/// request body for assertion. Splits the stream across multiple
/// `Uint8List`s so the provider's `\n\n`-boundary parser exercises the
/// "event split across chunks" code path.
class _CannedSseAdapter implements HttpClientAdapter {
  _CannedSseAdapter(this._events);

  final List<String> _events;
  RequestOptions? lastRequest;
  Map<String, dynamic>? lastRequestBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (options.data is Map) {
      lastRequestBody = Map<String, dynamic>.from(options.data as Map);
    } else if (requestStream != null) {
      final List<int> bytes = <int>[];
      await for (final Uint8List part in requestStream) {
        bytes.addAll(part);
      }
      lastRequestBody = json.decode(utf8.decode(bytes))
          as Map<String, dynamic>;
    }

    final Stream<Uint8List> bodyStream = _emit(_events);
    return ResponseBody(
      bodyStream,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/event-stream'],
      },
    );
  }

  Stream<Uint8List> _emit(List<String> events) async* {
    for (final String e in events) {
      // Split each event in half to force the provider to glue two
      // partial reads into a complete `\n\n`-terminated event.
      final List<int> bytes = utf8.encode(e);
      if (bytes.length < 4) {
        yield Uint8List.fromList(bytes);
        continue;
      }
      final int mid = bytes.length ~/ 2;
      yield Uint8List.fromList(bytes.sublist(0, mid));
      yield Uint8List.fromList(bytes.sublist(mid));
    }
  }

  @override
  void close({bool force = false}) {}
}

/// HTTP adapter that throws on every request — exercises the
/// transport-failure branch.
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return Future<ResponseBody>.error(
      DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'connection refused',
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}
