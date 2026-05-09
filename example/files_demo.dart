// End-to-end "LLM does work with files" demo.
//
// Wires the same OS handler and same seed-fixture pattern the web app
// uses, runs three tasks that exercise pathlib through Monty:
//
//   1. List /fixtures.
//   2. Read welcome.md and report its first sentence.
//   3. Compute the average price across /fixtures/sample.csv.
//
// For each task the LLM writes Python in a markdown fence, the fence
// extractor pulls the code, Monty executes it against the seeded
// MemoryFileSystem-equivalent (LocalFileSystem on FFI, scoped to
// /tmp/llama_monty_files/), and stdout shows the actual file content
// plus the model's computed answer.
//
// On a parse failure (the 2B model occasionally drops a colon) we
// surface Monty's own syntax error back to the LLM so it can fix the
// code and try again — exactly what the user meant by "we have
// typecheck that can run." Up to 2 retries.
//
// Run: dart run example/files_demo.dart

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

const _fixtureRoot = '/tmp/llama_monty_files/fixtures';

const _systemPrompt = '''
You write Python that runs inside Monty (a restricted Python subset).
Reply with ONE markdown ```python fence — no prose outside the fence.

Use pathlib for file access: `from pathlib import Path`.

Monty restrictions:
- NO class, decorators, yield, with-statements (context managers).
- NO format() method, NO collections / itertools / pandas.
- Use try/finally instead of `with` for file I/O.
- Path('...').read_text() / write_text() / iterdir() / exists() all work.
- Supported modules: math, re, json, datetime, pathlib.

Use print(...) for everything you want returned.
''';

const _fixtureWelcome = '''
# llama_monty — welcome

This is a small mounted filesystem the LLM can list, read, and write.

Try asking the assistant:
- list files in /fixtures
- read welcome.md
- compute the average of column 'price' in sample.csv
''';

const _fixtureSampleCsv = '''
name,quantity,price
apples,12,0.45
bananas,5,0.20
cherries,30,0.10
dates,8,1.20
elderberries,3,2.50
''';

const _fixtureNotes = '''
- bridge: tool-call grammar drops on web
- chat shell plugin: chat_summarize / chat_reset wired
- next: streaming + drag-drop fixtures
''';

Future<void> _seed(MontyRuntime monty) async {
  final script = '''
from pathlib import Path
Path('$_fixtureRoot').mkdir(parents=True, exist_ok=True)
Path('$_fixtureRoot/welcome.md').write_text(${_pyStr(_fixtureWelcome)})
Path('$_fixtureRoot/sample.csv').write_text(${_pyStr(_fixtureSampleCsv)})
Path('$_fixtureRoot/notes.txt').write_text(${_pyStr(_fixtureNotes)})
''';
  final r = await monty.execute(script).result;
  if (r.error != null) {
    throw StateError('seed failed: ${r.error!.message}');
  }
}

