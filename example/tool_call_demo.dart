// Demonstrates native LLM tool-calling:
//   get_datetime — returns current UTC timestamp
//   run_python   — executes Python in a MontyRuntime sandbox
//
// dart run example/tool_call_demo.dart

import 'dart:io';
import 'package:dart_monty/dart_monty.dart';
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final home = Platform.environment['HOME'] ?? '.';
  final engine = LlamaEngine(LlamaBackend());
  stdout.writeln('Loading model…');
  await engine.loadModel('$home/models/gemma-4-E2B-it-Q4_K_M.gguf');
  stdout.writeln('Ready.\n');

  final monty = MontyRuntime();

  final tools = [
    ToolDefinition(
      name: 'get_datetime',
      description:
          'Returns the current UTC date and time as an ISO-8601 string.',
      parameters: [],
      handler: (_) async => DateTime.now().toUtc().toIso8601String(),
    ),
    ToolDefinition(
      name: 'run_python',
      description: 'Executes Python code in a sandbox and returns the result. '
          'Use this for any calculation or data transformation.',
      parameters: [
        ToolParam.string('code',
            description: 'Python code to run.', required: true),
      ],
      handler: (params) async {
        final code = params.getString('code') ?? '';
        if (code.isEmpty) return 'Error: no code provided';
        final r = await monty.execute(code).result;
        if (r.error != null) return 'Error: ${r.error}';
        final out = (r.printOutput ?? '').trim();
        final val =
            r.value is MontyNone ? '' : '${r.value?.dartValue ?? ''}'.trim();
        return [out, val].where((s) => s.isNotEmpty).join('\n');
      },
    ),
  ];

  // One session per turn so history doesn't bleed between examples.
  Future<void> demo(String question) async {
    stdout.writeln('─' * 60);
    stdout.writeln('User:  $question');

    final s = ChatSession(
      engine,
      systemPrompt:
          'You are a helpful assistant. Always use a tool for real-time data '
          'or computation. Never answer from memory for those. '
          'Do not use markdown code fences.',
    );

    await for (final _ in s.create(
      [LlamaTextContent(question)],
      tools: tools,
      toolChoice: ToolChoice.required,
    )) {}

    final lastMsg = s.history.last;
    final calls = lastMsg.parts.whereType<LlamaToolCallContent>().toList();

    if (calls.isEmpty) {
      stdout.writeln('Assistant: ${lastMsg.content}');
      return;
    }

    for (final tc in calls) {
      stdout.writeln('  tool:   ${tc.name}');
      stdout.writeln('  args:   ${tc.arguments}  (raw: ${tc.rawJson})');
      final tool = tools.firstWhere((t) => t.name == tc.name);
      final result = await tool.invoke(tc.arguments.cast<String, dynamic>());
      stdout.writeln('  result: $result');
    }
    stdout.writeln();
  }

  await demo('What is the current UTC time?');
  await demo(
      'Compute 17 factorial using run_python with code="import math; math.factorial(17)"');

  await monty.dispose();
  await engine.dispose();
}
