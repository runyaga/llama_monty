// Survey: which shell commands does Gemma 4 E2B reach for?
//
// We give the model 15 shell-flavoured tasks against a VFS rooted at
// /tmp/llama-test/ — same world the Python sandbox sees. The model is told it has run_bash but NOT
// which commands are allow-listed. We record:
//   - the bash command(s) the model wrote (the argv0)
//   - whether they ran successfully or got `<host error -3>` from the
//     spike's allow-list
//   - tally per command across all tasks
//
// Output is a frequency table of {command -> {attempts, allowed, denied}}
// that tells us what to ask the dart_wasm_sandbox owner to add to the
// allow-list next.
//
// This is observational, not pass/fail. The bench (run_bash_bench.dart)
// asserts correctness on the 6 commands we DO have. This file figures
// out what the 7th, 8th, ... should be.
//
// Run: dart run example/eval/bash/bash_knowledge_survey.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';
import 'package:dart_wasm_sandbox/src/wasm_host_ffi.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';
const _spikeRoot = '/Users/runyaga/dev/dart_wasm_sandbox';
const _dylibPath = '$_spikeRoot/host/target/release/libwasm_host.dylib';
const _wasmPath =
    '$_spikeRoot/guest/target/wasm32-wasip1/release/wasm_guest.wasm';

// IMPORTANT: this prompt does NOT enumerate the allow-list. We want
// the model to write what it would naturally reach for, then the
// dart_wasm_sandbox's runtime tells us what was actually accepted.
const _systemPrompt = '''
You are a coding agent with a Python sandbox. To DO anything, write
a `\`\`\`monty` fence — the harness extracts and executes the code.

`run_bash(cmd)` runs a shell command and returns
`{'exit_code': N, 'stdout': '...', 'stderr': ''}`. The shell is
sandboxed and runs over a small in-memory VFS:

  /notes.txt              "todo:\\n  - finish the demo\\n  - profit\\n"
  /tmp/llama-test/fixtures/greeting.txt      "hello, world!\\n"
  /tmp/llama-test/fixtures/numbers.txt       "1\\n2\\n3\\n42\\n"
  /tmp/llama-test/state/app.log           "[INFO] booted\\n[ERROR] oh no\\n"

Use whatever shell command is most natural for each task. If a
command isn't supported, the response will say `<host error -3>`.

Example:

```monty
out = run_bash('echo hello')
print(out['stdout'])
```

CRITICAL: do NOT write `\`\`\`json` blocks pretending to be the tool
output — those are hallucinations. Only `\`\`\`monty` fences.
''';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

final Map<String, Uint8List> _vfs = {
  '/tmp/llama-test/fixtures/notes.txt': _b('todo:\n  - finish the demo\n  - profit\n'),
  '/tmp/llama-test/fixtures/greeting.txt': _b('hello, world!\n'),
  '/tmp/llama-test/fixtures/numbers.txt': _b('1\n2\n3\n42\n'),
  '/tmp/llama-test/state/app.log': _b('[INFO] booted\n[ERROR] oh no\n'),
};