String _pyStr(String s) {
  final escaped = s.replaceAll(r'\', r'\\').replaceAll("'''", r"\'\'\'");
  return "'''$escaped'''";
}

String? _extractCode(String reply) {
  final m = RegExp(r'```(?:python|py)?\s*\n?([\s\S]*?)```').firstMatch(reply);
  final c = m?.group(1)?.trim();
  if (c != null && c.isNotEmpty) return c;
  // Raw Python heuristic — used by the web demo too.
  final cleaned = reply.trim();
  if (cleaned.isEmpty) return null;
  if (RegExp(
          r'(^|\n)\s*(print\s*\(|def\s+\w|import\s+\w|from\s+\w|for\s+\w|while\s+|if\s+|return\s+|[a-zA-Z_]\w*\s*=)')
      .hasMatch(cleaned)) {
    return cleaned;
  }
  return null;
}

Future<({String code, String reply})> _llmCode(
  LlamaEngineRef ref,
  String task, {
  String? extraNote,
}) async {
  final note = extraNote == null ? '' : '\n\n$extraNote';
  final session = ChatSession(ref.engine, systemPrompt: _systemPrompt);
  final buf = StringBuffer();
  await for (final c in session.create([LlamaTextContent('$task$note')])) {
    final s = c.choices.firstOrNull?.delta.content;
    if (s != null) buf.write(s);
  }
  final reply = buf.toString();
  return (code: _extractCode(reply) ?? '', reply: reply);
}

/// Runs [task] through the LLM, executes the Python in [monty], and on
/// a Monty parse / runtime error feeds the error message back to the LLM
/// for one repair attempt before giving up.
Future<void> _runTask(
  String name,
  String task, {
  required LlamaEngineRef ref,
  required MontyRuntime monty,
}) async {
  stdout.writeln('\n=== $name ===');
  stdout.writeln('USER: $task');

  String? lastErr;
  for (var attempt = 0; attempt < 3; attempt++) {
    final w = await _llmCode(
      ref,
      task,
      extraNote: lastErr == null
          ? null
          : 'Your previous attempt failed with this error from Monty:\n'
              '  $lastErr\n'
              'Rewrite the code to avoid that issue.',
    );
    if (w.code.isEmpty) {
      stdout.writeln('  [attempt ${attempt + 1}] no code emitted');
      stdout.writeln('  reply preview: '
          '${w.reply.substring(0, w.reply.length > 200 ? 200 : w.reply.length)}');
      return;
    }
    stdout.writeln('\nLLM (attempt ${attempt + 1}):');
    stdout.writeln(w.code.split('\n').map((l) => '  $l').join('\n'));

    final result = await monty.execute(w.code).result;
    if (result.error != null) {
      lastErr = result.error!.message;
      stdout.writeln('\n  ✗ Monty error: $lastErr');
      stdout.writeln('  → asking LLM to retry');
      continue;
    }
    final out = (result.printOutput ?? '').trim();
    // Catch caught-but-printed errors: when the LLM's own try/except
    // swallows an exception and prints "Error: …" / "An ... occurred"
    // to stdout. Without this the host sees a "successful" run that
    // produced a misleading message instead of the real answer.
    final caught = RegExp(
      r"^(error[: ]|an .{0,40}(error|exception)|exception[: ]|traceback |"
      r"warning: |skipping line|invalid|.{0,80}has no attribute)",
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(out);
    if (caught != null) {
      lastErr =
          'your except-clause printed: ${out.substring(caught.start, (caught.start + 200).clamp(0, out.length))}';
      stdout.writeln('\n  ✗ Caught-but-printed error in stdout: $lastErr');
      stdout
          .writeln('  → asking LLM to retry without swallowing the exception');
      continue;
    }
    final ret = result.value is MontyNone
        ? ''
        : '${result.value.dartValue ?? ''}'.trim();
    stdout.writeln('\nMONTY OUTPUT:');
    stdout.writeln([out, ret]
        .where((s) => s.isNotEmpty)
        .map((b) => b.split('\n').map((l) => '  $l').join('\n'))
        .join('\n'));
    return;
  }
  stdout.writeln('  gave up after 3 attempts; last error: $lastErr');
}

Future<void> main() async {
  stdout.writeln('Loading model …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath,
      modelParams: ModelParams(contextSize: 8192));
  final ref = LlamaEngineRef(engine);

  final monty = MontyRuntime(
    os: defaultOsHandler(),
    extensions: [LlamaMontyPlugin(ref)],
  );

  stdout.writeln('Seeding fixtures at $_fixtureRoot …');
  await _seed(monty);
  stdout.writeln('Ready.');

  await _runTask(
    'TASK 1: list files',
    'List the files under $_fixtureRoot and print each name on its own line.',
    ref: ref,
    monty: monty,
  );

  await _runTask(
    'TASK 2: read welcome.md',
    'Read $_fixtureRoot/welcome.md and print only its first non-empty line '
        '(skip the leading "#" if present).',
    ref: ref,
    monty: monty,
  );

  await _runTask(
    'TASK 3: compute CSV average',
    'Read $_fixtureRoot/sample.csv (header line then rows of '
        'name,quantity,price). Compute and print the average price across '
        'all data rows, rounded to 2 decimal places. Do NOT import the csv '
        'module; parse with str.split.',
    ref: ref,
    monty: monty,
  );

  await monty.dispose();
  await engine.dispose();
}
