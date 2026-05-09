// ignore: dangling_library_doc_comments
/// Native runner — loads a GGUF model and exercises LlamaMontyPlugin via dart_monty.
///
/// Usage:
///   dart run example/native_runner.dart [path/to/model.gguf] [prompt]
///
/// Defaults:
///   model  ~/models/gemma-4-E2B-it-Q4_K_M.gguf
///   prompt "Say hello in one sentence."

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'] ?? '.';
  final modelPath =
      args.isNotEmpty ? args[0] : '$home/models/gemma-4-E2B-it-Q4_K_M.gguf';
  final prompt = args.length > 1 ? args[1] : 'Say hello in one sentence.';

  if (!File(modelPath).existsSync()) {
    stderr.writeln('Model file not found: $modelPath');
    stderr.writeln('Download it with:');
    stderr.writeln(
      '  curl -L https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf -o \$HOME/models/gemma-4-E2B-it-Q4_K_M.gguf',
    );
    exit(1);
  }

  stdout.writeln('Loading model: $modelPath');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(modelPath);
  stdout.writeln('Model loaded.\n');

  final ref = LlamaEngineRef(engine);
  final plugin = LlamaMontyPlugin(ref);
  final session = MontyRuntime(extensions: [plugin]);

  final escapedPrompt = prompt.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
  final code = "result = llm_complete('$escapedPrompt')\nresult";
  stdout.writeln('Prompt: $prompt\n');

  final result = await session.execute(code).result;

  if (result.error != null) {
    stderr.writeln('Error: ${result.error}');
  } else {
    stdout.writeln('--- Response ---');
    final text = switch (result.value) {
      MontyString(:final value) => value,
      _ => result.value.toString(),
    };
    stdout.writeln(text);
  }

  await session.dispose();
  await engine.dispose();
}