/// Tasks that span common shell idioms. Each is open-ended — model
/// picks the command. Picked to elicit grep / head / tail / wc / sort
/// / awk / sed naturally.
const _tasks = <({String id, String prompt})>[
  (
    id: 'T01_search_text',
    prompt:
        'Use run_bash to find every line in /tmp/llama-test/state/app.log that contains '
        '"ERROR". Tell me what you found.',
  ),
  (
    id: 'T02_first_line',
    prompt:
        'Use run_bash to print only the FIRST line of /tmp/llama-test/fixtures/numbers.txt. '
        'Tell me what it is.',
  ),
  (
    id: 'T03_last_line',
    prompt:
        'Use run_bash to print only the LAST line of /tmp/llama-test/fixtures/numbers.txt. '
        'Tell me what it is.',
  ),
  (
    id: 'T04_count_lines',
    prompt:
        'Use run_bash to count how many lines /tmp/llama-test/fixtures/numbers.txt has. '
        'Tell me the count.',
  ),
  (
    id: 'T05_count_chars',
    prompt:
        'Use run_bash to count how many bytes /tmp/llama-test/fixtures/greeting.txt has. '
        'Tell me the byte count.',
  ),
  (
    id: 'T06_find_files_by_ext',
    prompt:
        'Use run_bash to find every .txt file under /. List them.',
  ),
  (
    id: 'T07_recursive_listing',
    prompt:
        'Use run_bash to list every file (not directory) under /, recursively.',
  ),
  (
    id: 'T08_grep_inverse',
    prompt:
        'Use run_bash to print every line of /tmp/llama-test/state/app.log that does NOT '
        'contain "INFO". Tell me what you found.',
  ),
  (
    id: 'T09_sort',
    prompt:
        'Use run_bash to print the contents of /tmp/llama-test/fixtures/numbers.txt sorted '
        'numerically. Tell me what you printed.',
  ),
  (
    id: 'T10_replace_text',
    prompt:
        'Use run_bash to replace every "INFO" with "info" in /tmp/llama-test/state/app.log '
        'and print the result. (Do not modify the file on disk.)',
  ),
  (
    id: 'T11_word_count',
    prompt:
        'Use run_bash to count the number of words in /tmp/llama-test/fixtures/greeting.txt. '
        'Tell me the count.',
  ),
  (
    id: 'T12_pipe_chain',
    prompt:
        'Use run_bash to print just the first 2 lines of /tmp/llama-test/fixtures/numbers.txt '
        'using a pipe (cat | head, or similar). Tell me what you got.',
  ),
  (
    id: 'T13_unique',
    prompt:
        'Use run_bash to print only the unique distinct lines from a file. '
        '(/notes.txt has dup-free content, so the answer is the whole file.) '
        'Show me the command and the result.',
  ),
  (
    id: 'T14_sum_column',
    prompt:
        'Use run_bash to compute the SUM of the integers in '
        '/tmp/llama-test/fixtures/numbers.txt. (Hint: awk is the canonical tool.) '
        'Tell me the sum.',
  ),
  (
    id: 'T15_diff',
    prompt:
        'Use run_bash to compare /tmp/llama-test/fixtures/greeting.txt against itself; should '
        'show no differences. Tell me what diff said.',
  ),
];

/// Pulls the first whitespace token out of a `run_bash('...')` literal
/// in a fence. Best-effort — if the model parameterised the command
/// the literal might be a variable; in that case we record `<dynamic>`.
String _argv0Of(String cmd) {
  final trimmed = cmd.trim();
  if (trimmed.isEmpty) return '<empty>';
  final firstWord = trimmed.split(RegExp(r'\s+')).first;
  return firstWord;
}

/// Pulls every `run_bash('...')` call's command literal out of [code].
/// Parses both single-quoted and double-quoted single-line literals.
/// Misses: triple-quoted, f-strings, concatenations, variables.
List<String> _extractRunBashLiterals(String code) {
  final out = <String>[];
  final re = RegExp(
    r'''run_bash\(\s*([rRbB]?)('([^']*)'|"([^"]*)")''',
  );
  for (final m in re.allMatches(code)) {
    out.add(m.group(3) ?? m.group(4) ?? '');
  }
  return out;
}

/// Splits a shell command on `&&` so we can record each argv0 separately.
List<String> _splitChained(String shellCmd) =>
    shellCmd.split('&&').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

class _Outcome {
  int allowed = 0;
  int denied = 0;
  int total = 0;
  final attemptedTasks = <String>{};
  void record(String taskId, bool wasAllowed) {
    total++;
    if (wasAllowed) {
      allowed++;
    } else {
      denied++;
    }
    attemptedTasks.add(taskId);
  }
}

final _fenceRe = RegExp(r'```(?:monty|python|py)\s*\n?([\s\S]*?)```');

