// Scores summarization strategies against the F1–F10 fixture set.
//
// For each fixture:
//   1. Replay the turns into a fresh ChatSession.
//   2. Run BASELINE: ChatSummarizePipeline.runFromChatSession in one-shot
//      mode (oneShotThreshold = infinity).
//   3. Run V2: full pipeline (oneShotThreshold = 0 — force chunking).
//   4. For each strategy: chat_reset(seed=summary) + ask "List everything
//      you know about the user" and score the reply against the
//      ground-truth fact table.
//
// Metrics per strategy per fixture:
//   - recall:           % of ground-truth facts whose subject AND object
//                       both appear in the reply (case-insensitive).
//   - negation_acc:     % of negate facts that retained negation in the
//                       reply (negation token within ±60 chars of subject).
//   - llm_calls:        engineRef.complete() count for the summarize step.
//   - wall_ms:          wall clock for the summarize step.
//
// Run: dart run example/eval/summarize/run_eval.dart [fixture_glob]
//
// Optional positional arg restricts to fixtures whose filename matches
// the glob substring (e.g. "F8" runs only the negations fixture).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show sqrt;

import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';
const _fixturesDir = 'example/eval/summarize/fixtures';

class Fact {
  Fact({
    required this.subject,
    required this.predicate,
    required this.object,
    required this.polarity,
  });
  factory Fact.fromJson(Map<String, dynamic> j) => Fact(
        subject: j['subject'] as String,
        predicate: j['predicate'] as String? ?? '',
        object: j['object'] as String? ?? '',
        polarity: j['polarity'] as String? ?? 'affirm',
      );

  final String subject;
  final String predicate;
  final String object;
  final String polarity;
}

class FixtureScore {
  FixtureScore({
    required this.strategy,
    required this.fixture,
    required this.recall,
    required this.negationAcc,
    required this.llmCalls,
    required this.wallMs,
    required this.summary,
    required this.reply,
  });
  final String strategy;
  final String fixture;
  final double recall;
  final double negationAcc;
  final int llmCalls;
  final int wallMs;
  final String summary;
  final String reply;
}

bool _present(String hay, String needle) {
  if (needle.trim().isEmpty) return true;
  return hay.toLowerCase().contains(needle.toLowerCase());
}

bool _negationNear(String hay, String subject) {
  final h = hay.toLowerCase();
  final s = subject.toLowerCase();
  final idx = h.indexOf(s);
  if (idx == -1) return false;
  final win = h.substring(
    (idx - 60).clamp(0, h.length),
    (idx + s.length + 60).clamp(0, h.length),
  );
  return RegExp(r"\b(not|no|never|n'?t|without|cannot|can't|against)\b")
      .hasMatch(win);
}

({double recall, double negationAcc}) _score(
  List<Fact> facts,
  String reply,
) {
  if (facts.isEmpty) return (recall: 1.0, negationAcc: 1.0);
  var hits = 0;
  var negTotal = 0;
  var negHits = 0;
  for (final f in facts) {
    final subjOk = _present(reply, f.subject);
    final objOk = f.object.isEmpty ? true : _present(reply, f.object);
    if (subjOk && objOk) hits++;
    if (f.polarity == 'negate') {
      negTotal++;
      if (subjOk && _negationNear(reply, f.subject)) negHits++;
    }
  }
  return (
    recall: hits / facts.length,
    negationAcc: negTotal == 0 ? 1.0 : negHits / negTotal,
  );
}

Future<void> _replayInto(
  ChatSession session,
  List<dynamic> turns,
) async {
  for (final t in turns) {
    final m = t as Map<String, dynamic>;
    if ((m['role'] as String) != 'user') continue;
    // Drive the engine so the assistant turn matches the LLM the
    // strategies will see, not the ground-truth assistant text.
    final content = m['content'] as String;
    final stream = session.create([LlamaTextContent(content)]);
    await for (final _ in stream) {/* drain */}
  }
}

Future<String> _ask(LlamaEngine engine, ChatSession session, String q) async {
  final buf = StringBuffer();
  await for (final chunk in session.create([LlamaTextContent(q)])) {
    final c = chunk.choices.firstOrNull?.delta.content;
    if (c != null) buf.write(c);
  }
  return buf.toString().trim();
}

