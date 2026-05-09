// 14-spec competence battery for the run_bash host fn against Gemma 4
// FFI. Mirrors example/eval/e2e/run_e2e.dart's shape; the fence-extract
// + retry-with-context-reset loop is the same. Each spec gets a fresh
// chat session AND a freshly reset wasm host (cwd back to /, VFS
// re-loaded) so specs are independent.
//
// Run: dart run example/eval/bash/run_bash_bench.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';
import 'package:wasm_host_dart/src/wasm_host_ffi.dart';
import 'package:wasm_host_dart/wasm_host.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';
const _spikeRoot = '/Users/runyaga/dev/wasmtime-spike';
const _dylibPath = '$_spikeRoot/host/target/release/libwasm_host.dylib';
const _wasmPath =
    '$_spikeRoot/guest/target/wasm32-wasip1/release/wasm_guest.wasm';

const _systemPrompt = '''
You are a coding agent with a Python sandbox. To DO anything, write
a `\`\`\`monty` fence — the harness extracts and executes the code.
Plain prose is for the final answer AFTER you see the tool output.

`run_bash(cmd)` is a Python function that runs allow-listed shell
commands (pwd / cd / ls / cat / find / echo; && chaining; cwd
persists across calls) and returns
`{'exit_code': N, 'stdout': '...', 'stderr': ''}`.

```monty
out = run_bash('echo hello')
print(out['stdout'])
```

CRITICAL: do NOT write `\`\`\`json` blocks pretending to be the tool
output — those are hallucinations. Only `\`\`\`monty` fences for code.

GROUNDING: copy values from tool output verbatim. Never substitute
training defaults.

When the user asks you to run a shell command, USE run_bash, not
Python pathlib.
''';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

final Map<String, Uint8List> _vfs = {
  '/notes.txt': _b('todo:\n  - finish the demo\n  - profit\n'),
  '/data/greeting.txt': _b('hello, world!\n'),
  '/data/numbers.txt': _b('1\n2\n3\n42\n'),
  '/logs/app.log': _b('[INFO] booted\n[ERROR] oh no\n'),
};

// ---------------------------------------------------------------------------
// Spec types
// ---------------------------------------------------------------------------

typedef BashVerify = ({bool ok, String reason}) Function({
  required String finalProse,
  required List<String> fences,
  required List<String> stdouts,
});

class BashSpec {
  BashSpec({
    required this.id,
    required this.prompt,
    required this.verify,
    this.maxTurns = 4,
    this.knownFail = false,
  });
  final String id;
  final String prompt;
  final BashVerify verify;
  final int maxTurns;
  final bool knownFail;
}

class BashResult {
  BashResult({
    required this.id,
    required this.passed,
    required this.reason,
    required this.turns,
    required this.transcript,
    required this.knownFail,
  });
  final String id;
  final bool passed;
  final String reason;
  final int turns;
  final String transcript;
  final bool knownFail;
}

// ---------------------------------------------------------------------------
// Verify helpers
// ---------------------------------------------------------------------------

BashVerify _v({
  Iterable<String>? stdoutContainsAll,
  Iterable<String>? stdoutContainsAny,
  Iterable<String>? proseContainsAll,
  Iterable<String>? proseContainsAny,
  String? fenceContains,
  Iterable<String>? proseDoesNotContain,
}) {
  return ({
    required finalProse,
    required fences,
    required stdouts,
  }) {
    bool inAnyStdout(String s) => stdouts.any((o) => o.contains(s));
    bool inProseOrStdout(String s) =>
        finalProse.contains(s) || inAnyStdout(s);

    if (fenceContains != null &&
        !fences.any((f) => f.contains(fenceContains))) {
      return (ok: false, reason: 'no fence contains "$fenceContains"');
    }
    if (stdoutContainsAll != null) {
      for (final s in stdoutContainsAll) {
        if (!inAnyStdout(s)) {
          return (ok: false, reason: 'no stdout contains "$s"');
        }
      }
    }
    if (stdoutContainsAny != null &&
        !stdoutContainsAny.any(inAnyStdout)) {
      return (ok: false, reason: 'no stdout contains any of $stdoutContainsAny');
    }
    if (proseContainsAll != null) {
      for (final s in proseContainsAll) {
        if (!inProseOrStdout(s)) {
          return (
            ok: false,
            reason: 'value "$s" not in prose or stdout',
          );
        }
      }
    }
    if (proseContainsAny != null &&
        !proseContainsAny.any(inProseOrStdout)) {
      return (ok: false, reason: 'no value of $proseContainsAny in prose/stdout');
    }
    if (proseDoesNotContain != null) {
      for (final s in proseDoesNotContain) {
        if (finalProse.contains(s)) {
          return (ok: false, reason: 'prose contains forbidden "$s"');
        }
      }
    }
    return (ok: true, reason: 'ok');
  };
}

