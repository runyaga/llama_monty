// Smoke-tests the multi-step summarization pipeline end-to-end on FFI.
//
// Drives a 16-turn conversation that crosses the oneShotThreshold so the
// full chunked pipeline runs (extract → dedup → render → validate → repair).
// Reports per-stage telemetry (LLM call count, validation issues, fallback)
// so we can see what the pipeline actually did.
//
// Compares the pipeline output against the existing one-shot
// chat_summarize() to spot the difference qualitatively. The fixture-based
// quantitative eval is in example/eval/summarize/.
//
// Run: dart run example/summarize_v2_demo.dart

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

/// Sixteen turns: name + project + location + pet + dietary preference
/// (with a NEGATION) + a numeric fact + a topic switch. Designed to
/// exercise the failure modes the proposal flagged.
const _userTurns = <String>[
  'My name is Alan.',
  'My favorite color is purple.',
  'I am working on a Dart project called llama_monty.',
  'I live in Austin, Texas.',
  'I have a cat named Pixel.',
  'I do NOT eat fish, by the way.',
  'I am 38 years old.',
  'Switching topic — what is the capital of France?',
];

const _outerSystemPrompt =
    'You are a helpful assistant talking with a user. Keep replies concise.';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());
  stdout.writeln('Loading model …');
  await engine.loadModel(_modelPath,
      modelParams: ModelParams(contextSize: 8192));
  stdout.writeln('Loaded.\n');

  final engineRef = LlamaEngineRef(engine);
  final session = ChatSession(engine, systemPrompt: _outerSystemPrompt);

  // ---- Build the chat (no tools, just plain LLM turns) ----------------------
  for (final t in _userTurns) {
    stdout.writeln('USER: $t');
    final buf = StringBuffer();
    await for (final chunk in session.create([LlamaTextContent(t)])) {
      final c = chunk.choices.firstOrNull?.delta.content;
      if (c != null) buf.write(c);
    }
    stdout.writeln('ASSISTANT: ${buf.toString().trim()}\n');
  }

  stdout.writeln('=== history: ${session.history.length} messages ===\n');

  // ---- Baseline one-shot ----------------------------------------------------
  stdout.writeln('--- Baseline one-shot chat_summarize ---');
  final t0 = DateTime.now();
  final oneShot = await ChatSummarizePipeline(engineRef: engineRef)
      .runFromChatSession(session);
  final dt0 = DateTime.now().difference(t0).inMilliseconds;
  stdout.writeln('llmCalls: ${oneShot.llmCalls}, ${dt0}ms');
  stdout.writeln(oneShot.summary);
  stdout.writeln();

  // ---- Pipeline (force pipeline by lowering threshold) ----------------------
  stdout.writeln('--- Multi-step chat_summarize_v2 ---');
  final pipeline = ChatSummarizePipeline(
    engineRef: engineRef,
    oneShotThreshold: 0, // force the full pipeline regardless of history size
  );
  final t1 = DateTime.now();
  final v2 = await pipeline.runFromChatSession(session);
  final dt1 = DateTime.now().difference(t1).inMilliseconds;
  stdout.writeln('llmCalls: ${v2.llmCalls}, '
      'usedFallback: ${v2.usedFallback}, '
      'issues: ${v2.validationIssues}, '
      '${dt1}ms');
  stdout.writeln('--- extracted facts (${v2.facts.length}) ---');
  for (final f in v2.facts) {
    stdout.writeln('  ${f.renderLine()}');
  }
  if (v2.decisions.isNotEmpty) {
    stdout.writeln('--- decisions ---');
    for (final d in v2.decisions) stdout.writeln('  $d');
  }
  if (v2.openQuestions.isNotEmpty) {
    stdout.writeln('--- open questions ---');
    for (final q in v2.openQuestions) stdout.writeln('  $q');
  }
  stdout.writeln('--- final summary ---');
  stdout.writeln(v2.summary);
  stdout.writeln();

  await engine.dispose();
}
