// End-to-end retry loop test: send a prompt, take the model's reply,
// run it in Monty, feed the error back, see if the model fixes it.
//
// Mirrors what _send() does in the web app. Lets us verify whether the
// model is actually LEARNING from the error nudge (and what error
// message it's receiving from Monty).
//
// Run: dart run example/prompt_retry_test.dart

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

const _systemPrompt = '''
You DO have a working filesystem and a working Python interpreter. The
sandbox mounts `/fixtures/` (read-write, pre-seeded) and `/tmp/`
(read-write). NEVER refuse on grounds of "I am an AI without filesystem
access" — read/write the files via pathlib.

You write SMALL Monty programs in ```monty fences.

Monty is a Python 3 SUBSET. ALWAYS:
  print(x)            # print is a FUNCTION, not a statement
  from pathlib import Path
  Path(p).read_text()                  # read a file
  Path(p).write_text("hello")          # write a file
  for p in Path('/tmp').iterdir(): print(p)
NEVER:
  import os           # os module is NOT available — use pathlib
  print x             # Python 2 syntax — REJECTED
  with open(p):       # context managers REJECTED
  class X:            # class keyword REJECTED
  "{:.2f}".format(x)  # .format is REJECTED — use round(x,2)
  "%.2f" % x          # % string formatting REJECTED
Allowed modules: math, re, json, datetime, pathlib.
''';

String? _extractFence(String reply) {
  final m =
      RegExp(r'```(?:monty|python|py)?\s*\n?([\s\S]*?)```').firstMatch(reply);
  return m?.group(1)?.trim();
}

/// Mirrors the web app's pre-flight: catch patterns Monty's parser
/// accepts but the runtime cannot satisfy, so the model gets a hard
/// error instead of a swallowed try/except success.
String? _preflight(String code) {
  if (RegExp(r'(^|\n)\s*import\s+os\b').hasMatch(code) ||
      RegExp(r'(^|\n)\s*from\s+os\b').hasMatch(code)) {
    return 'The `os` module is not available in Monty. Use `pathlib`: '
        '`from pathlib import Path`, then `Path(p).iterdir()` to list a '
        'directory, `Path(p).read_text()` to read a file, '
        '`Path(p).write_text(s)` to write a file.';
  }
  if (RegExp(r'\bwith\s+open\b').hasMatch(code)) {
    return 'Context managers (`with`) are not supported. Use '
        '`Path(p).read_text()` / `Path(p).write_text(s)` instead.';
  }
  if (RegExp(r'(^|\n)\s*print\s+(?!\()').hasMatch(code)) {
    return 'Use `print(x)` (function call). Python 2 syntax is rejected.';
  }
  if (RegExp(r'(^|\n)\s*class\s+\w').hasMatch(code)) {
    return 'The `class` keyword is not supported. Use plain functions.';
  }
  return null;
}

bool _looksLikeSwallowedError(String output) {
  final lower = output.toLowerCase();
  return RegExp(r'\ban error occurred\b').hasMatch(lower) ||
      RegExp(r'\btraceback\b').hasMatch(lower) ||
      RegExp(r'^\s*error\s*:', multiLine: true).hasMatch(lower) ||
      RegExp(r'\b(attribute|name|type|value|key|index|module)error\b')
          .hasMatch(lower) ||
      RegExp(r'\bno module named\b').hasMatch(lower);
}

Future<String> _ask(LlamaEngine engine, List<LlamaChatMessage> msgs) async {
  final buf = StringBuffer();
  await for (final c in engine.create(
    msgs,
    params: const GenerationParams(temp: 1.0, topP: 0.95),
  )) {
    final s = c.choices.firstOrNull?.delta.content;
    if (s != null) buf.write(s);
  }
  return buf.toString();
}

Future<void> main() async {
  stdout.writeln('Loading model …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath,
      modelParams: ModelParams(contextSize: 8192));

  // Same Monty wiring the web app uses.
  final monty = MontyRuntime(os: defaultOsHandler());

  final messages = <LlamaChatMessage>[
    LlamaChatMessage.fromText(role: LlamaChatRole.system, text: _systemPrompt),
    LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'List the files in /tmp.',
    ),
  ];

  for (var attempt = 1; attempt <= 3; attempt++) {
    stdout.writeln('\n========= ATTEMPT $attempt =========');
    final reply = await _ask(engine, messages);
    stdout.writeln('--- model reply ---');
    stdout.writeln(reply);

    final code = _extractFence(reply);
    if (code == null || code.trim().isEmpty) {
      stdout.writeln('(no code in reply, stopping)');
      break;
    }
    stdout.writeln('--- extracted code ---');
    stdout.writeln(code);

    stdout.writeln('--- running in Monty ---');
    String summary;
    bool failed;
    final pre = _preflight(code);
    if (pre != null) {
      summary = 'Error: $pre';
      failed = true;
      stdout.writeln(summary);
    } else {
      final result = await monty.execute(code).result;
      if (result.error != null) {
        summary = 'Error: ${result.error!.message}';
        failed = true;
      } else {
        final out = (result.printOutput ?? '').trim();
        if (_looksLikeSwallowedError(out)) {
          summary = 'Error (swallowed by try/except): $out';
          failed = true;
        } else {
          summary = 'OK output:\n$out';
          failed = false;
        }
      }
      stdout.writeln(summary);
    }

    if (!failed) {
      stdout.writeln('\n✓ Model produced working code on attempt $attempt');
      break;
    }

    // Mimic our web _send retry nudge.
    messages.add(
      LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: reply),
    );
    messages.add(
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Your last Monty program produced an error: $summary\n'
            'Write a corrected program in a ```monty fence. '
            'Do not give the answer in prose.',
      ),
    );
  }

  await monty.dispose();
  await engine.dispose();
}