// ---------------------------------------------------------------------------
// Runner — single spec
// ---------------------------------------------------------------------------

final _fenceRe =
    RegExp(r'```(?:monty|python|py)\s*\n?([\s\S]*?)```');

Future<BashResult> _runOne({
  required LlamaEngine engine,
  required MontyRuntime monty,
  required WasmHostBackend wasmHost,
  required BashSpec tc,
}) async {
  // Reset shell + VFS so specs are independent.
  await wasmHost.resetSession();
  await wasmHost.loadTree(_vfs);

  final session = ChatSession(engine, systemPrompt: _systemPrompt);
  final t = StringBuffer();
  void log(String tag, String s) => t.writeln('[$tag] $s');
  log('user', tc.prompt);

  session.addMessage(LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: tc.prompt,
  ));

  final fences = <String>[];
  final stdouts = <String>[];
  var finalProse = '';

  for (var turn = 0; turn < tc.maxTurns; turn++) {
    final buf = StringBuffer();
    await for (final chunk in session.create(
      const [],
      params: const GenerationParams(temp: 1.0, topP: 0.95),
    )) {
      final s = chunk.choices.firstOrNull?.delta.content;
      if (s != null) buf.write(s);
    }
    final reply = buf.toString().trim();
    log('asst', reply.isEmpty ? '(empty)' : reply);

    final matches = _fenceRe.allMatches(reply).toList();
    if (matches.isEmpty) {
      finalProse = reply;
      log('done', 'no fence; final prose');
      break;
    }
    String? lastFenceCode;
    var failed = false;
    String result = '';
    for (final m in matches) {
      final code = m.group(1)!.trim();
      if (code.isEmpty) continue;
      fences.add(code);
      lastFenceCode = code;
      log('code', code);
      final r = await monty.execute(code).result;
      if (r.error != null) {
        result = 'Error: ${r.error!.message}';
        failed = true;
        log('err', result);
        break;
      }
      final out = (r.printOutput ?? '').trim();
      stdouts.add(out);
      result = out.isEmpty ? '(empty)' : out;
      log('stdout', result);
    }

    // If model wrote prose AFTER the last fence, take it as the answer.
    if (!failed && matches.isNotEmpty) {
      final tail = reply.substring(matches.last.end).trim();
      if (tail.isNotEmpty) {
        finalProse = tail;
        log('done', 'prose after last fence');
        break;
      }
    }

    if (failed) {
      // Feed the error back as a synthetic user msg; cap at maxTurns.
      session.addMessage(LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'tool_output:\n$result\n\n'
            'That fence errored. Rewrite it to run successfully and '
            'tell me the result.',
      ));
      continue;
    }

    // Successful fence(s) but no trailing prose — feed result back so
    // the model can react.
    session.addMessage(LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text:
          'tool_output:\n$result\n\nNow tell me the answer in plain '
          'prose using the EXACT values you saw.',
    ));
  }

  final v = tc.verify(
    finalProse: finalProse,
    fences: fences,
    stdouts: stdouts,
  );
  return BashResult(
    id: tc.id,
    passed: v.ok,
    reason: v.reason,
    turns: _countAssistantTurns(t.toString()),
    transcript: t.toString(),
    knownFail: tc.knownFail,
  );
}

int _countAssistantTurns(String transcript) =>
    RegExp(r'\[asst\]', multiLine: true).allMatches(transcript).length;

