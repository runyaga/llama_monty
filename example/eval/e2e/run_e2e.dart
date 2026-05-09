// End-to-end integration harness that mirrors the web app's _send() loop
// against Gemma 4 FFI. Three independent test cases probe the failure
// modes the user has been hitting in the UI:
//
//   A — single-fence pathlib task: does the model stay on pathlib /
//       does the pre-flight + context-reset retry actually push it
//       off `import os` / `with open` when it slips?
//   B — multi-step task with side-effect verification: does iterative
//       decomposition actually complete a real task end-to-end?
//   C — sandbox subagent: does `sandbox_spawn` with shared VFS run a
//       child and bring its result back?
//
// Each test gets a FRESH ChatSession + MontyRuntime so the failure
// modes are measured independently. Per-test transcript is printed so
// we can see exactly where things diverge.
//
// Run: dart run example/eval/e2e/run_e2e.dart

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

// Keep in sync with example/llama_monty_web/lib/main.dart::_webSystemPrompt.
const _systemPrompt = '''
You DO have a working filesystem and a working Python interpreter. The
sandbox mounts `/tmp/fixtures/` (read-write, pre-seeded) and `/tmp/`
(read-write). NEVER refuse on grounds of "I am an AI without filesystem
access" — read/write the files via pathlib.

You write SMALL Monty programs in ```monty fences. Variables and
imports persist across fences, so each turn does one step:

```monty
from pathlib import Path
data = Path('/tmp/fixtures/sample.csv').read_text().splitlines()
print(len(data), 'rows; header:', data[0])
```

Read the printed output, then write the NEXT small fence using what
you saw. Don't pack everything into one fence.

For verbose work, hand it to a child sandbox — only the child's
final print() bubbles back here:

```monty
h = sandbox_spawn("...code as a string... ; print(answer)")
print(sandbox_await(h))
sandbox_free(h)
```

Monty is a Python 3 SUBSET. ALWAYS:
  print(x)
  from pathlib import Path
  Path(p).read_text()
  Path(p).write_text("hello")
  for p in Path('/tmp').iterdir(): print(p)
NEVER:
  import os
  print x
  with open(p):
  class X:
  "{:.2f}".format(x)
  "%.2f" % x
Allowed modules: math, re, json, datetime, pathlib.
Every if/for/while/def header ends with `:`. Use simple f-strings.

DO NOT wrap calls in try/except just to print the error — let errors
surface so the system can correct your code.

When the printed output IS the answer to the user's question, REPLY
IN PLAIN PROSE WITHOUT A FENCE. The harness only knows you are done
when you stop writing fences. One fence per question once you have
the answer.

For tasks that genuinely need multiple separate steps (each step
depends on the previous step's output, or the steps are too big for
a single fence), you MAY write a checklist to `/tmp/state/PLAN.md`
to track progress. Don't do this for simple tasks — one fence is
fine when the answer fits.
''';

// ---------------------------------------------------------------------------
// Helpers (copied from main.dart so the harness is self-contained).
// ---------------------------------------------------------------------------

String? _extractFence(String text) {
  final m = RegExp(
    r'```(?:monty|python|py)?\s*\n?([\s\S]*?)```',
  ).firstMatch(text);
  final code = m?.group(1)?.trim();
  return (code != null && code.isNotEmpty) ? code : null;
}

