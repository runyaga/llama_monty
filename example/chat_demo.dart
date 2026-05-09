import 'dart:io';
import 'package:dart_monty/dart_monty.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final home = Platform.environment['HOME'] ?? '.';
  final engine = LlamaEngine(LlamaBackend());
  stdout.writeln('Loading model...');
  await engine.loadModel('$home/models/gemma-4-E2B-it-Q4_K_M.gguf');
  stdout.writeln('Ready.\n');

  final ref = LlamaEngineRef(engine);
  final session = MontyRuntime(extensions: [LlamaMontyPlugin(ref)]);

  Future<void> run(String label, String code) async {
    stdout.writeln('>>> $label');
    final r = await session.execute(code).result;
    if (r.error != null) {
      stdout.writeln('ERROR: ${r.error}');
    } else {
      if (r.printOutput?.isNotEmpty == true) stdout.write(r.printOutput);
      final val = r.value is MontyString
          ? (r.value as MontyString).value
          : '${r.value}';
      if (val.isNotEmpty && val != 'None') stdout.writeln(val);
    }
    stdout.writeln();
  }

  // stateless
  await run(
    'llm_complete — stateless',
    "llm_complete('What is 7 × 6? One number only.')",
  );

  // chat turn 1 — plant a fact
  await run(
    'llm_chat turn 1 — plant a fact',
    "llm_chat('My secret codeword is XYZZY. Just reply: OK.')",
  );

  // chat turn 2 — should recall
  await run(
    'llm_chat turn 2 — recall fact',
    "llm_chat('What is my secret codeword? One word.')",
  );

  // reset
  await run(
    'llm_chat_reset — wipe history',
    'llm_chat_reset(keep_system_prompt=False)',
  );

  // turn 3 — should NOT know
  await run(
    'llm_chat turn 3 — after reset',
    "llm_chat('What is my secret codeword? Say you do not know if unsure.')",
  );

  await session.dispose();
  await engine.dispose();
}
