// A/B prompt comparison: same 17-spec battery, two system prompts,
// three replicates each. Measures whether peer-tools framing or
// single-fence containment moves Gemma 4 E2B's pass rate more.
//
// Variant A — peer tools / multi-tool composition.
//   Tells the agent it has TWO equal tools (run_python and run_bash).
//   Examples show pure-shell, then bash-then-Python.
//
// Variant B — Python-first / single-fence containment.
//   Wrap the whole task in ONE monty fence; run_bash is just a
//   Python function inside the script.
//
// Same engine, same specs, same VFS, same temp/top_p, same retry
// policy. The only thing that changes between A and B is the system
// prompt string. The fence pipeline is identical: run_bash is
// always a host function in dart_monty regardless of how the prompt
// frames it.
//
// Usage:
//   dart run example/eval/bash/bash_prompt_ab.dart
//   dart run example/eval/bash/bash_prompt_ab.dart --replicates 5
//   dart run example/eval/bash/bash_prompt_ab.dart --only B01,B02
//
// Output: a side-by-side comparison table to stdout, plus a
// machine-readable JSON dump at /tmp/bash_ab_<timestamp>.json.

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';
import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';
import 'package:dart_wasm_sandbox/ffi.dart' show openFfi;
import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';

import 'bash_specs.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';
const _spikeRoot = '/Users/runyaga/dev/dart_wasm_sandbox';
const _dylibPath = '$_spikeRoot/host/target/release/libwasm_host.dylib';
const _wasmPath =
    '$_spikeRoot/guest/target/wasm32-wasip1/release/wasm_guest.wasm';

// ---------------------------------------------------------------------------
// Variant prompts
// ---------------------------------------------------------------------------

/// Variant A: two peer tools, agent picks. Closer to Claude/GPT-4
/// tool-use framing, but still routed through the same fence.
const _promptA = '''
You are a coding agent with TWO tools you can call from inside a
`\`\`\`monty` fence.

  run_python: write Python in the fence; the harness extracts and
              executes it.
  run_bash(cmd): an allow-listed shell command (pwd / cd / ls / cat
              / find / echo; && chaining; cwd persists across calls).
              Returns `{'exit_code': N, 'stdout': '...', 'stderr': ''}`.

For shell-flavoured tasks (cat, ls, cd, find), CALL run_bash. For
computation, use Python. The two compose — a fence may call run_bash
one or more times and process the result with Python.

Pure-shell example:

```monty
out = run_bash('cat /tmp/llama-test/fixtures/greeting.txt')
print(out['stdout'])
```

Bash + Python example:

```monty
out = run_bash('cat /tmp/llama-test/fixtures/numbers.txt')
total = sum(int(n) for n in out['stdout'].split() if n)
print(total)
```

CRITICAL: only `\`\`\`monty` fences. Do NOT write `\`\`\`json` blocks
pretending to be tool output — those are hallucinations. Copy values
from tool output verbatim.
''';

/// Variant B: single fence, Python-first. run_bash is just a function
/// the model calls inside the script. The fence holds the whole plan.
const _promptB = '''
You are a coding agent with a Python sandbox. To DO anything, write
ONE `\`\`\`monty` fence — the harness extracts and executes the code.
Plain prose is for the final answer AFTER you see the tool output.

Inside the fence you have `run_bash(cmd)` — a Python function that
runs an allow-listed shell command (pwd / cd / ls / cat / find /
echo; && chaining; cwd persists across calls). It returns
`{'exit_code': N, 'stdout': '...', 'stderr': ''}`.

`run_bash` is just a function call. Wrap your whole task in one
fence: read with run_bash, compute with Python, print the answer.

```monty
out = run_bash('cat /tmp/llama-test/fixtures/numbers.txt')
nums = [int(n) for n in out['stdout'].split() if n]
print(sum(nums))
```

CRITICAL:
- Exactly ONE `\`\`\`monty` fence per turn.
- Only `\`\`\`monty` fences. Do NOT write `\`\`\`json` blocks
  pretending to be tool output — those are hallucinations.
- Copy values from tool output verbatim.
''';

// ---------------------------------------------------------------------------
// Per-trial result
// ---------------------------------------------------------------------------

class _Trial {
  _Trial({
    required this.specId,
    required this.variant,
    required this.replicate,
    required this.passed,
    required this.knownFail,
    required this.turns,
    required this.fenceCount,
    required this.reason,
  });
  final String specId;
  final String variant; // 'A' | 'B'
  final int replicate; // 1..N
  final bool passed;
  final bool knownFail;
  final int turns;
  final int fenceCount;
  final String reason;

  Map<String, Object?> toJson() => {
        'spec': specId,
        'variant': variant,
        'replicate': replicate,
        'passed': passed,
        'knownFail': knownFail,
        'turns': turns,
        'fenceCount': fenceCount,
        'reason': reason,
      };
}

// ---------------------------------------------------------------------------
// Single trial runner — distilled from run_bash_bench.dart
// ---------------------------------------------------------------------------

