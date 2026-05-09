// Harness: an outer chat shell whose own assistant decides when to summarize
// and reset itself, using ChatShellPlugin's host functions from inside Monty.
//
// Run:
//   dart run example/summarize_demo.dart
//
// Drives a 4-turn conversation, then asks the assistant to compress + reset
// via run_python. Prints the chat shell's history before, the Python the LLM
// writes, the summary, and the post-reset state.

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

const _outerSystemPrompt = '''
You are a helpful assistant talking with a user. The host can execute Python
that you write via the run_python tool. You also have host functions for
introspecting and managing your own conversation:

- chat_history() -> str
- chat_summarize(style='bullets') -> str
- chat_reset(keep_system_prompt=True, seed=None)

Use them when the user asks to compress, reset, or review the conversation.
Otherwise just chat normally.
''';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());
  stdout.writeln('Loading model from $_modelPath …');
  await engine.loadModel(_modelPath, modelParams: ModelParams(contextSize: 8192));
  stdout.writeln('Loaded.\n');

  final engineRef = LlamaEngineRef(engine);
  final chatSession = ChatSession(engine, systemPrompt: _outerSystemPrompt);

  final agentRuntime = MontyRuntime(
    extensions: [
      LlamaMontyPlugin(engineRef),
      ChatShellPlugin(engineRef: engineRef, shell: () => chatSession),
    ],
  );

  final runPython = ToolDefinition(
    name: 'run_python',
    description: 'Execute Python in Monty. Use chat_history / chat_summarize / '
        'chat_reset host functions to manage the conversation.',
    parameters: [
      ToolParam.string('code', description: 'Python source', required: true),
    ],
    handler: (params) async {
      final code = params.getString('code') ?? '';
      if (code.isEmpty) return 'Error: tool call missing required `code`.';
      stdout
        ..writeln('  ── run_python ──')
        ..writeln(code.split('\n').map((l) => '  | $l').join('\n'))
        ..writeln('  ────────────────');
      final result = await agentRuntime.execute(code).result;
      if (result.error != null) return 'Error: ${result.error!.message}';
      final out = (result.printOutput ?? '').trim();
      final ret = result.value is MontyNone
          ? ''
          : '${result.value.dartValue ?? ''}'.trim();
      return [out, ret].where((s) => s.isNotEmpty).join('\n');
    },
  );

  // ---- helper: send one user turn, drive any tool calls to completion ------
  Future<String> sendTurn(String text) async {
    stdout.writeln('USER: $text');
    var parts = <LlamaContentPart>[LlamaTextContent(text)];
    var retries = 0;
    const maxRetries = 2;
    while (true) {
      String? finishReason;
      await for (final chunk in chatSession.create(parts, tools: [runPython])) {
        finishReason = chunk.choices.firstOrNull?.finishReason ?? finishReason;
      }
      final last = chatSession.history.last;
      final calls = last.parts.whereType<LlamaToolCallContent>().toList();
      if (finishReason == 'tool_calls' && calls.isNotEmpty) {
        var anyError = false;
        for (final tc in calls) {
          final result =
              await runPython.invoke(tc.arguments.cast<String, dynamic>());
          if ('$result'.startsWith('Error:')) anyError = true;
          chatSession.addMessage(
            LlamaChatMessage.withContent(
              role: LlamaChatRole.tool,
              content: [
                LlamaToolResultContent(
                    name: tc.name, result: '$result', id: tc.id),
              ],
            ),
          );
        }
        if (anyError && retries < maxRetries) {
          retries++;
          parts = [
            LlamaTextContent(
              'The previous tool call returned an error. Look at the tool '
              'result, fix the issue (often: include the required `code` '
              'argument with valid Python), and call run_python again.',
            ),
          ];
        } else {
          parts = [];
        }
        continue;
      }
      final replyText = last.parts
          .whereType<LlamaTextContent>()
          .map((p) => p.text)
          .join()
          .trim();
      stdout.writeln('ASSISTANT: $replyText\n');
      return replyText;
    }
  }

  // ---- Phase 1: build up a real conversation -------------------------------
  await sendTurn('My name is Alan. My favorite color is purple.');
  await sendTurn('I am working on a project called llama_monty.');
  await sendTurn('I live in Texas.');
  await sendTurn('I have a cat named Pixel.');

  stdout.writeln('--- Outer chat history (${chatSession.history.length} msgs) ---');
  stdout.writeln(_renderHistory(chatSession));
  stdout.writeln('---------------------------------------------\n');

  // ---- Phase 2: drive summarize + reset directly via Monty -----------------
  // (The LLM CAN call these from inside run_python — see the system prompt
  //  and the example llama_monty_web app — but small models often emit
  //  malformed tool calls. To keep the harness deterministic we exercise the
  //  host functions from a hand-written Python snippet.)
  stdout.writeln('--- Phase 2: chat_summarize + chat_reset via Monty ---');
  const compressScript = '''
summary = chat_summarize(style='3 short bullets')
print('--- summary ---')
print(summary)
print('---------------')
chat_reset(keep_system_prompt=True, seed='Earlier in this conversation: ' + summary)
print('chat reset; new history length =', len(chat_history_messages()))
''';
  final compressResult = await agentRuntime.execute(compressScript).result;
  if (compressResult.error != null) {
    stdout.writeln('compress failed: ${compressResult.error!.message}');
  } else {
    stdout.write(compressResult.printOutput ?? '');
  }
  stdout.writeln();

  stdout.writeln(
      '--- Outer chat history AFTER reset (${chatSession.history.length} msgs) ---');
  stdout.writeln(_renderHistory(chatSession));
  stdout.writeln('--------------------------------------------------------\n');

  // ---- Phase 3: confirm the new turn carries the seeded context -----------
  await sendTurn('What do you remember about me?');

  await agentRuntime.dispose();
  await engine.dispose();
}

String _renderHistory(ChatSession s) {
  final out = StringBuffer();
  for (final m in s.history) {
    final text = m.parts
        .whereType<LlamaTextContent>()
        .map((p) => p.text)
        .join()
        .trim();
    if (text.isEmpty) continue;
    out.writeln('  [${m.role.name}] $text');
  }
  return out.toString().trimRight();
}
