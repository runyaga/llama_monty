// Direct probe of SandboxExtension's sandbox_spawn / sandbox_await /
// sandbox_free without the LLM in the loop. Lets us isolate whether
// sandbox_await returning None is:
//   (a) a wiring bug in our setup (childVfsStrategy, platformFactory)
//   (b) a real bug in dart_monty SandboxExtension
//   (c) the model writing the wrong sandbox_spawn code
//
// Run: dart run example/eval/e2e/sandbox_probe.dart

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> _exec(MontyRuntime monty, String label, String code) async {
  stdout.writeln('\n=== $label ===');
  stdout.writeln('code:');
  for (final line in code.trim().split('\n')) {
    stdout.writeln('    $line');
  }
  final r = await monty.execute(code).result;
  if (r.error != null) {
    stdout.writeln('ERROR: ${r.error!.message}');
    return;
  }
  final out = (r.printOutput ?? '').trim();
  stdout.writeln(out.isEmpty ? '(no print output)' : 'output: $out');
  if (r.value != null && r.value is! MontyNone) {
    stdout.writeln('return value: ${r.value} (${r.value.runtimeType})');
  }
}

Future<void> main() async {
  stdout.writeln('Setting up MontyRuntime with SandboxExtension …');
  final monty = MontyRuntime(
    os: defaultOsHandler(),
    extensions: [
      SandboxExtension(
        platformFactory: () async => createPlatformMonty(),
        childVfsStrategy: ChildVfsStrategy.shared,
      ),
    ],
  );

  // Probe 1: child prints a literal — does sandbox_await return the printed text?
  await _exec(monty, 'P1 child prints literal', '''
h = sandbox_spawn("print(42)")
v = sandbox_await(h)
print('await returned:', v)
sandbox_free(h)
''');

  // Probe 2: child prints a computed value (no imports) — same question.
  await _exec(monty, 'P2 child prints computed value', '''
h = sandbox_spawn("a = 6 * 7\\nprint(a)")
v = sandbox_await(h)
print('await returned:', v)
sandbox_free(h)
''');

  // Probe 3: child uses math.factorial — does the child have allowed modules?
  await _exec(monty, 'P3 child uses math.factorial', '''
h = sandbox_spawn("import math\\nprint(math.factorial(10))")
v = sandbox_await(h)
print('await returned:', v)
sandbox_free(h)
''');

  // Probe 4: child reads /tmp/fixtures via shared VFS.
  await _exec(monty, 'P4 child reads shared /tmp/fixtures', '''
from pathlib import Path
Path('/tmp/fixtures').mkdir(parents=True, exist_ok=True)
Path('/tmp/fixtures/probe.txt').write_text("hello from parent")

h = sandbox_spawn("from pathlib import Path\\nprint(Path('/tmp/fixtures/probe.txt').read_text())")
v = sandbox_await(h)
print('await returned:', v)
sandbox_free(h)
''');

  // Probe 5: child has multiple prints — does await return ALL of them?
  await _exec(monty, 'P5 child prints multiple lines', '''
h = sandbox_spawn("print('line1')\\nprint('line2')\\nprint('line3')")
v = sandbox_await(h)
print('await returned:', repr(v))
sandbox_free(h)
''');

  await monty.dispose();
  stdout.writeln('\nDone.');
}
