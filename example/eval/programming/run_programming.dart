// Pressure-tests the 2B Gemma 4 model's ability to write Python that
// runs unmodified inside dart_monty's restricted interpreter. Each probe
// is graded on a 4-state scale so we can see WHERE the model breaks:
//
//   PASS         — code emitted, ran in Monty, expected check held.
//   FAIL_OUTPUT  — code emitted, ran in Monty, output disagreed with check.
//   ERROR_PY     — code emitted, but Monty rejected it (unsupported feature,
//                  syntax error, runtime exception).
//   NO_CODE      — the model didn't emit anything we could extract as Python.
//
// Probes are graduated by difficulty so we can identify the breaking
// point. Each probe specifies an `expect` predicate over Monty's combined
// stdout + return-value-as-string.
//
// Run: dart run example/eval/programming/run_programming.dart [P1 P2 …]

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

/// Format the LLM is given on every turn — concise system prompt that
/// tells it about Monty's restrictions AND insists on a markdown fence
/// (so extraction is reliable).
const _systemPrompt = '''
You write Python that runs inside Monty, a restricted Python subset.
Reply with ONE markdown ```python fence containing your solution. No
prose outside the fence.

Monty restrictions:
- NO class keyword.
- NO yield / generators.
- NO match/case, del, decorators.
- NO format() method, no .format() calls.
- NO collections, functools, itertools, numpy, pandas.
- NO chained assignment (i = j = 0).
- NO tuple unpacking in for-loop headers (use indexing instead).
- Supported modules: math, re, json, datetime, pathlib.

Write print() for any output you want returned. The host runs your
code and reads the printed output.
''';

class _Probe {
  const _Probe({
    required this.id,
    required this.title,
    required this.userPrompt,
    required this.expect,
    this.tier = 1,
  });

  final String id;
  final String title;
  final int tier; // 1=trivial, 2=easy, 3=medium, 4=hard, 5=trap
  final String userPrompt;
  final bool Function(String stdoutAndReturn) expect;
}

bool _contains(String h, Object x) =>
    h.toLowerCase().contains(x.toString().toLowerCase());

