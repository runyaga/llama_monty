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

CRITICAL — surfacing data:
  Only `print(x)` shows me a value. Bare expressions, list literals,
  dict literals, and function return values do NOT display. If you
  want me to see something, ALWAYS wrap it in `print(...)`.

  WRONG (I will see nothing):
      data[0]                # bare expression — silent
      [1, 2, 3]              # list literal — silent
      def f(): return 42
      f()                    # function return — silent

  RIGHT:
      print(data[0])
      print([1, 2, 3])
      print(f())

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
  required List<String> fences,
  required List<String> printOutputs,
});

class TestCase {
  TestCase({
    required this.id,
    required this.prompt,
    required this.verify,
    this.usesSandbox = false,
    this.maxTurns = 8,
    this.knownFail = false,
  });
  final String id;
  final String prompt;
  final VerifyFn verify;
  final bool usesSandbox;
  // Some tests assert the model STOPS after a small number of turns
  // (e.g. a one-fence comparison should not spin into 8 fences).
  final int maxTurns;
  // Stretch tests we expect to fail with Gemma 4 E2B. Marked △ in the
  // summary; failure does NOT fail the run.
  final bool knownFail;
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
    required this.fences,
    required this.printOutputs,
    this.knownFail = false,
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
  // Every fence the model emitted (in order). Tests that assert the
  // model used `print(` somewhere check this list.
  final List<String> fences;
  // The printOutput of each successful fence run, in the same order
  // as `fences`. Lets tests check what the LLM actually saw.
  final List<String> printOutputs;
  final bool knownFail;
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
  final fences = <String>[];
  final printOutputs = <String>[];
  var finalProse = '';

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
      finalProse = reply;
      log('done', 'no fence; treating reply as final');
      break;
    }
    fences.add(code);
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
          printOutputs.add(out);
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

  final v = await tc.verify(
    monty: monty,
    finalProse: finalProse,
    fences: fences,
    printOutputs: printOutputs,
  );
  return TestResult(
    id: tc.id,
    passed: v.ok,
    reason: v.reason,
    turns: turns,
    retries: retries,
    transcript: t.toString(),
    finalProse: finalProse,
    fences: List.unmodifiable(fences),
    printOutputs: List.unmodifiable(printOutputs),
    knownFail: tc.knownFail,
  );
}

// ---------------------------------------------------------------------------
// Fixture seed.
// ---------------------------------------------------------------------------

// Known fixture contents — every test that references a fixture file
// can predict the exact bytes here. Tests that read these files assert
// against these literal strings.
const _welcomeMd = '# llama_monty — welcome\n'
    'This is a tiny in-memory filesystem mounted at /tmp/fixtures/.\n'
    'The llama is a friendly mammal.\n';
const _notesTxt = '- bridge: tool-call grammar still drops on web\n'
    '- llama: cute mammal\n'
    '- next: streaming + drag-drop fixtures\n';

Future<void> _seedFixtures(MontyRuntime monty) async {
  // Wipe /tmp/state and /tmp/fixtures so each test starts pristine.
  // Re-write known fixture bytes so tests can compare against literals.
  final script = '''
from pathlib import Path
state = Path('/tmp/state')
if state.exists():
    for p in state.iterdir():
        if p.is_file():
            p.unlink()
state.mkdir(parents=True, exist_ok=True)

fixtures = Path('/tmp/fixtures')
fixtures.mkdir(parents=True, exist_ok=True)
for p in fixtures.iterdir():
    if p.is_file():
        p.unlink()

Path('/tmp/fixtures/sample.csv').write_text("""name,quantity,price
apples,12,0.45
bananas,5,0.20
cherries,30,0.10
""")
Path('/tmp/fixtures/welcome.md').write_text(${_pyStr(_welcomeMd)})
Path('/tmp/fixtures/notes.txt').write_text(${_pyStr(_notesTxt)})
''';
  final r = await monty.execute(script).result;
  if (r.error != null) {
    stderr.writeln('seed failed: ${r.error!.message}');
  }
}

/// Renders [s] as a triple-quoted Python literal, escaping `"""` to
/// avoid breaking the outer fence.
String _pyStr(String s) {
  final escaped = s.replaceAll('"""', r'\"\"\"');
  return '"""$escaped"""';
}

