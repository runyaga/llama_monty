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

Future<void> main(List<String> args) async {
  final verbose = args.contains('--verbose') || args.contains('-v');
  final positional = args.where((a) => !a.startsWith('-')).toList();
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
    stdout.writeln(
      '  baseline: recall=${(base.recall * 100).toStringAsFixed(1)}%  '
      'neg=${(base.negationAcc * 100).toStringAsFixed(1)}%  '
      'calls=${base.llmCalls}  ${base.wallMs}ms',
    );
    if (verbose) {
      stdout.writeln('    --- baseline summary ---');
      for (final l in base.summary.split('\n')) stdout.writeln('    $l');
      stdout.writeln('    --- baseline post-reset reply ---');
      for (final l in base.reply.split('\n')) stdout.writeln('    $l');
    }

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
    stdout.writeln(
      '  v2:       recall=${(v2score.recall * 100).toStringAsFixed(1)}%  '
      'neg=${(v2score.negationAcc * 100).toStringAsFixed(1)}%  '
      'calls=${v2score.llmCalls}  ${v2score.wallMs}ms',
    );
    if (verbose) {
      stdout.writeln('    --- v2 summary ---');
      for (final l in v2score.summary.split('\n')) stdout.writeln('    $l');
      stdout.writeln('    --- v2 post-reset reply ---');
      for (final l in v2score.reply.split('\n')) stdout.writeln('    $l');
    }
  }

  // ---- Aggregate -----------------------------------------------------------
  stdout.writeln('\n=== aggregate ===');
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