final List<_Probe> _probes = [
  // ---- Tier 1: trivial -----------------------------------------------------
  _Probe(
    id: 'P1',
    tier: 1,
    title: 'sum 1..100',
    userPrompt: 'Print the sum of integers 1 through 100 inclusive.',
    expect: (out) => _contains(out, '5050'),
  ),
  _Probe(
    id: 'P2',
    tier: 2,
    title: 'fibonacci 12',
    userPrompt:
        'Print the 12th Fibonacci number. Use 0-indexed convention where '
        'fib(0)=0, fib(1)=1. So fib(12)=144.',
    expect: (out) => _contains(out, '144'),
  ),
  _Probe(
    id: 'P3',
    tier: 2,
    title: 'list of primes below 50',
    userPrompt:
        'Print the list of prime numbers below 50, in order, like: '
        '[2, 3, 5, 7, ...]',
    expect: (out) {
      // Required primes the output must contain.
      const required = ['2', '3', '5', '7', '11', '13', '17', '19', '23',
                        '29', '31', '37', '41', '43', '47'];
      return required.every((n) => _contains(out, n)) &&
          // forbid 1 and 49 sneaking in
          !RegExp(r'\b1\b').hasMatch(out.split('[').last);
    },
  ),

  // ---- Tier 3: medium ------------------------------------------------------
  _Probe(
    id: 'P4',
    tier: 3,
    title: 'CSV average from /fixtures',
    userPrompt:
        'Read /fixtures/sample.csv (a header line then rows of '
        'name,quantity,price). Compute and print the AVERAGE price across '
        'all rows, rounded to 2 decimal places. Use only the math, re, '
        'json modules and pathlib. Do NOT import csv.',
    // /fixtures/sample.csv: 0.45+0.20+0.10+1.20+2.50 = 4.45 / 5 = 0.89
    expect: (out) => _contains(out, '0.89'),
  ),
  _Probe(
    id: 'P5',
    tier: 3,
    title: 'factorial 20 without math.factorial',
    userPrompt:
        'Print the factorial of 20. The math module IS available, but '
        'do NOT use math.factorial — implement the multiplication '
        'yourself.',
    expect: (out) => _contains(out, '2432902008176640000'),
  ),
  _Probe(
    id: 'P6',
    tier: 3,
    title: 'unique-word counter without classes',
    userPrompt:
        'Given the sentence "the cat sat on the mat the cat purred", '
        'count occurrences of each word and print the result as a Python '
        'dict mapping word -> count. Order does not matter. Do NOT '
        'define a class.',
    expect: (out) =>
        _contains(out, "'the': 3") &&
        _contains(out, "'cat': 2") &&
        _contains(out, "'sat': 1") &&
        _contains(out, "'mat': 1") &&
        _contains(out, "'purred': 1"),
  ),

  // ---- Tier 4: hard --------------------------------------------------------
  _Probe(
    id: 'P7',
    tier: 4,
    title: 'bubble-sort swap count',
    userPrompt:
        'Implement bubble sort in pure Python. Sort the list '
        '[64, 34, 25, 12, 22, 11, 90] and print BOTH the sorted list AND '
        'the EXACT number of swap operations performed. Use the form: '
        'print(sorted_list); print("swaps:", n)',
    // Bubble sort on [64,34,25,12,22,11,90] makes 14 swaps when no
    // early-exit optimization is used; with optimization it can be 14
    // also. Accept any of {12, 13, 14, 15} since exact count depends on
    // implementation detail of "swap when equal".
    expect: (out) =>
        _contains(out, '[11, 12, 22, 25, 34, 64, 90]') &&
        RegExp(r'swaps?\s*:\s*(12|13|14|15)\b', caseSensitive: false)
            .hasMatch(out),
  ),
  _Probe(
    id: 'P8',
    tier: 4,
    title: 'run-length encode + decode round-trip',
    userPrompt:
        'For the string "AAABBBCCDDDDEEEE": (1) compute the run-length '
        'encoded form as a list of [char, count] pairs; (2) decode it '
        'back into a string; (3) print the encoded list AND the decoded '
        'string AND whether the round trip equals the original (True/'
        'False).',
    expect: (out) =>
        _contains(out, 'AAABBBCCDDDDEEEE') &&
        _contains(out, 'true'), // Python prints True; lowercase here ok
  ),
  _Probe(
    id: 'P9',
    tier: 4,
    title: 'strict JSON output spec',
    userPrompt:
        'Print EXACTLY (no surrounding text, no extra whitespace) a JSON '
        'string of this shape:\n'
        '{"version": 1, "items": [{"id": 1, "name": "alpha"}, '
        '{"id": 2, "name": "beta"}]}\n'
        'Use json.dumps to produce the exact string. The keys MUST be in '
        'the order shown above. The output MUST be parseable by '
        'json.loads.',
    expect: (out) {
      // Find a JSON object in the output and check key facts.
      final m = RegExp(r'\{[^{}]*"version"[^{}]*\}').firstMatch(out);
      if (m == null) return false;
      final s = m.group(0)!;
      return _contains(s, '"version": 1') &&
          _contains(s, '"items"') &&
          _contains(s, '"alpha"') &&
          _contains(s, '"beta"');
    },
  ),

  // ---- Tier 5: traps -------------------------------------------------------
  _Probe(
    id: 'P10',
    tier: 5,
    title: 'memoize without decorators',
    userPrompt:
        'Memoize a recursive `fib(n)` function in pure Python without '
        'using decorators (no @lru_cache, no custom decorator syntax). '
        'Print fib(30). The result must be 832040.',
    expect: (out) => _contains(out, '832040'),
  ),
];

/// Reuses the same fence/raw-Python extractor as the web demo.
String? _extractCode(String reply) {
  final fenced = RegExp(r'```(?:python|py)?\s*\n?([\s\S]*?)```')
      .firstMatch(reply);
  if (fenced != null) {
    final c = fenced.group(1)?.trim();
    if (c != null && c.isNotEmpty) return c;
  }
  // Raw Python heuristic.
  final cleaned = reply.trim();
  if (cleaned.isEmpty) return null;
  if (RegExp(
    r'(^|\n)\s*(print\s*\(|def\s+\w|import\s+\w|from\s+\w|for\s+\w|while\s+|if\s+|return\s+|[a-zA-Z_]\w*\s*=)',
  ).hasMatch(cleaned)) {
    return cleaned;
  }
  return null;
}