Future<FixtureScore> _runStrategy({
  required String strategy,
  required String fixtureName,
  required LlamaEngine engine,
  required LlamaEngineRef ref,
  required String systemPrompt,
  required List<dynamic> turns,
  required List<Fact> facts,
  required Future<SummaryResult> Function(ChatSession s) doSummarize,
}) async {
  final session = ChatSession(engine, systemPrompt: systemPrompt);
  await _replayInto(session, turns);

  final t0 = DateTime.now();
  final res = await doSummarize(session);
  final wallMs = DateTime.now().difference(t0).inMilliseconds;

  // Apply: reset + seed.
  session.reset(keepSystemPrompt: true);
  session.addMessage(LlamaChatMessage.fromText(
    role: LlamaChatRole.assistant,
    text: 'Earlier in this conversation: ${res.summary}',
  ));
  final reply =
      await _ask(engine, session, 'List everything you know about the user.');

  final s = _score(facts, reply);
  return FixtureScore(
    strategy: strategy,
    fixture: fixtureName,
    recall: s.recall,
    negationAcc: s.negationAcc,
    llmCalls: res.llmCalls,
    wallMs: wallMs,
    summary: res.summary,
    reply: reply,
  );
}

/// Computes mean and population stdev (over a small N) of [xs].
({double mean, double stdev, double min, double max}) _stats(List<double> xs) {
  if (xs.isEmpty) return (mean: 0, stdev: 0, min: 0, max: 0);
  final mean = xs.reduce((a, b) => a + b) / xs.length;
  final variance = xs.fold<double>(0, (a, x) => a + (x - mean) * (x - mean)) /
      xs.length;
  final stdev = variance > 0 ? sqrt(variance) : 0.0;
  return (
    mean: mean,
    stdev: stdev,
    min: xs.reduce((a, b) => a < b ? a : b),
    max: xs.reduce((a, b) => a > b ? a : b),
  );
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

Future<void> main(List<String> args) async {
  final verbose = args.contains('--verbose') || args.contains('-v');
  final positional = args.where((a) => !a.startsWith('-')).toList();
  // Optional `--runs N` (default 1). Each fixture × strategy is summarized
  // N times so we can report mean ± stdev and stop ranking from a single
  // noisy sample at temp=1.0.
  var runs = 1;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--runs' && i + 1 < args.length) {
      runs = int.tryParse(args[i + 1]) ?? 1;
    } else if (args[i].startsWith('--runs=')) {
      runs = int.tryParse(args[i].substring('--runs='.length)) ?? 1;
    }
  }
  final glob = positional.isEmpty ? '' : positional.first;

  final dir = Directory(_fixturesDir);
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .where((f) => glob.isEmpty || f.path.contains(glob))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    stdout.writeln('No fixtures matched (glob="$glob") under $_fixturesDir');
    exit(2);
  }

  stdout.writeln('Loading model …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath, modelParams: ModelParams(contextSize: 8192));
  // Google's recommended sampling for Gemma 4: temp=1.0, top_p=0.95.
  final ref = LlamaEngineRef(
    engine,
    defaultParams: const GenerationParams(temp: 1.0, topP: 0.95),
  );

  // Two pipeline configs — same code, different threshold.
  final baseline = ChatSummarizePipeline(engineRef: ref, oneShotThreshold: 999);
  final v2 = ChatSummarizePipeline(engineRef: ref, oneShotThreshold: 0);

  stdout.writeln('Configuration: runs=$runs, sampling=temp=1.0/topP=0.95');

  // perFixture[fixtureName][strategy] = list of FixtureScore over N runs.
  final perFixture = <String, Map<String, List<FixtureScore>>>{};
  final scores = <FixtureScore>[];
  for (final f in files) {
    final fixture = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final name = fixture['name'] as String? ?? f.path;
    final systemPrompt =
        fixture['system_prompt'] as String? ?? 'You are a helpful assistant.';
    final turns = fixture['turns'] as List<dynamic>;
    final facts = (fixture['facts'] as List<dynamic>)
        .map((e) => Fact.fromJson(e as Map<String, dynamic>))
        .toList();

    stdout.writeln('\n=== $name ===');
    perFixture[name] = {'baseline': [], 'v2': []};

    for (var run = 0; run < runs; run++) {
      final base = await _runStrategy(
        strategy: 'baseline',
        fixtureName: name,
        engine: engine,
        ref: ref,
        systemPrompt: systemPrompt,
        turns: turns,
        facts: facts,
        doSummarize: (s) => baseline.runFromChatSession(s),
      );
      scores.add(base);
      perFixture[name]!['baseline']!.add(base);
      stdout.writeln(
        '  [run ${run + 1}/$runs] baseline: recall=${_pct(base.recall)}  '
        'neg=${_pct(base.negationAcc)}  '
        'calls=${base.llmCalls}  ${base.wallMs}ms',
      );

      final v2score = await _runStrategy(
        strategy: 'v2',
        fixtureName: name,
        engine: engine,
        ref: ref,
        systemPrompt: systemPrompt,
        turns: turns,
        facts: facts,
        doSummarize: (s) => v2.runFromChatSession(s),
      );
      scores.add(v2score);
      perFixture[name]!['v2']!.add(v2score);
      stdout.writeln(
        '  [run ${run + 1}/$runs] v2:       recall=${_pct(v2score.recall)}  '
        'neg=${_pct(v2score.negationAcc)}  '
        'calls=${v2score.llmCalls}  ${v2score.wallMs}ms',
      );
    }

    if (runs > 1) {
      // Per-fixture stats summary line.
      for (final strat in ['baseline', 'v2']) {
        final s = perFixture[name]![strat]!;
        final r = _stats(s.map((x) => x.recall).toList());
        final n = _stats(s.map((x) => x.negationAcc).toList());
        stdout.writeln(
          '  ─ $strat × $runs: recall μ=${_pct(r.mean)} σ=${_pct(r.stdev)} '
          'min=${_pct(r.min)} max=${_pct(r.max)}  '
          'neg μ=${_pct(n.mean)} σ=${_pct(n.stdev)}',
        );
      }
    }

    if (verbose && runs == 1) {
      // Verbose output is per-run; only useful with --runs=1.
      for (final s in perFixture[name]!.values.expand((x) => x)) {
        stdout.writeln('    --- ${s.strategy} summary ---');
        for (final l in s.summary.split('\n')) stdout.writeln('    $l');
        stdout.writeln('    --- ${s.strategy} post-reset reply ---');
        for (final l in s.reply.split('\n')) stdout.writeln('    $l');
      }
    }
  }

  // ---- Aggregate -----------------------------------------------------------
  if (runs > 1) {
    stdout.writeln('\n=== aggregate (mean of per-fixture means) ===');
    for (final strat in ['baseline', 'v2']) {
      // Per-fixture mean recall (each fixture contributes one number),
      // then mean / stdev across fixtures.
      final perFxRecall = perFixture.values
          .map((m) =>
              m[strat]!.map((s) => s.recall).reduce((a, b) => a + b) /
              m[strat]!.length)
          .toList();
      final perFxNeg = perFixture.values
          .map((m) =>
              m[strat]!.map((s) => s.negationAcc).reduce((a, b) => a + b) /
              m[strat]!.length)
          .toList();
      final r = _stats(perFxRecall);
      final n = _stats(perFxNeg);
      // Total cost is just the sum.
      final calls = perFixture.values
          .expand((m) => m[strat]!)
          .map((s) => s.llmCalls)
          .fold<int>(0, (a, b) => a + b);
      final ms = perFixture.values
          .expand((m) => m[strat]!)
          .map((s) => s.wallMs)
          .fold<int>(0, (a, b) => a + b);
      stdout.writeln(
        '  $strat:  recall μ=${_pct(r.mean)} σ=${_pct(r.stdev)}  '
        'neg μ=${_pct(n.mean)} σ=${_pct(n.stdev)}  '
        'calls=$calls  ${ms}ms',
      );
    }
  }

  stdout.writeln('\n=== aggregate (raw across all runs) ===');
  for (final strat in ['baseline', 'v2']) {
    final s = scores.where((x) => x.strategy == strat).toList();
    final recall = s.map((x) => x.recall).reduce((a, b) => a + b) / s.length;
    final neg = s.map((x) => x.negationAcc).reduce((a, b) => a + b) / s.length;
    final calls = s.map((x) => x.llmCalls).reduce((a, b) => a + b);
    final ms = s.map((x) => x.wallMs).reduce((a, b) => a + b);
    stdout.writeln(
      '  $strat: recall=${(recall * 100).toStringAsFixed(1)}%  '
      'neg=${(neg * 100).toStringAsFixed(1)}%  '
      'calls=$calls  ${ms}ms',
    );
  }

  await engine.dispose();
}