final _fenceRe = RegExp(r'```(?:monty|python|py)\s*\n?([\s\S]*?)```');

Future<_Trial> _runOne({
  required LlamaEngine engine,
  required MontyRuntime monty,
  required WasmHost wasmHost,
  required BashSpec spec,
  required String variant,
  required String systemPrompt,
  required int replicate,
}) async {
  await wasmHost.resetSession();
  await wasmHost.loadTree(bashVfs);

  final session = ChatSession(engine, systemPrompt: systemPrompt);
  session.addMessage(LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: spec.prompt,
  ));

  final fences = <String>[];
  final stdouts = <String>[];
  var finalProse = '';
  var asstTurns = 0;

  for (var turn = 0; turn < spec.maxTurns; turn++) {
    final buf = StringBuffer();
    await for (final chunk in session.create(
      const [],
      params: const GenerationParams(temp: 1.0, topP: 0.95),
    )) {
      final s = chunk.choices.firstOrNull?.delta.content;
      if (s != null) buf.write(s);
    }
    final reply = buf.toString().trim();
    asstTurns++;

    final matches = _fenceRe.allMatches(reply).toList();
    if (matches.isEmpty) {
      finalProse = reply;
      break;
    }

    var failed = false;
    var result = '';
    for (final m in matches) {
      final code = m.group(1)!.trim();
      if (code.isEmpty) continue;
      fences.add(code);
      final r = await monty.execute(code).result;
      if (r.error != null) {
        result = 'Error: ${r.error!.message}';
        failed = true;
        break;
      }
      final out = (r.printOutput ?? '').trim();
      stdouts.add(out);
      result = out.isEmpty ? '(empty)' : out;
    }

    if (!failed && matches.isNotEmpty) {
      final tail = reply.substring(matches.last.end).trim();
      if (tail.isNotEmpty) {
        finalProse = tail;
        break;
      }
    }

    if (failed) {
      session.addMessage(LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'tool_output:\n$result\n\n'
            'That fence errored. Rewrite it to run successfully and '
            'tell me the result.',
      ));
      continue;
    }

    session.addMessage(LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'tool_output:\n$result\n\nNow tell me the answer in '
          'plain prose using the EXACT values you saw.',
    ));
  }

  final v = spec.verify(
    finalProse: finalProse,
    fences: fences,
    stdouts: stdouts,
  );
  return _Trial(
    specId: spec.id,
    variant: variant,
    replicate: replicate,
    passed: v.ok,
    knownFail: spec.knownFail,
    turns: asstTurns,
    fenceCount: fences.length,
    reason: v.reason,
  );
}

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------

class _Agg {
  int passes = 0;
  int trials = 0;
  int totalTurns = 0;
  int totalFences = 0;
  void add(_Trial t) {
    trials++;
    totalTurns += t.turns;
    totalFences += t.fenceCount;
    if (t.passed) passes++;
  }

  String fmt() {
    if (trials == 0) return '—';
    final rate = passes / trials;
    final avgTurns = totalTurns / trials;
    final avgFences = totalFences / trials;
    return '${(rate * 100).toStringAsFixed(0)}% '
        '(${passes}/${trials})  '
        'turns=${avgTurns.toStringAsFixed(1)} '
        'fences=${avgFences.toStringAsFixed(1)}';
  }
}

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

class _Args {
  _Args({required this.replicates, required this.only});
  final int replicates;
  final Set<String>? only;
}