// ---------------------------------------------------------------------------
// Spec battery
// ---------------------------------------------------------------------------

final _specs = <BashSpec>[
  // Tier 1 — basics (3)
  BashSpec(
    id: 'B01_echo_literal',
    prompt: "Use run_bash to print 'hello' via echo. Tell me what it printed.",
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['hello'],
      proseContainsAll: ['hello'],
    ),
  ),
  BashSpec(
    id: 'B02_echo_multi_arg',
    prompt: "Use run_bash to echo 'foo bar baz'. Tell me what it printed.",
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['foo bar baz'],
      proseContainsAll: ['foo bar baz'],
    ),
  ),
  BashSpec(
    id: 'B03_pwd_root',
    prompt: 'Use run_bash to print the current working directory. State '
        'what it is.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['/'],
      proseContainsAny: ['/'],
    ),
  ),

  // Tier 2 — file reads (2)
  BashSpec(
    id: 'B04_cat_notes',
    prompt: 'Use run_bash to cat /notes.txt. Quote what it printed.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['todo'],
      proseContainsAny: ['todo', 'finish'],
    ),
  ),
  BashSpec(
    id: 'B05_cat_numbers',
    prompt:
        'Use run_bash to cat /data/numbers.txt. Then tell me the LAST number '
        'in the file.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['42'],
      proseContainsAll: ['42'],
    ),
  ),

  // Tier 3 — listings (2)
  BashSpec(
    id: 'B06_ls_data',
    prompt: 'Use run_bash to list /data. Tell me the filenames you saw.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['greeting.txt', 'numbers.txt'],
      proseContainsAll: ['greeting.txt'],
    ),
  ),
  BashSpec(
    id: 'B07_find_root',
    prompt: 'Use run_bash to find / (recursive). Tell me which paths exist.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['/notes.txt', '/data/greeting.txt'],
      proseContainsAny: ['/notes.txt', 'notes.txt'],
    ),
  ),

  // Tier 4 — navigation with cd + chaining (3)
  BashSpec(
    id: 'B08_cd_then_pwd',
    prompt: 'Use run_bash with `cd /data && pwd` and tell me the result.',
    verify: _v(
      fenceContains: 'cd /data',
      stdoutContainsAll: ['/data'],
      proseContainsAll: ['/data'],
    ),
    maxTurns: 5,
  ),
  BashSpec(
    id: 'B09_cd_then_ls',
    prompt:
        'Use run_bash with `cd /data && ls` and tell me what files are there.',
    verify: _v(
      fenceContains: 'cd /data',
      stdoutContainsAll: ['greeting.txt', 'numbers.txt'],
      proseContainsAll: ['greeting.txt'],
    ),
  ),
  BashSpec(
    id: 'B10_cd_then_cat',
    prompt:
        'Use run_bash with `cd /data && cat greeting.txt` and tell me the '
        'greeting.',
    verify: _v(
      fenceContains: 'cd /data',
      stdoutContainsAll: ['hello, world!'],
      proseContainsAny: ['hello, world!', 'hello world'],
    ),
  ),

  // Tier 5 — multi-call (cwd persists across SEPARATE run_bash calls) (2)
  BashSpec(
    id: 'B11_multi_call_cwd_persists',
    prompt:
        'Use run_bash TWICE in one fence: first `cd /data` and discard the '
        'result, then `pwd` to confirm cwd. Tell me what pwd printed.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['/data'],
      proseContainsAll: ['/data'],
    ),
    maxTurns: 5,
  ),
  BashSpec(
    id: 'B12_find_then_cat',
    prompt:
        'Use run_bash to find files under /logs (one call), then cat the '
        'first one (second call). Tell me the first non-blank line of '
        'that file.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['INFO'],
      proseContainsAny: ['INFO', 'booted'],
    ),
    maxTurns: 6,
  ),

  // Tier 6 — combined evals: Python + bash composition (3)
  // The whole point — agent uses bash for what bash is good at and
  // Python for what Python is good at, in the same fence.
  BashSpec(
    id: 'C01_bash_then_python_sum',
    prompt:
        'Use run_bash to cat /data/numbers.txt, then in the SAME fence '
        "use Python to parse the stdout (split lines, int() each) and "
        'print the sum.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['48'], // 1 + 2 + 3 + 42 = 48
      proseContainsAll: ['48'],
    ),
    maxTurns: 5,
  ),
  BashSpec(
    id: 'C02_bash_find_then_python_count',
    prompt:
        'Use run_bash with `find /` to list every path, then in the SAME '
        'fence use Python to count how many lines stdout had. Tell me '
        'the count.',
    verify: _v(
      fenceContains: 'run_bash',
      // VFS has 4 files plus implicit directories; find should yield
      // at least 4 path lines.
      proseContainsAny: ['4', '5', '6', '7', '8'],
    ),
    maxTurns: 5,
  ),
  BashSpec(
    id: 'C03_python_value_via_bash_echo',
    prompt:
        'In Python, compute 7 * 8. Then use run_bash to echo the result. '
        'Tell me what bash printed.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['56'],
      proseContainsAll: ['56'],
    ),
    maxTurns: 5,
  ),

  // Tier 7 — known-fail / disallowed (2)
  BashSpec(
    id: 'B13_disallowed_grep',
    prompt:
        'Try to use run_bash with `grep INFO /logs/app.log`. Tell me what '
        "happens and (if it failed) explain why.",
    knownFail: true,
    verify: _v(
      proseContainsAny: ['error', 'not allow', 'allow-list', 'rejected'],
    ),
  ),
  BashSpec(
    id: 'B14_disallowed_pipe',
    prompt:
        'Try to use run_bash with `cat /notes.txt | head -1`. Tell me what '
        "happens.",
    knownFail: true,
    verify: _v(
      proseContainsAny: ['error', 'not allow', 'pipe', 'rejected'],
    ),
  ),
];

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  if (!File(_dylibPath).existsSync()) {
    stderr.writeln('libwasm_host.dylib not built at $_dylibPath');
    exit(2);
  }
  if (!File(_wasmPath).existsSync()) {
    stderr.writeln('wasm_guest.wasm not built at $_wasmPath');
    exit(2);
  }

  stdout.writeln('Loading Gemma 4 …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(
    _modelPath,
    modelParams: ModelParams(contextSize: 8192),
  );

  final wasmHost = WasmHostFfi.open(_dylibPath);
  // The bash bench doesn't need MontyRuntime extensions like
  // LlamaMontyPlugin / SandboxExtension — only run_bash.
  final monty = MontyRuntime(os: defaultOsHandler());
  final wasmBytes = File(_wasmPath).readAsBytesSync();
  monty.register(
    buildRunBashFunction(host: wasmHost, wasmBytes: wasmBytes),
  );

  final results = <BashResult>[];
  for (final tc in _specs) {
    stdout.writeln('\n========= ${tc.id} =========');
    final result = await _runOne(
      engine: engine,
      monty: monty,
      wasmHost: wasmHost,
      tc: tc,
    );
    if (!result.passed) {
      stdout.writeln(result.transcript);
    }
    final mark = !result.passed && result.knownFail
        ? '△'
        : result.passed
            ? '✓'
            : '✗';
    stdout.writeln(
      'result: $mark ${result.passed ? 'PASS' : 'FAIL'} '
      '(turns=${result.turns}) — ${result.reason}'
      '${result.knownFail && !result.passed ? ' [known-fail]' : ''}',
    );
    results.add(result);
  }

  stdout.writeln('\n========= summary =========');
  for (final r in results) {
    final mark = !r.passed && r.knownFail
        ? '△'
        : r.passed
            ? '✓'
            : '✗';
    stdout.writeln('$mark ${r.id.padRight(34)} turns=${r.turns} — ${r.reason}');
  }
  final passed = results.where((r) => r.passed).length;
  final unexpectedFail =
      results.where((r) => !r.passed && !r.knownFail).length;
  final knownFail = results.where((r) => !r.passed && r.knownFail).length;
  stdout.writeln(
    '\n$passed PASS · $unexpectedFail FAIL · $knownFail △ known-fail '
    '(of ${results.length})',
  );

  await wasmHost.dispose();
  await monty.dispose();
  await engine.dispose();
}
