// Scores grounded-QA fixtures against the FFI Gemma 4 model.
//
// Each fixture has:
//   - context           — passage(s) the model must use as ground truth.
//   - question          — what to answer.
//   - gold_must_contain — substrings that MUST appear in the reply
//                         (case-insensitive).
//   - gold_must_not_contain — substrings that MUST NOT appear.
//
// Scoring:
//   PASS  — every must_contain matched AND no must_not_contain matched.
//   FAIL  — at least one criterion failed.
//
// For G2 (refuse-when-out-of-scope) the must_contain list contains
// alternatives ("don't know", "not", "no") and we accept ANY of them
// as evidence of refusal — adjust the harness if you need stricter
// language.
//
// Run: dart run example/eval/grounded/run_grounded.dart [glob]

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';
const _fixturesDir = 'example/eval/grounded/fixtures';

class _Fixture {
  _Fixture({
    required this.name,
    required this.systemPrompt,
    required this.context,
    required this.question,
    required this.mustContain,
    required this.mustNotContain,
    required this.category,
    required this.refuseSemantics,
  });

  final String name;
  final String systemPrompt;
  final String context;
  final String question;
  final List<String> mustContain;
  final List<String> mustNotContain;
  final String category;

  /// True for fixtures where any one of `mustContain` is sufficient
  /// (refuse-OOB style — "I don't know" OR "not" OR "no" all count).
  /// Default is "all of mustContain must match".
  final bool refuseSemantics;
}

_Fixture _parseFixture(File f) {
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return _Fixture(
    name: j['name'] as String,
    systemPrompt: j['system_prompt'] as String,
    context: j['context'] as String,
    question: j['question'] as String,
    mustContain: (j['gold_must_contain'] as List).cast<String>(),
    mustNotContain: (j['gold_must_not_contain'] as List? ?? []).cast<String>(),
    category: j['category'] as String? ?? 'unknown',
    refuseSemantics: (j['category'] == 'refuse_oob'),
  );
}

({bool pass, List<String> missed, List<String> contraband}) _score(
  _Fixture fx,
  String reply,
) {
  final r = reply.toLowerCase();
  final missed = <String>[];
  if (fx.refuseSemantics) {
    // Refuse-style: ANY must_contain match counts as a pass on the
    // contains side.
    final any = fx.mustContain.any((s) => r.contains(s.toLowerCase()));
    if (!any) missed.add('(none of: ${fx.mustContain.join(' | ')})');
  } else {
    for (final s in fx.mustContain) {
      if (!r.contains(s.toLowerCase())) missed.add(s);
    }
  }
  final contraband = <String>[];
  for (final s in fx.mustNotContain) {
    if (r.contains(s.toLowerCase())) contraband.add(s);
  }
  return (
    pass: missed.isEmpty && contraband.isEmpty,
    missed: missed,
    contraband: contraband,
  );
}

Future<String> _ask(LlamaEngine engine, _Fixture fx) async {
  final session = ChatSession(engine, systemPrompt: fx.systemPrompt);
  final user = 'CONTEXT:\n${fx.context}\n\nQUESTION: ${fx.question}';
  final buf = StringBuffer();
  await for (final chunk in session.create([LlamaTextContent(user)])) {
    final c = chunk.choices.firstOrNull?.delta.content;
    if (c != null) buf.write(c);
  }
  return buf.toString().trim();
}

Future<void> main(List<String> args) async {
  final glob = args.isEmpty ? '' : args.first;
  final dir = Directory(_fixturesDir);
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      // Skip the specialty template — it has TODO placeholders.
      .where((f) => !f.path.contains('G6_specialty_template'))
      .where((f) => glob.isEmpty || f.path.contains(glob))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    stdout.writeln('No fixtures matched.');
    exit(2);
  }

  stdout.writeln('Loading model …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath,
      modelParams: ModelParams(contextSize: 8192));

  var pass = 0;
  var fail = 0;
  for (final f in files) {
    final fx = _parseFixture(f);
    stdout.writeln('\n=== ${fx.name} (${fx.category}) ===');
    final t0 = DateTime.now();
    final reply = await _ask(engine, fx);
    final dt = DateTime.now().difference(t0).inMilliseconds;
    final s = _score(fx, reply);
    if (s.pass) {
      pass++;
    } else {
      fail++;
    }
    stdout.writeln('  reply (${dt}ms, ${reply.length} chars):');
    final preview = reply.length > 400 ? '${reply.substring(0, 400)}…' : reply;
    stdout.writeln(preview.split('\n').map((l) => '    $l').join('\n'));
    stdout.writeln('  result: ${s.pass ? 'PASS' : 'FAIL'}');
    if (s.missed.isNotEmpty) stdout.writeln('    missed:    ${s.missed}');
    if (s.contraband.isNotEmpty)
      stdout.writeln('    contraband: ${s.contraband}');
  }

  stdout.writeln('\n=== aggregate ===');
  final n = pass + fail;
  stdout.writeln('  $pass/$n PASS, $fail FAIL');

  await engine.dispose();
}
