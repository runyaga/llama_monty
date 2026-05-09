// Three adversarial capability probes for the 2B Gemma 4 model, recast as
// multiple-choice so auto-scoring is deterministic. Each probe asks the
// model to reason and END with "Answer: X" where X ∈ {A,B,C,D}. The
// harness extracts the letter and prints PASS / FAIL.
//
// Run: dart run example/eval/capability/run_capability.dart [T1 T2 T3 …]

import 'dart:io';

import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

class _Probe {
  const _Probe({
    required this.id,
    required this.title,
    required this.systemPrompt,
    required this.userPrompt,
    required this.correct,
  });

  final String id;
  final String title;
  final String systemPrompt;
  final String userPrompt;

  /// Single uppercase letter A/B/C/D — the correct answer.
  final String correct;
}

const _systemBoilerplate =
    'Reason carefully step by step. End your reply with a single line in '
    'the exact format: "Answer: X" where X is one of A, B, C, or D. No '
    'additional letters, no other format on that final line.';

final List<_Probe> _probes = [
  // ---------------------------------------------------------------------------
  // T1 — Boolean truth table: a single row's value, multiple choice.
  // ---------------------------------------------------------------------------
  _Probe(
    id: 'T1',
    title: 'Boolean truth-table — single row evaluation',
    systemPrompt: 'You are a formal logic analyzer. $_systemBoilerplate',
    userPrompt: '''
Given the boolean expression:

  F(P,Q,R,S) = ((P AND NOT Q) OR (R XOR S)) IMPLIES (P EQUIV S)

Evaluate F when P=True, Q=False, R=True, S=False.

A. True
B. False
C. Undefined
D. Both True and False
''',
    correct: 'B',
  ),
  // ---------------------------------------------------------------------------
  // T2 — Agentic state-machine routing: final state of Document B.
  // ---------------------------------------------------------------------------
  _Probe(
    id: 'T2',
    title: 'Agentic state-machine routing',
    systemPrompt:
        'Execute the rule logic precisely without skipping steps. '
        '$_systemBoilerplate',
    userPrompt: '''
A document processing system has 4 states: Raw, Chunked, Embedded, Agent_Review.

Rule 1: A document moves from Raw to Chunked if it has > 100 pages OR contains WASM binary code.
Rule 2: From Chunked, a document moves to Embedded UNLESS it contains FFI bindings, in which case it goes directly to Agent_Review.
Rule 3: From Embedded, a document returns to Raw if its token count exceeds 8k; otherwise it proceeds to Agent_Review.
Rule 4: At Agent_Review, the document is Approved if it arrived from Embedded, or Rejected if it arrived from Chunked.

Document B: 50 pages, contains WASM, no FFI, 10k tokens.

Trace Document B's path. Considering Rules 1–4 only (no other rules), what is the immediate next state after Document B's first time in Embedded?

A. Agent_Review (Approved)
B. Agent_Review (Rejected)
C. Raw
D. Chunked
''',
    correct: 'C',
  ),
  // ---------------------------------------------------------------------------
  // T3 — Self-correction: Dart Macros status.
  // ---------------------------------------------------------------------------
  _Probe(
    id: 'T3',
    title: 'Dart Macros — current status',
    systemPrompt: 'You are a careful Dart engineer. $_systemBoilerplate',
    userPrompt: '''
What is the current status (as of late 2025) of "static metaprogramming macros" as a built-in Dart language feature, originally proposed for compile-time code generation?

A. Released and stable since Dart 3.0; commonly used for serialization.
B. Officially canceled / withdrawn by the Dart team — code generation is done via external tools like build_runner + json_serializable instead.
C. Still in private alpha; only available behind a hidden flag.
D. Replaced by C-FFI which provides equivalent functionality.
''',
    correct: 'B',
  ),
];

/// Extract the FIRST 'Answer: X' style declaration. Tolerates surrounding
/// markdown / parentheses / whitespace, plus the common '**Answer: B**' bold.
String? _extractAnswer(String reply) {
  final m = RegExp(
          r'answer\s*[:\-=]\s*\**\s*\(?\s*([A-D])\b',
          caseSensitive: false)
      .firstMatch(reply);
  return m?.group(1)?.toUpperCase();
}

Future<String> _ask(LlamaEngine engine, _Probe p) async {
  final session = ChatSession(engine, systemPrompt: p.systemPrompt);
  final buf = StringBuffer();
  await for (final chunk in session.create([LlamaTextContent(p.userPrompt)])) {
    final c = chunk.choices.firstOrNull?.delta.content;
    if (c != null) buf.write(c);
  }
  return buf.toString().trim();
}

Future<void> main(List<String> args) async {
  stdout.writeln('Loading model …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath, modelParams: ModelParams(contextSize: 8192));

  var passed = 0;
  var failed = 0;
  var unparsable = 0;
  for (final p in _probes) {
    if (args.isNotEmpty && !args.contains(p.id)) continue;
    stdout.writeln('\n=== ${p.id}: ${p.title} ===');
    final t0 = DateTime.now();
    final reply = await _ask(engine, p);
    final dt = DateTime.now().difference(t0).inMilliseconds;
    final picked = _extractAnswer(reply);
    final tag = picked == null
        ? 'UNPARSABLE'
        : picked == p.correct
            ? 'PASS'
            : 'FAIL';
    if (tag == 'PASS') passed++;
    else if (tag == 'FAIL') failed++;
    else unparsable++;

    // Print just the last 600 chars of the reply so we see the answer +
    // the immediately preceding reasoning, not the whole essay.
    final tail =
        reply.length > 600 ? '…${reply.substring(reply.length - 600)}' : reply;
    stdout.writeln('--- reply tail (${dt}ms, ${reply.length} chars total) ---');
    stdout.writeln(tail);
    stdout.writeln('--- result ---');
    stdout.writeln('  picked: ${picked ?? '(none)'}    correct: ${p.correct}'
        '    [$tag]');
  }

  stdout.writeln('\n=== aggregate ===');
  final total = passed + failed + unparsable;
  stdout.writeln('  $passed/$total PASS,  $failed FAIL,  $unparsable UNPARSABLE');

  await engine.dispose();
}