Future<void> main() async {
  if (!File(_dylibPath).existsSync()) {
    stderr.writeln('libwasm_host.dylib not built at $_dylibPath');
    exit(2);
  }

  stdout.writeln('Loading Gemma 4 …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(
    _modelPath,
    modelParams: ModelParams(contextSize: 8192),
  );

  final wasmHost = WasmHostFfi.open(_dylibPath);
  final monty = MontyRuntime(os: defaultOsHandler());
  final wasmBytes = File(_wasmPath).readAsBytesSync();
  monty.register(
    buildRunBashFunction(host: wasmHost, wasmBytes: wasmBytes),
  );

  final commandStats = <String, _Outcome>{};

  for (final task in _tasks) {
    stdout.writeln('\n========= ${task.id} =========');
    stdout.writeln('[user] ${task.prompt}');

    await wasmHost.resetSession();
    await wasmHost.loadTree(_vfs);

    final session = ChatSession(engine, systemPrompt: _systemPrompt);
    session.addMessage(LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: task.prompt,
    ));

    final buf = StringBuffer();
    await for (final chunk in session.create(
      const [],
      params: const GenerationParams(temp: 1.0, topP: 0.95),
    )) {
      final s = chunk.choices.firstOrNull?.delta.content;
      if (s != null) buf.write(s);
    }
    final reply = buf.toString().trim();
    stdout.writeln('[asst] $reply');

    final fences = _fenceRe.allMatches(reply).toList();
    for (final m in fences) {
      final code = m.group(1)!.trim();
      if (code.isEmpty) continue;
      // Run it so we record actual allowed/denied.
      final r = await monty.execute(code).result;
      final stdoutText = (r.printOutput ?? '').trim();
      stdout.writeln('[stdout] $stdoutText');

      // Parse command literals to see what the model attempted.
      // Classification is purely against the static allow-list — the
      // runtime strips the `<host error -3>` marker out of the stdout
      // field before Python sees it, so we can't detect denial from
      // the captured stdout. Static classification is more honest
      // anyway: it's the dart_wasm_sandbox's known allow-list.
      for (final shellCmd in _extractRunBashLiterals(code)) {
        for (final segment in _splitChained(shellCmd)) {
          final argv0 = _argv0Of(segment);
          final stat = commandStats.putIfAbsent(argv0, _Outcome.new);
          stat.record(task.id, _isAllowListed(argv0));
        }
      }
    }
  }

  stdout.writeln('\n========= command frequency =========');
  final entries = commandStats.entries.toList()
    ..sort((a, b) => b.value.total.compareTo(a.value.total));
  stdout.writeln('${'cmd'.padRight(14)}  attempts  allowed  denied  tasks');
  for (final e in entries) {
    final s = e.value;
    stdout.writeln(
      '${e.key.padRight(14)}  '
      '${s.total.toString().padLeft(8)}  '
      '${s.allowed.toString().padLeft(7)}  '
      '${s.denied.toString().padLeft(6)}  '
      '${s.attemptedTasks.toList().join(",")}',
    );
  }

  // Rank-by-want: commands the model wanted most that AREN'T in the
  // allow-list — these are the top candidates to send to the wasmtime-
  // spike owner.
  final wants = entries
      .where((e) => !_isAllowListed(e.key) && e.value.denied > 0)
      .toList();
  if (wants.isNotEmpty) {
    stdout.writeln('\n========= commands the model wants but we deny =========');
    for (final e in wants) {
      stdout.writeln(
        '  ${e.key.padRight(14)} (denied ${e.value.denied}× across ${e.value.attemptedTasks.length} task(s))',
      );
    }
    stdout.writeln(
      '\nForward this list to the dart_wasm_sandbox owner for allow-list '
      'expansion candidates.',
    );
  }

  await wasmHost.dispose();
  await monty.dispose();
  await engine.dispose();
}

// Post-Phase-A1 allow-list (dart_wasm_sandbox commit 190d0c3).
// The runtime adds wc / grep / head / tail; pipes, sed, awk, sort,
// diff, and others remain rejected.
bool _isAllowListed(String argv0) => const {
      'pwd',
      'cd',
      'ls',
      'cat',
      'find',
      'echo',
      'wc',
      'grep',
      'head',
      'tail',
    }.contains(argv0);