String? _preflight(String code) {
  if (RegExp(r'(^|\n)\s*import\s+os\b').hasMatch(code) ||
      RegExp(r'(^|\n)\s*from\s+os\b').hasMatch(code)) {
    return 'The `os` module is not available. Use pathlib: '
        '`from pathlib import Path`, then `Path(p).iterdir()`, '
        '`Path(p).read_text()`, `Path(p).write_text(s)`.';
  }
  if (RegExp(r'\bwith\s+open\b').hasMatch(code)) {
    return 'Context managers (`with`) are not supported. Use '
        '`Path(p).read_text()` / `Path(p).write_text(s)`.';
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
      RegExp(
        r'\b(attribute|name|type|value|key|index|module)error\b',
      ).hasMatch(lower) ||
      RegExp(r'\bno module named\b').hasMatch(lower);
}

String _pointedNudge({required String code, required String error}) {
  final hints = <String>[];
  if (code.contains('import os')) {
    hints.add('Use pathlib instead of os.');
  }
  if (RegExp(r'\bwith\s+open\b').hasMatch(code)) {
    hints.add(
      'Replace `with open(p) as f: data = f.read()` with '
      '`data = Path(p).read_text()`.',
    );
  }
  final buf = StringBuffer('Your last attempt failed: $error\n');
  if (hints.isNotEmpty) {
    buf.writeln('Specific fixes:');
    for (final h in hints) {
      buf.writeln('  • $h');
    }
  }
  buf.write('Rewrite the program from scratch using pathlib.');
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Test case definition.
// ---------------------------------------------------------------------------

typedef VerifyFn = Future<({bool ok, String reason})> Function({
  required MontyRuntime monty,
  required String finalProse,
});

class TestCase {
  TestCase({
    required this.id,
    required this.prompt,
    required this.verify,
    this.usesSandbox = false,
    this.maxTurns = 8,
  });
  final String id;
  final String prompt;
  final VerifyFn verify;
  final bool usesSandbox;
  // Some tests assert the model STOPS after a small number of turns
  // (e.g. a one-fence comparison should not spin into 8 fences).
  final int maxTurns;
}

class TestResult {
  TestResult({
    required this.id,
    required this.passed,
    required this.reason,
    required this.turns,
    required this.retries,
    required this.transcript,
    required this.finalProse,
  });
  final String id;
  final bool passed;
  final String reason;
  final int turns;
  final int retries;
  final String transcript;
  // The model's last NON-fence assistant reply — i.e. the prose answer
  // after the last successful fence. Used by tests that check whether
  // the LLM hallucinates (claims values that aren't in the tool output).
  final String finalProse;
}

// ---------------------------------------------------------------------------
// Runner — mirrors _send() with context-reset retry.
// ---------------------------------------------------------------------------

Future<TestResult> runOne({
  required LlamaEngine engine,
  required MontyRuntime monty,
  required TestCase tc,
  int maxRetries = 4,
}) async {
  final maxTurns = tc.maxTurns;
  final session = ChatSession(engine, systemPrompt: _systemPrompt);
  final t = StringBuffer();
  void log(String tag, String s) => t.writeln('[$tag] $s');

  log('user', tc.prompt);
  String currentPrompt = tc.prompt;
  var retries = 0;
  var turns = 0;

  // Send first user turn.
  session.addMessage(
    LlamaChatMessage.fromText(role: LlamaChatRole.user, text: currentPrompt),
  );

  while (turns < maxTurns) {
    turns++;
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

    final code = _extractFence(reply);
    if (code == null) {
      // No fence => model produced final prose; loop ends.
      log('done', 'no fence; treating reply as final');
      break;
    }
    log('code', code);

    String result;
    bool failed;
    final pre = _preflight(code);
    if (pre != null) {
      result = 'Error: $pre';
      failed = true;
    } else {
      final r = await monty.execute(code).result;
      if (r.error != null) {
        result = 'Error: ${r.error!.message}';
        failed = true;
      } else {
        final out = (r.printOutput ?? '').trim();
        if (_looksLikeSwallowedError(out)) {
          result = 'Error (swallowed by try/except): $out';
          failed = true;
        } else {
          result = out.isEmpty ? '(no output)' : out;
          failed = false;
        }
      }
    }
    log(failed ? 'tool-error' : 'tool-output', result);

    if (failed) {
      if (retries >= maxRetries) {
        log('done', 'max retries hit');
        break;
      }
      retries++;
      // CONTEXT RESET: drop history, replay original prompt + hint.
      final hint = _pointedNudge(code: code, error: result);
      currentPrompt =
          '${tc.prompt}\n\n'
          'NOTE: a previous attempt at this task failed. '
          'Read the correction below and rewrite the program from scratch.\n\n'
          '$hint';
      session.reset();
      session.addMessage(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: currentPrompt,
        ),
      );
      log('retry', 'context reset, retry $retries/$maxRetries');
      continue;
    }

    // Success: feed tool result back as a synthetic user message so the
    // model can react / continue / chain into the next step. Keeps the
    // assistant message in history for the multi-step case.
    session.addMessage(
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'tool_output:\n$result\n\nIs the task done? '
            'If yes, reply without a fence. If not, write the next fence.',
      ),
    );
  }

  final v = await tc.verify(monty);
  return TestResult(
    id: tc.id,
    passed: v.ok,
    reason: v.reason,
    turns: turns,
    retries: retries,
    transcript: t.toString(),
  );
}

