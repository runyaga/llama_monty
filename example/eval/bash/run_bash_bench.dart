// 14-spec competence battery for the run_bash host fn against Gemma 4
// FFI. Mirrors example/eval/e2e/run_e2e.dart's shape; the fence-extract
// + retry-with-context-reset loop is the same. Each spec gets a fresh
// chat session AND a freshly reset wasm host (cwd back to /, VFS
// re-loaded) so specs are independent.
//
// Run: dart run example/eval/bash/run_bash_bench.dart

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';
import 'package:dart_wasm_sandbox/src/wasm_host_ffi.dart';
import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';

import 'bash_specs.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';
const _spikeRoot = '/Users/runyaga/dev/dart_wasm_sandbox';
const _dylibPath = '$_spikeRoot/host/target/release/libwasm_host.dylib';
const _wasmPath =
    '$_spikeRoot/guest/target/wasm32-wasip1/release/wasm_guest.wasm';

const _systemPrompt = '''
You are a coding agent with a Python sandbox. To DO anything, write
a `\`\`\`monty` fence — the harness extracts and executes the code.
Plain prose is for the final answer AFTER you see the tool output.

`run_bash(cmd)` is a Python function that runs allow-listed shell
commands and returns
`{'exit_code': N, 'stdout': '...', 'stderr': '...'}`.

Allow-listed: pwd / cd / ls / cat / find / echo / wc / grep / head /
tail / sort. && chains and `|` pipes work. cwd persists across calls.

If `exit_code != 0`, the command failed — `stderr` says why. Don't
silently print empty `stdout` and pretend it worked.

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
  await wasmHost.loadTree(bashVfs);

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
  for (final tc in bashSpecs) {
    stdout.writeln('\n========= ${tc.id} =========');
    final result = await _runOne(
      engine: engine,
      monty: monty,
      wasmHost: wasmHost,
      tc: tc,
    );
    // Always dump transcript so every run_bash literal is captured.
    stdout.writeln(result.transcript);
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
