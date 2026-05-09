// Smoke test for the web _webSystemPrompt against Gemma 4 on FFI.
//
// Sends prompts that previously made the model write the WRONG thing
// (import os, Python-2 print, with-statements, .format()), and prints
// the actual response so we can eyeball whether the new prompt steers
// the model away.
//
// Run: dart run example/prompt_test.dart

import 'dart:io';

import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

// Keep this in sync with example/llama_monty_web/lib/main.dart
// (_webSystemPrompt). Anything we change here must match there.
const _systemPrompt = '''
You DO have a working filesystem and a working Python interpreter. The
sandbox mounts `/fixtures/` (read-write, pre-seeded) and `/tmp/`
(read-write). NEVER refuse on grounds of "I am an AI without filesystem
access" — read/write the files via pathlib.

You write SMALL Monty programs in ```monty fences. Variables and
imports persist across fences, so each turn does one step:

```monty
from pathlib import Path
data = Path('/fixtures/sample.csv').read_text().splitlines()
print(len(data), 'rows; header:', data[0])
```

Read the printed output, then write the NEXT small fence using what
you saw. Don't pack everything into one fence.

Files at /fixtures/: welcome.md, sample.csv (name,quantity,price),
notes.txt.

For verbose work, hand it to a child sandbox — only the child's
final print() bubbles back here:

```monty
h = sandbox_spawn("...code as a string... ; print(answer)")
print(sandbox_await(h))
sandbox_free(h)
```

Children inherit every host function (llm_complete, chat_summarize,
chat_history, etc.) so a child can compress this very chat and
return one line.

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
Also no yield / decorators / del / match-case.
Allowed modules: math, re, json, datetime, pathlib.
Every if/for/while/def header ends with `:`. Use simple f-strings
(no method calls inside braces).
''';

const List<({String tag, String prompt})> _probes = [
  (tag: 'list-tmp', prompt: 'List the files in /tmp.'),
  (
    tag: 'read-csv',
    prompt: 'What\'s the average price in /fixtures/sample.csv?'
  ),
  (
    tag: 'write-file',
    prompt:
        'Write a one-line summary of /fixtures/welcome.md to /tmp/summary.txt.'
  ),
  (
    tag: 'format-num',
    prompt: 'Compute 22 / 7 and print it rounded to 4 decimal places.'
  ),
];

({bool ok, List<String> issues}) _check(String reply) {
  final issues = <String>[];
  if (reply.contains('import os')) issues.add('uses `import os` (forbidden)');
  // Python-2 print: `print "..."` or `print foo` (no paren)
  if (RegExp(r'^\s*print\s+(?!\()', multiLine: true).hasMatch(reply)) {
    issues.add('uses Python-2 `print x` (no parens)');
  }
  if (RegExp(r'\bwith\s+open\b').hasMatch(reply)) {
    issues.add('uses `with open(...)` (forbidden)');
  }
  if (reply.contains('.format(')) issues.add('uses `.format()` (forbidden)');
  if (RegExp(r'"[^"]*"\s*%\s+\w').hasMatch(reply)) {
    issues.add('uses `"…" %` formatting (forbidden)');
  }
  if (RegExp(r'^\s*class\s+\w', multiLine: true).hasMatch(reply)) {
    issues.add('uses `class` (forbidden)');
  }
  if (!reply.contains('```monty') &&
      !reply.contains('```python') &&
      !reply.contains('```py')) {
    issues.add('no markdown fence in reply');
  }
  return (ok: issues.isEmpty, issues: issues);
}

Future<void> main() async {
  stdout.writeln('Loading model …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath,
      modelParams: ModelParams(contextSize: 8192));
  // Gemma 4's recommended sampling.
  final ref = LlamaEngineRef(
    engine,
    defaultParams: const GenerationParams(temp: 1.0, topP: 0.95),
  );

  var passed = 0;
  for (final probe in _probes) {
    stdout.writeln('\n=== ${probe.tag}: ${probe.prompt} ===');
    final reply = await ref.complete([
      LlamaChatMessage.fromText(
          role: LlamaChatRole.system, text: _systemPrompt),
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: probe.prompt),
    ]);
    stdout.writeln('--- reply ---');
    stdout.writeln(reply);
    final c = _check(reply);
    if (c.ok) {
      stdout.writeln('--- PASS ---');
      passed++;
    } else {
      stdout.writeln('--- FAIL ---');
      for (final i in c.issues) stdout.writeln('  • $i');
    }
  }
  stdout.writeln('\n=== aggregate: $passed/${_probes.length} PASS ===');

  await engine.dispose();
}

class LlamaEngineRef {
  LlamaEngineRef(this.engine, {this.defaultParams});
  final LlamaEngine engine;
  final GenerationParams? defaultParams;
  Future<String> complete(List<LlamaChatMessage> messages) async {
    final buf = StringBuffer();
    await for (final c in engine.create(messages, params: defaultParams)) {
      final s = c.choices.firstOrNull?.delta.content;
      if (s != null) buf.write(s);
    }
    return buf.toString();
  }
}