// ---------------------------------------------------------------------------
// Fixture seed.
// ---------------------------------------------------------------------------

Future<void> _seedFixtures(MontyRuntime monty) async {
  // Wipe /tmp/state so each test starts with a fresh PLAN.md.
  // Recreate /tmp/state empty so the model has a writable directory.
  const script = '''
from pathlib import Path
Path('/tmp/fixtures').mkdir(parents=True, exist_ok=True)
Path('/tmp/fixtures/sample.csv').write_text("""name,quantity,price
apples,12,0.45
bananas,5,0.20
cherries,30,0.10
""")
state = Path('/tmp/state')
if state.exists():
    for p in state.iterdir():
        if p.is_file():
            p.unlink()
state.mkdir(parents=True, exist_ok=True)
''';
  final r = await monty.execute(script).result;
  if (r.error != null) {
    stderr.writeln('seed failed: ${r.error!.message}');
  }
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('Loading Gemma 4 …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(
    _modelPath,
    modelParams: ModelParams(contextSize: 8192),
  );
  final engineRef = LlamaEngineRef(engine);

  Future<MontyRuntime> makeRuntime({bool sandbox = false}) async {
    final monty = MontyRuntime(
      os: defaultOsHandler(),
      extensions: [
        LlamaMontyPlugin(engineRef),
        if (sandbox)
          SandboxExtension(
            platformFactory: () async => createPlatformMonty(),
            childVfsStrategy: ChildVfsStrategy.shared,
          ),
      ],
    );
    await _seedFixtures(monty);
    return monty;
  }

  final tests = [
    TestCase(
      id: 'A_single_fence_pathlib',
      prompt: 'List the files in /tmp/fixtures/.',
      verify: (m) async => (ok: true, reason: 'no side-effect to verify'),
    ),
    TestCase(
      id: 'B_multi_step_revenue',
      prompt:
          'Read /tmp/fixtures/sample.csv (header: name,quantity,price). '
          'Compute total revenue = sum(quantity * price) across all rows. '
          'Write the total (rounded to 2 decimals) to /tmp/revenue.txt.',
      verify: (m) async {
        final r = await m.execute('''
from pathlib import Path
p = Path('/tmp/revenue.txt')
if p.exists():
    print('EXISTS:' + p.read_text().strip())
else:
    print('MISSING')
''').result;
        final out = (r.printOutput ?? '').trim();
        if (!out.startsWith('EXISTS:')) {
          return (ok: false, reason: '/tmp/revenue.txt not written');
        }
        final value = double.tryParse(out.substring(7));
        if (value == null) {
          return (ok: false, reason: 'value not numeric: $out');
        }
        // 12*0.45 + 5*0.20 + 30*0.10 = 5.40 + 1.00 + 3.00 = 9.40
        const expected = 9.40;
        if ((value - expected).abs() > 0.01) {
          return (ok: false, reason: 'value=$value expected=$expected');
        }
        return (ok: true, reason: 'revenue=$value');
      },
    ),
    TestCase(
      // Regression test for "False makes the loop spin": model writes
      // `print(a == b)`, output is `False`, the loop should NOT keep
      // emitting more fences. Single fence in, single answer out —
      // the model should reply in plain prose (no fence) once it has
      // the answer. maxTurns=3 caps the loop so this test surfaces
      // the runaway behaviour: we then mark FAIL in main() if the
      // loop hit the cap (turns >= 3).
      id: 'D_terminal_false_stops_loop',
      prompt:
          'Are /tmp/fixtures/welcome.md and /tmp/fixtures/notes.txt '
          'identical files? Reply with a clear yes or no.',
      maxTurns: 3,
      verify: (m) async => (ok: true, reason: 'turn-bound check in main'),
    ),
    TestCase(
      // Multi-output side-effect: write a JSON summary.json with three
      // computed fields. Plan/PLAN.md is OPTIONAL — we don't care HOW
      // the model gets there, only that summary.json on disk has the
      // right keys with the right values.
      id: 'E_summary_json',
      prompt:
          'Compute the min price, max price, and average price across all '
          'rows in /tmp/fixtures/sample.csv. Write the final result as JSON '
          'to /tmp/state/summary.json with keys: min, max, avg (rounded to '
          '2 decimals).',
      maxTurns: 6,
      verify: (m) async {
        final r = await m.execute('''
from pathlib import Path
import json

summary = Path('/tmp/state/summary.json')
if not summary.exists():
    print('NO_SUMMARY')
else:
    data = json.loads(summary.read_text())
    print(f'min={data.get("min")} max={data.get("max")} avg={data.get("avg")}')
''').result;
        if (r.error != null) {
          return (ok: false, reason: 'verify failed: \${r.error!.message}');
        }
        final out = (r.printOutput ?? '').trim();
        if (out.startsWith('NO_SUMMARY')) {
          return (ok: false, reason: 'summary.json not written');
        }
        // Expected min=0.10, max=0.45, avg=0.25.
        final mins = RegExp(r'min=([\d.]+)').firstMatch(out)?.group(1);
        final maxs = RegExp(r'max=([\d.]+)').firstMatch(out)?.group(1);
        final avgs = RegExp(r'avg=([\d.]+)').firstMatch(out)?.group(1);
        if (mins != '0.1' && mins != '0.10') {
          return (ok: false, reason: 'min=\$mins (expected 0.10)');
        }
        if (maxs != '0.45') {
          return (ok: false, reason: 'max=\$maxs (expected 0.45)');
        }
        final avg = double.tryParse(avgs ?? '');
        if (avg == null || (avg - 0.25).abs() > 0.01) {
          return (ok: false, reason: 'avg=\$avgs (expected 0.25)');
        }
        return (ok: true, reason: 'summary={min:$mins, max:$maxs, avg:$avgs}');
      },
    ),
    TestCase(
      id: 'C_sandbox_factorial',
      prompt:
          'Use sandbox_spawn to compute factorial(10) inside a child sandbox '
          'and print the result back here. The function math.factorial is '
          'available inside the child.',
      usesSandbox: true,
      verify: (m) async {
        // Side-effect detection is via transcript check below.
        return (ok: true, reason: 'transcript-checked');
      },
    ),
  ];

  final results = <TestResult>[];
  for (final tc in tests) {
    stdout.writeln('\n========= ${tc.id} =========');
    final monty = await makeRuntime(sandbox: tc.usesSandbox);
    final result = await runOne(engine: engine, monty: monty, tc: tc);
    results.add(result);
    stdout.writeln(result.transcript);
    if (tc.id == 'C_sandbox_factorial') {
      // Special-case verification: did the transcript print 3628800 anywhere?
      final hit = result.transcript.contains('3628800');
      stdout.writeln('sandbox factorial check: ${hit ? 'PASS' : 'FAIL'}');
    }
    // For tests that ASSERT the loop should stop quickly: hitting the
    // turn cap means the model kept emitting fences past the answer.
    var passed = result.passed;
    var reason = result.reason;
    if (tc.id == 'D_terminal_false_stops_loop' &&
        result.turns >= tc.maxTurns) {
      passed = false;
      reason = 'loop hit turn cap (${result.turns}) — model kept fencing '
          'after a terminal answer';
    }
    stdout.writeln(
      'result: ${passed ? 'PASS' : 'FAIL'} '
      '(turns=${result.turns}, retries=${result.retries}) — $reason',
    );
    // Stash the adjusted result for the summary.
    if (passed != result.passed || reason != result.reason) {
      results[results.length - 1] = TestResult(
        id: result.id,
        passed: passed,
        reason: reason,
        turns: result.turns,
        retries: result.retries,
        transcript: result.transcript,
      );
    }
    await monty.dispose();
  }

  stdout.writeln('\n========= summary =========');
  for (final r in results) {
    final mark = r.passed ? '✓' : '✗';
    stdout.writeln(
      '$mark ${r.id.padRight(28)} turns=${r.turns} retries=${r.retries} — '
      '${r.reason}',
    );
  }
  final passed = results.where((r) => r.passed).length;
  stdout.writeln('\n$passed / ${results.length} PASS');

  await engine.dispose();
}
