// 14-spec competence battery for the run_bash host fn against Gemma 4
// FFI. Mirrors example/eval/e2e/run_e2e.dart's shape; the fence-extract
// + retry-with-context-reset loop is the same. Each spec gets a fresh
// chat session AND a freshly reset wasm host (cwd back to /, VFS
// re-loaded) so specs are independent.
//
// Run: dart run example/eval/bash/run_bash_bench.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
tail / sort / xargs. && chains and `|` pipes work. cwd persists
across calls.

If `exit_code != 0`, the command failed — `stderr` says why. Don't
silently print empty `stdout` and pretend it worked.

IMPORTANT shell semantics:
- **No glob expansion.** `*` is NOT expanded. Don't write
  `ls /dir/*.log` — it returns empty. To list files in a directory,
  use `find /dir` (or `find /dir -type f` for files only).
- **`grep` is fixed-string substring match, NOT regex.** `[`, `]`,
  `^`, `\$`, `\\`, `.` are matched as literal characters. Don't
  escape brackets — write `grep ERROR file`, not `grep "\[ERROR\]"
  file`.
- For "find X files matching pattern then run cmd on each," use
  `find /dir | xargs cmd` or `cmd file1 file2 ...` directly.

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
  required WasmHostBackend wasmHost,
  required Uint8List wasmBytes,
  required BashSpec tc,
}) async {
  // Reset shell + VFS so specs are independent.
  await wasmHost.resetSession();
  await wasmHost.loadTree(bashVfs);

  // Fresh MontyRuntime per replicate. The runtime carries a Python
  // namespace; without this, variables defined in one spec/replicate
  // leak into the next. Cheap to construct.
  final monty = MontyRuntime(os: defaultOsHandler());
  monty.register(
    buildRunBashFunction(host: wasmHost, wasmBytes: wasmBytes),
  );

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

  await monty.dispose();

  final turns = _countAssistantTurns(t.toString());
  final v = tc.verify(
    finalProse: finalProse,
    fences: fences,
    stdouts: stdouts,
  );

  // Cross-turn gate: if the spec sets minTurns, fail the run when
  // the model finished in fewer chat turns than required (e.g. by
  // packing the whole solution into one fence + prose).
  var ok = v.ok;
  var reason = v.reason;
  if (tc.minTurns != null && turns < tc.minTurns!) {
    ok = false;
    reason = 'used $turns turns; spec needs >= ${tc.minTurns}';
  }

  return BashResult(
    id: tc.id,
    passed: ok,
    reason: reason,
    turns: turns,
    transcript: t.toString(),
    knownFail: tc.knownFail,
  );
}

int _countAssistantTurns(String transcript) =>
    RegExp(r'\[asst\]', multiLine: true).allMatches(transcript).length;


// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
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
  final wasmBytes = File(_wasmPath).readAsBytesSync();

  // ---------------------------------------------------------------
  // Canonical-solution probe — runs each spec's `canonicalSolution`
  // against the live wasm host (no LLM). Catches fixture / runtime
  // drift before burning compute on a doomed bench.
  // ---------------------------------------------------------------
  stdout.writeln('\n========= canonical probe =========');
  var canonicalFails = 0;
  for (final tc in bashSpecs) {
    if (tc.canonicalSolution == null) continue;
    await wasmHost.resetSession();
    await wasmHost.loadTree(bashVfs);
    final out = await wasmHost.run(
      wasmBytes,
      stdin: Uint8List.fromList(utf8.encode(tc.canonicalSolution!)),
    );
    final raw = utf8.decode(out, allowMalformed: true);
    final marker = RegExp(r'<host error -?\d+>').firstMatch(raw);
    final firstLine =
        raw.split('\n').firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (marker != null) {
      stdout.writeln('✗ ${tc.id.padRight(38)} ${marker.group(0)}');
      canonicalFails++;
    } else {
      // Apply the spec's verify treating canonical stdout as the
      // ground-truth-prose-and-stdout. GREEN = canonical fully
      // satisfies the spec. YELLOW = runtime supports it but verify
      // also checks LLM-prose-only fields the canonical can't fake.
      final v = tc.verify(
        finalProse: raw,
        fences: [tc.canonicalSolution!],
        stdouts: [raw],
      );
      final mark = v.ok ? '✓' : '~';
      stdout.writeln(
        '$mark ${tc.id.padRight(38)} ${firstLine.length > 60 ? "${firstLine.substring(0, 60)}..." : firstLine}',
      );
    }
  }
  if (canonicalFails > 0) {
    stderr.writeln(
      '\n$canonicalFails canonical probe(s) returned <host error -N>. '
      'Fixture or runtime drift? Aborting before burning LLM compute.',
    );
    await wasmHost.dispose();
    await engine.dispose();
    exit(2);
  }
  stdout.writeln('canonical probe ok\n');

  // Bail out if --probe-only was requested.
  if (args.contains('--probe-only')) {
    await wasmHost.dispose();
    await engine.dispose();
    return;
  }

  // Per-spec replicate sweep so single-run flakes become statistical
  // signal. Each spec runs N times against a fresh wasm session +
  // chat session; the spec is "passed" if at least majority of
  // replicates pass.
  final replicates = _argInt(args, '--replicates', 3);
  final onlyArg = _argString(args, '--only');
  final onlySet = onlyArg?.split(',').map((s) => s.trim()).toSet();
  final specs = onlySet == null
      ? bashSpecs
      : bashSpecs
          .where(
            (s) =>
                onlySet.contains(s.id) ||
                onlySet.any(
                  (prefix) => s.id.startsWith('$prefix') || s.id.startsWith('${prefix}_'),
                ),
          )
          .toList();
  if (specs.isEmpty) {
    stderr.writeln('No specs matched --only=$onlyArg');
    exit(2);
  }
  stdout.writeln(
    'Replicates per spec: $replicates · running ${specs.length} of '
    '${bashSpecs.length} specs',
  );

  final perSpec = <String, List<BashResult>>{};
  for (final tc in specs) {
    final specReps = tc.replicates ?? replicates;
    final reps = <BashResult>[];
    for (var i = 1; i <= specReps; i++) {
      stdout.writeln('\n========= ${tc.id} (rep $i/$specReps) =========');
      final result = await _runOne(
        engine: engine,
        wasmHost: wasmHost,
        wasmBytes: wasmBytes,
        tc: tc,
      );
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
      reps.add(result);
    }
    perSpec[tc.id] = reps;
  }

  stdout.writeln('\n========= summary =========');
  var totalPassed = 0;
  var totalUnexpectedFail = 0;
  var totalKnownFail = 0;
  for (final tc in specs) {
    final reps = perSpec[tc.id]!;
    final specReps = tc.replicates ?? replicates;
    final passes = reps.where((r) => r.passed).length;
    final pass = passes >= (specReps / 2).ceil();
    final isKnownFail = tc.knownFail;
    final mark = pass
        ? '✓'
        : isKnownFail
            ? '△'
            : '✗';
    final avgTurns = reps.map((r) => r.turns).reduce((a, b) => a + b) /
        specReps;
    stdout.writeln(
      '$mark ${tc.id.padRight(34)} '
      '$passes/$specReps  '
      'avg-turns=${avgTurns.toStringAsFixed(1)}',
    );
    if (pass) {
      totalPassed++;
    } else if (isKnownFail) {
      totalKnownFail++;
    } else {
      totalUnexpectedFail++;
    }
  }
  stdout.writeln(
    '\n$totalPassed PASS · $totalUnexpectedFail FAIL · '
    '$totalKnownFail △ known-fail (of ${specs.length}) '
    '@ N=$replicates replicates',
  );

  await wasmHost.dispose();
  await engine.dispose();
}

int _argInt(List<String> args, String flag, int fallback) {
  final i = args.indexOf(flag);
  if (i == -1 || i + 1 >= args.length) return fallback;
  return int.tryParse(args[i + 1]) ?? fallback;
}

String? _argString(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}