_Args _parseArgs(List<String> argv) {
  var replicates = 3;
  Set<String>? only;
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--replicates' && i + 1 < argv.length) {
      replicates = int.parse(argv[++i]);
    } else if (a == '--only' && i + 1 < argv.length) {
      only = argv[++i].split(',').map((s) => s.trim()).toSet();
    }
  }
  return _Args(replicates: replicates, only: only);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);

  if (!File(_dylibPath).existsSync()) {
    stderr.writeln('libwasm_host.dylib not built at $_dylibPath');
    exit(2);
  }
  if (!File(_wasmPath).existsSync()) {
    stderr.writeln('wasm_guest.wasm not built at $_wasmPath');
    exit(2);
  }

  final specs = args.only == null
      ? bashSpecs
      : bashSpecs.where((s) => args.only!.contains(s.id)).toList();
  if (specs.isEmpty) {
    stderr.writeln('No specs matched --only filter');
    exit(2);
  }

  final variants = <({String name, String prompt})>[
    (name: 'A', prompt: _promptA),
    (name: 'B', prompt: _promptB),
  ];

  final totalTrials = specs.length * variants.length * args.replicates;
  stdout.writeln(
    'A/B prompt comparison: ${specs.length} specs × ${variants.length} '
    'variants × ${args.replicates} replicates = $totalTrials trials',
  );

  stdout.writeln('Loading Gemma 4 …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(
    _modelPath,
    modelParams: ModelParams(contextSize: 8192),
  );

  final wasmHost = await openFfi(libraryPath: _dylibPath);
  final monty = MontyRuntime(os: defaultOsHandler());
  final wasmBytes = File(_wasmPath).readAsBytesSync();
  final guest = wasmHost.loadGuest(wasmBytes);
  await guest.warmup();
  monty.register(buildRunBashFunction(guest: guest));

  final trials = <_Trial>[];
  // Per-spec-per-variant aggregate.
  final perSpec = <String, Map<String, _Agg>>{};
  // Per-variant overall aggregate.
  final perVariant = <String, _Agg>{
    for (final v in variants) v.name: _Agg(),
  };

  // Outer loop is replicate, then spec, then variant. Means each
  // replicate completes a full A/B sweep across all specs before
  // starting the next round — useful if the run is interrupted, the
  // partial results are still balanced.
  for (var rep = 1; rep <= args.replicates; rep++) {
    for (final spec in specs) {
      for (final variant in variants) {
        final idx = trials.length + 1;
        stdout.writeln(
          '\n[$idx/$totalTrials] ${spec.id} variant=${variant.name} '
          'rep=$rep',
        );
        final t = await _runOne(
          engine: engine,
          monty: monty,
          wasmHost: wasmHost,
          spec: spec,
          variant: variant.name,
          systemPrompt: variant.prompt,
          replicate: rep,
        );
        trials.add(t);
        perVariant[variant.name]!.add(t);
        perSpec
            .putIfAbsent(spec.id, () => {for (final v in variants) v.name: _Agg()})[variant.name]!
            .add(t);
        final mark = !t.passed && t.knownFail
            ? '△'
            : t.passed
                ? '✓'
                : '✗';
        stdout.writeln(
          '  $mark ${t.passed ? 'PASS' : 'FAIL'} '
          'turns=${t.turns} fences=${t.fenceCount} — ${t.reason}',
        );
      }
    }
  }

  // -----------------------------------------------------------------------
  // Per-spec table
  // -----------------------------------------------------------------------
  stdout.writeln('\n========= per-spec pass-rate (A vs B) =========');
  stdout.writeln(
    '${'spec'.padRight(34)}  ${'A'.padRight(28)}  ${'B'.padRight(28)}  delta',
  );
  for (final spec in specs) {
    final a = perSpec[spec.id]!['A']!;
    final b = perSpec[spec.id]!['B']!;
    final aRate = a.trials == 0 ? 0.0 : a.passes / a.trials;
    final bRate = b.trials == 0 ? 0.0 : b.passes / b.trials;
    final delta = bRate - aRate;
    final deltaStr = delta == 0
        ? '  0'
        : (delta > 0 ? '+' : '') + (delta * 100).toStringAsFixed(0) + '%';
    final note = spec.knownFail ? ' [known-fail]' : '';
    stdout.writeln(
      '${spec.id.padRight(34)}  '
      '${a.fmt().padRight(28)}  '
      '${b.fmt().padRight(28)}  '
      '$deltaStr$note',
    );
  }

  // -----------------------------------------------------------------------
  // Overall
  // -----------------------------------------------------------------------
  stdout.writeln('\n========= overall =========');
  stdout.writeln('A (peer tools / multi-tool):    ${perVariant['A']!.fmt()}');
  stdout.writeln('B (single-fence / Python-first): ${perVariant['B']!.fmt()}');

  // -----------------------------------------------------------------------
  // Wins / flakies
  // -----------------------------------------------------------------------
  final aWins = <String>[];
  final bWins = <String>[];
  final flakies = <String>[];
  for (final spec in specs) {
    final a = perSpec[spec.id]!['A']!;
    final b = perSpec[spec.id]!['B']!;
    if (a.passes > b.passes) aWins.add(spec.id);
    if (b.passes > a.passes) bWins.add(spec.id);
    final aFlaky = a.passes != 0 && a.passes != a.trials;
    final bFlaky = b.passes != 0 && b.passes != b.trials;
    if (aFlaky || bFlaky) flakies.add(spec.id);
  }
  stdout.writeln('\nA > B on: ${aWins.isEmpty ? '(none)' : aWins.join(', ')}');
  stdout.writeln('B > A on: ${bWins.isEmpty ? '(none)' : bWins.join(', ')}');
  stdout.writeln(
    'flaky (passed in some replicates, not others): '
    '${flakies.isEmpty ? '(none)' : flakies.join(', ')}',
  );

  // -----------------------------------------------------------------------
  // JSON dump
  // -----------------------------------------------------------------------
  final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
  final jsonPath = '/tmp/bash_ab_$ts.json';
  await File(jsonPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'replicates': args.replicates,
      'specs': specs.map((s) => s.id).toList(),
      'overall': {
        'A': {
          'passes': perVariant['A']!.passes,
          'trials': perVariant['A']!.trials,
        },
        'B': {
          'passes': perVariant['B']!.passes,
          'trials': perVariant['B']!.trials,
        },
      },
      'trials': trials.map((t) => t.toJson()).toList(),
    }),
  );
  stdout.writeln('\nFull trial dump: $jsonPath');

  await wasmHost.dispose();
  await monty.dispose();
  await engine.dispose();
}