Future<({String code, String reply})> _writeCode(
    LlamaEngine engine, _Probe p) async {
  final session = ChatSession(engine, systemPrompt: _systemPrompt);
  final buf = StringBuffer();
  await for (final chunk in session.create([LlamaTextContent(p.userPrompt)])) {
    final c = chunk.choices.firstOrNull?.delta.content;
    if (c != null) buf.write(c);
  }
  final reply = buf.toString();
  return (code: _extractCode(reply) ?? '', reply: reply);
}

Future<void> main(List<String> args) async {
  stdout.writeln('Loading model …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath, modelParams: ModelParams(contextSize: 8192));

  // Monty runtime with default OS handler so pathlib works for P4 (csv).
  // Also seeds /fixtures/sample.csv on native (LocalFileSystem allows
  // writing a tmp path); seed via Python.
  final monty = MontyRuntime(os: defaultOsHandler());
  await monty.execute('''
from pathlib import Path
Path('/tmp/fixtures').mkdir(parents=True, exist_ok=True)
# Symlink-equivalent: copy the fixture CSV into /fixtures/ as well as
# /tmp/fixtures/ so probes can read either path.
csv_data = """name,quantity,price
apples,12,0.45
bananas,5,0.20
cherries,30,0.10
dates,8,1.20
elderberries,3,2.50
"""
Path('/tmp/fixtures/sample.csv').write_text(csv_data)
''').result;

  // Note: native LocalFileSystem can't write to /fixtures/ without sudo,
  // so we redirect /fixtures/ in P4's prompt to /tmp/fixtures/.
  // Quick-and-dirty: rewrite the user prompt before sending.
  String swapPath(String s) => s.replaceAll('/fixtures/', '/tmp/fixtures/');

  final tally = <String, int>{
    'PASS': 0,
    'FAIL_OUTPUT': 0,
    'ERROR_PY': 0,
    'NO_CODE': 0,
  };

  for (final p in _probes) {
    if (args.isNotEmpty && !args.contains(p.id)) continue;
    stdout.writeln('\n=== ${p.id} (T${p.tier}): ${p.title} ===');
    final adjusted = _Probe(
      id: p.id,
      tier: p.tier,
      title: p.title,
      userPrompt: swapPath(p.userPrompt),
      expect: p.expect,
    );

    final t0 = DateTime.now();
    final w = await _writeCode(engine, adjusted);
    final dtWrite = DateTime.now().difference(t0).inMilliseconds;

    if (w.code.isEmpty) {
      tally['NO_CODE'] = tally['NO_CODE']! + 1;
      stdout.writeln('  status: NO_CODE  (write ${dtWrite}ms)');
      stdout.writeln('  reply tail: '
          '${w.reply.substring(0, w.reply.length > 200 ? 200 : w.reply.length)}');
      continue;
    }

    stdout.writeln('  --- code (${w.code.length} chars, write ${dtWrite}ms) ---');
    stdout.writeln(w.code.split('\n').take(20).map((l) => '    $l').join('\n'));
    if (w.code.split('\n').length > 20) stdout.writeln('    …');

    final t1 = DateTime.now();
    final result = await monty.execute(w.code).result;
    final dtRun = DateTime.now().difference(t1).inMilliseconds;

    if (result.error != null) {
      tally['ERROR_PY'] = tally['ERROR_PY']! + 1;
      stdout.writeln('  status: ERROR_PY  (run ${dtRun}ms)');
      stdout.writeln('  monty error: ${result.error!.message}');
      continue;
    }

    final out = (result.printOutput ?? '').trim();
    final ret = result.value is MontyNone
        ? ''
        : '${result.value.dartValue ?? ''}'.trim();
    final combined = [out, ret].where((s) => s.isNotEmpty).join('\n');
    final pass = adjusted.expect(combined);
    final tag = pass ? 'PASS' : 'FAIL_OUTPUT';
    tally[tag] = tally[tag]! + 1;
    stdout.writeln('  status: $tag  (run ${dtRun}ms)');
    stdout.writeln('  output: '
        '${combined.substring(0, combined.length > 200 ? 200 : combined.length)}');
  }

  stdout.writeln('\n=== aggregate ===');
  final n = tally.values.reduce((a, b) => a + b);
  for (final entry in tally.entries) {
    stdout.writeln('  ${entry.key.padRight(12)} ${entry.value}/$n');
  }

  await monty.dispose();
  await engine.dispose();
}