// ---------------------------------------------------------------------------
// Verify-helper toolbox: build a verify closure from declarative checks.
// ---------------------------------------------------------------------------

({bool ok, String reason}) _checks({
  required List<String> fences,
  required String finalProse,
  required List<String> printOutputs,
  String? fenceContains,
  Iterable<String>? proseContainsAll,
  Iterable<String>? proseContainsAny,
  Iterable<String>? proseDoesNotContain,
  String? printContains,
  Iterable<String>? printContainsAll,
}) {
  if (fenceContains != null &&
      !fences.any((f) => f.contains(fenceContains))) {
    return (ok: false, reason: 'no fence contains "$fenceContains"');
  }
  if (printContains != null &&
      !printOutputs.any((o) => o.contains(printContains))) {
    return (ok: false, reason: 'no printOutput contains "$printContains"');
  }
  if (printContainsAll != null) {
    for (final s in printContainsAll) {
      if (!printOutputs.any((o) => o.contains(s))) {
        return (ok: false, reason: 'no printOutput contains "$s"');
      }
    }
  }
  if (proseContainsAll != null) {
    for (final s in proseContainsAll) {
      if (!finalProse.contains(s)) {
        return (
          ok: false,
          reason: 'prose missing "$s" — got: '
              '"${_truncate(finalProse, 200)}"',
        );
      }
    }
  }
  if (proseContainsAny != null) {
    if (!proseContainsAny.any((s) => finalProse.contains(s))) {
      return (
        ok: false,
        reason: 'prose contains none of $proseContainsAny — got: '
            '"${_truncate(finalProse, 200)}"',
      );
    }
  }
  if (proseDoesNotContain != null) {
    for (final s in proseDoesNotContain) {
      if (finalProse.contains(s)) {
        return (
          ok: false,
          reason: 'prose contains forbidden "$s" — got: '
              '"${_truncate(finalProse, 200)}"',
        );
      }
    }
  }
  return (ok: true, reason: 'ok');
}

String _truncate(String s, int n) =>
    s.length <= n ? s : '${s.substring(0, n)}…';

VerifyFn _v({
  String? fenceContains,
  Iterable<String>? proseContainsAll,
  Iterable<String>? proseContainsAny,
  Iterable<String>? proseDoesNotContain,
  String? printContains,
  Iterable<String>? printContainsAll,
}) {
  return ({
    required monty,
    required finalProse,
    required fences,
    required printOutputs,
  }) async => _checks(
    fences: fences,
    finalProse: finalProse,
    printOutputs: printOutputs,
    fenceContains: fenceContains,
    proseContainsAll: proseContainsAll,
    proseContainsAny: proseContainsAny,
    proseDoesNotContain: proseDoesNotContain,
    printContains: printContains,
    printContainsAll: printContainsAll,
  );
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
    // ─────────── REGRESSIONS (kept from prior runs) ──────────────
    TestCase(
      id: 'D_terminal_false_stops_loop',
      prompt:
          'Are /tmp/fixtures/welcome.md and /tmp/fixtures/notes.txt '
          'identical files? Reply with a clear yes or no.',
      maxTurns: 3,
      verify: _v(proseContainsAny: ['No', 'no', 'differ', 'not the same']),
    ),
    TestCase(
      id: 'C_sandbox_factorial',
      prompt: 'Use sandbox_spawn to compute factorial(10) inside a child '
          'sandbox and print the result back here. math.factorial is '
          'available inside the child.',
      usesSandbox: true,
      knownFail: true, // upstream dart_monty sandbox bug (issue #422)
      verify: _v(proseContainsAny: ['3628800']),
    ),

    // ─────────── TIER 1: print of literals ───────────────────────
    TestCase(id: 'T01_print_int', prompt: 'Print the integer 42.',
        maxTurns: 3, verify: _v(printContains: '42', proseContainsAll: ['42'])),
    TestCase(id: 'T02_print_str', prompt: "Print the string 'hello world'.",
        maxTurns: 3, verify: _v(printContains: 'hello world',
            proseContainsAll: ['hello world'])),
    TestCase(id: 'T03_print_float', prompt: 'Print the float 3.14.',
        maxTurns: 3, verify: _v(printContains: '3.14',
            proseContainsAll: ['3.14'])),
    TestCase(id: 'T04_print_bool', prompt: 'Print the boolean True.',
        maxTurns: 3, verify: _v(printContains: 'True',
            proseContainsAll: ['True'])),
    TestCase(id: 'T05_print_none', prompt: 'Print the value None.',
        maxTurns: 3, verify: _v(printContains: 'None',
            proseContainsAll: ['None'])),

    // ─────────── TIER 2: print of basic compute ──────────────────
    TestCase(id: 'T06_print_arith', prompt: 'Compute 7 * 8 and print it.',
        maxTurns: 3,
        verify: _v(fenceContains: 'print(', printContains: '56',
            proseContainsAll: ['56'])),
    TestCase(id: 'T07_print_concat',
        prompt: "Print 'hello ' + 'world'.",
        maxTurns: 3,
        verify: _v(printContains: 'hello world',
            proseContainsAll: ['hello world'])),
    TestCase(id: 'T08_print_len',
        prompt: "Print the length of 'python' using len().",
        maxTurns: 3, verify: _v(printContains: '6',
            proseContainsAll: ['6'])),
    TestCase(id: 'T09_print_max',
        prompt: 'Print the max of [3, 7, 2, 8, 5].',
        maxTurns: 3, verify: _v(printContains: '8',
            proseContainsAll: ['8'])),
    TestCase(id: 'T10_print_round',
        prompt: 'Print 22/7 rounded to 4 decimals using round().',
        maxTurns: 3,
        verify: _v(fenceContains: 'round(', printContains: '3.1429',
            proseContainsAll: ['3.1429'])),

    // ─────────── TIER 3: print of function results ───────────────
    TestCase(id: 'T11_print_func_return',
        prompt: 'Define square(n) returning n*n. Print square(7).',
        maxTurns: 3,
        verify: _v(fenceContains: 'def square', printContains: '49',
            proseContainsAll: ['49'])),
    TestCase(id: 'T12_print_in_func',
        prompt: "Define greet(name) that prints 'hi ' + name. "
            "Call greet('alan').",
        maxTurns: 3,
        verify: _v(fenceContains: 'def greet',
            printContains: 'hi alan',
            proseContainsAll: ['hi alan'])),
    TestCase(id: 'T13_print_recursive',
        prompt: 'Define factorial(n) recursively, then print factorial(5).',
        maxTurns: 4,
        verify: _v(fenceContains: 'def factorial',
            printContains: '120', proseContainsAll: ['120'])),
    TestCase(id: 'T14_print_default_arg',
        prompt: "Define greet(name='world') returning 'hi ' + name. "
            'Print greet().',
        maxTurns: 3,
        verify: _v(printContains: 'hi world',
            proseContainsAll: ['hi world'])),
    TestCase(id: 'T15_print_multi_arg',
        prompt: 'Define avg(a, b, c) returning (a+b+c)/3. '
            'Print avg(2, 4, 6).',
        maxTurns: 3,
        verify: _v(printContainsAll: ['4'], proseContainsAll: ['4'])),

    // ─────────── TIER 4: state across fences ─────────────────────
    TestCase(id: 'T16_state_int',
        prompt: 'In a first fence, set x = 100. In a SECOND fence, '
            'print(x + 1).',
        maxTurns: 4,
        verify: _v(printContains: '101', proseContainsAll: ['101'])),
    TestCase(id: 'T17_state_func',
        prompt: 'Fence 1: define greet(n) returning \'hi \' + n. '
            "Fence 2: print(greet('a')).",
        maxTurns: 4,
        verify: _v(printContains: 'hi a',
            proseContainsAll: ['hi a'])),
    TestCase(id: 'T18_state_list',
        prompt: 'Fence 1: lst = [1, 2, 3]. Fence 2: print(sum(lst)).',
        maxTurns: 4,
        verify: _v(printContains: '6', proseContainsAll: ['6'])),
    TestCase(id: 'T19_state_dict',
        prompt: "Fence 1: d = {'a': 1, 'b': 2}. "
            "Fence 2: print(d['a'] + d['b']).",
        maxTurns: 4,
        verify: _v(printContains: '3', proseContainsAll: ['3'])),
    TestCase(id: 'T20_state_acc',
        prompt: 'Fence 1: total = 0. Fence 2: total = total + 10. '
            'Fence 3: print(total).',
        maxTurns: 5,
        verify: _v(printContains: '10', proseContainsAll: ['10'])),

    // ─────────── TIER 5: print of file-derived values ────────────
    TestCase(id: 'T21_file_first_line',
        prompt: 'Print the FIRST non-blank line of '
            '/tmp/fixtures/welcome.md.',
        maxTurns: 3,
        verify: _v(printContains: '# llama_monty',
            proseContainsAll: ['llama_monty', 'welcome'])),
    TestCase(id: 'T22_file_csv_header',
        prompt: 'Print just the column header line of '
            '/tmp/fixtures/sample.csv.',
        maxTurns: 3,
        verify: _v(printContains: 'name,quantity,price',
            proseContainsAll: ['name,quantity,price'])),
    TestCase(id: 'T23_file_row_count',
        prompt: 'Print the integer number of DATA rows in '
            '/tmp/fixtures/sample.csv (excluding the header line).',
        maxTurns: 3,
        verify: _v(printContains: '3', proseContainsAll: ['3'])),
    TestCase(id: 'T24_file_filenames',
        prompt: 'Print each filename in /tmp/fixtures/ on its own line.',
        maxTurns: 3,
        verify: _v(printContainsAll: ['sample.csv', 'welcome.md', 'notes.txt'],
            proseContainsAll: ['sample.csv'])),
    TestCase(id: 'T25_file_write_read',
        prompt: "Write 'hello' to /tmp/state/g.txt. Read it back and "
            'print the contents.',
        maxTurns: 3,
        verify: _v(printContains: 'hello', proseContainsAll: ['hello'])),

    // ─────────── TIER 6: grounding (prose echoes real values) ────
    TestCase(id: 'T26_ground_count',
        prompt: 'How many data rows are in /tmp/fixtures/sample.csv '
            '(excluding the header)?',
        maxTurns: 3,
        verify: _v(proseContainsAll: ['3'],
            proseDoesNotContain: ['name,age,city', 'age', 'city'])),
    TestCase(id: 'T27_ground_header',
        prompt: 'What is the column header line of '
            '/tmp/fixtures/sample.csv? Quote it exactly.',
        maxTurns: 3,
        verify: _v(proseContainsAll: ['name', 'quantity', 'price'],
            proseDoesNotContain: ['age', 'city'])),
    TestCase(id: 'T28_ground_value',
        prompt: 'What is the price of bananas in '
            '/tmp/fixtures/sample.csv?',
        maxTurns: 3,
        verify: _v(proseContainsAll: ['0.20'],
            proseDoesNotContain: ['0.50', '1.00'])),
    TestCase(id: 'T29_ground_max',
        prompt: 'Which item in /tmp/fixtures/sample.csv has the '
            'HIGHEST price?',
        maxTurns: 4,
        verify: _v(proseContainsAll: ['apples'])),
    TestCase(id: 'T30_ground_avg',
        prompt: 'What is the AVERAGE price across all rows in '
            '/tmp/fixtures/sample.csv? Round to 2 decimals.',
        maxTurns: 4,
        verify: _v(proseContainsAll: ['0.25'])),

    // ─────────── TIER 7: hard / known-fail ───────────────────────
    TestCase(id: 'T31_dict_print_complex',
        prompt: "Print the dict {'a': [1, 2, 3], 'b': {'nested': True}}.",
        maxTurns: 3,
        knownFail: true,
        verify: _v(printContainsAll: ['1, 2, 3', 'nested', 'True'],
            proseContainsAll: ['1, 2, 3'])),
    TestCase(id: 'T32_unicode_emdash',
        prompt: 'Print only the line of /tmp/fixtures/welcome.md '
            'that contains an em-dash (—).',
        maxTurns: 4,
        knownFail: true,
        verify: _v(printContains: '—',
            proseContainsAll: ['—', 'llama_monty'])),
    TestCase(id: 'T33_sort_csv_pivot',
        prompt: 'Print all data rows of /tmp/fixtures/sample.csv sorted '
            'by price DESCENDING, one row per line.',
        maxTurns: 5,
        knownFail: true,
        verify: _v(
            printContainsAll: ['apples', 'bananas', 'cherries'],
            proseContainsAll: ['apples'])),
    TestCase(id: 'T34_stddev_no_format',
        prompt: 'Compute the standard deviation of the prices in '
            '/tmp/fixtures/sample.csv (use math.sqrt). Print the result '
            'rounded to 4 decimals using round() — do NOT use .format() '
            'or % formatting.',
        maxTurns: 5,
        knownFail: true,
        verify: _v(
            // stddev of [0.45, 0.20, 0.10] = ~0.1471 (population)
            // or ~0.1803 (sample). Either is a stretch.
            proseContainsAny: ['0.14', '0.15', '0.18'],
            proseDoesNotContain: ['.format(', '%.', '"%s"'])),
    TestCase(id: 'T35_multistep_grounded',
        prompt: 'Read /tmp/fixtures/sample.csv, find the item with the '
            'lowest price and the item with the highest price, write '
            "{'min_item': name, 'max_item': name} as JSON to "
            "/tmp/state/extremes.json, then in your final reply name "
            'BOTH items by their actual names from the file.',
        maxTurns: 8,
        knownFail: true,
        verify: ({
          required monty,
          required finalProse,
          required fences,
          required printOutputs,
        }) async {
          // Side-effect: file written with right names.
          final r = await monty.execute('''
from pathlib import Path
import json
p = Path('/tmp/state/extremes.json')
if p.exists():
    d = json.loads(p.read_text())
    print(f"min={d.get('min_item')} max={d.get('max_item')}")
else:
    print('MISSING')
''').result;
          final out = (r.printOutput ?? '').trim();
          if (out.startsWith('MISSING')) {
            return (ok: false, reason: 'extremes.json not written');
          }
          if (!out.contains('min=cherries') ||
              !out.contains('max=apples')) {
            return (ok: false, reason: 'wrong items: $out');
          }
          if (!finalProse.contains('apples') ||
              !finalProse.contains('cherries')) {
            return (
              ok: false,
              reason: 'prose missing item names: '
                  '"${_truncate(finalProse, 200)}"',
            );
          }
          return (ok: true, reason: out);
        },
    ),
  ];

  final results = <TestResult>[];
  for (final tc in tests) {
    stdout.writeln('\n========= ${tc.id} =========');
    final monty = await makeRuntime(sandbox: tc.usesSandbox);
    final result = await runOne(engine: engine, monty: monty, tc: tc);
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
    final mark = !passed && tc.knownFail
        ? '△'
        : passed
            ? '✓'
            : '✗';
    stdout.writeln(
      'result: $mark ${passed ? 'PASS' : 'FAIL'} '
      '(turns=${result.turns}, retries=${result.retries}) — $reason'
      '${tc.knownFail && !passed ? ' [known-fail]' : ''}',
    );
    results.add(TestResult(
      id: result.id,
      passed: passed,
      reason: reason,
      turns: result.turns,
      retries: result.retries,
      transcript: result.transcript,
      finalProse: result.finalProse,
      fences: result.fences,
      printOutputs: result.printOutputs,
      knownFail: tc.knownFail,
    ));
    await monty.dispose();
  }

  stdout.writeln('\n========= summary =========');
  for (final r in results) {
    final mark = !r.passed && r.knownFail
        ? '△'
        : r.passed
            ? '✓'
            : '✗';
    stdout.writeln(
      '$mark ${r.id.padRight(30)} turns=${r.turns} retries=${r.retries} — '
      '${_truncate(r.reason, 100)}',
    );
  }
  final passed = results.where((r) => r.passed).length;
  final unexpectedFail =
      results.where((r) => !r.passed && !r.knownFail).length;
  final knownFail = results.where((r) => !r.passed && r.knownFail).length;
  stdout.writeln(
    '\n$passed PASS · $unexpectedFail FAIL · $knownFail △ known-fail '
    '(of ${results.length})',
  );

  await engine.dispose();
}
