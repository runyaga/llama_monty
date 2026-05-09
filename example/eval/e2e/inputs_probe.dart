// Direct probe: confirm `MontyRuntime.execute(code, inputs: {...})`
// actually works in our pinned dart_monty 0.17.1, AND that
// `run_script(path, inputs={...})` (Python-side host fn) is callable.
//
// Run: dart run example/eval/e2e/inputs_probe.dart

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> _exec(MontyRuntime monty, String label, String code,
    {Map<String, Object?>? inputs}) async {
  stdout.writeln('\n=== $label ===');
  if (inputs != null) stdout.writeln('  inputs: $inputs');
  for (final line in code.trim().split('\n')) {
    stdout.writeln('    $line');
  }
  final r = await monty.execute(code, inputs: inputs).result;
  if (r.error != null) {
    stdout.writeln('  ERROR: ${r.error!.message}');
  } else {
    stdout.writeln('  printOutput: ${r.printOutput}');
    stdout.writeln('  value: ${r.value}');
  }
}

Future<void> main() async {
  final os = defaultOsHandler();
  final monty = MontyRuntime(os: os);

  // Register run_script the same way main.dart does. Read via the
  // shared OsCallHandler directly (NOT via runtime — would deadlock
  // because run_script is mid-flight on the bridge).
  monty.register(
    buildRunScriptFunction((path) async {
      final raw = await os('Path.read_text', [path], null);
      return raw is String ? raw : '';
    }),
  );

  // P1: simple int input
  await _exec(monty, 'P1 inputs={x: 42}', 'print(x)', inputs: {'x': 42});

  // P2: multiple typed inputs
  await _exec(monty, 'P2 mixed inputs', 'print(name, age, ratio)',
      inputs: {'name': 'alice', 'age': 30, 'ratio': 0.75});

  // P3: list input
  await _exec(monty, 'P3 list input',
      'print(sum(values))', inputs: {'values': [1, 2, 3, 4, 5]});

  // P4: dict input
  await _exec(monty, 'P4 dict input',
      "print(d['a'] + d['b'])", inputs: {
        'd': {'a': 10, 'b': 32},
      });

  // P5: write a script to disk, then run_script() it from Python.
  // The script's LAST LINE must be an expression (not an assignment)
  // for run_script() to capture its return value. `main(values)` as
  // a bare expression returns the function's return value.
  await _exec(monty, 'P5 setup: write avg.py to /tmp/llama-test/scripts/',
      r'''
from pathlib import Path
Path('/tmp/llama-test/scripts').mkdir(parents=True, exist_ok=True)
Path('/tmp/llama-test/scripts/avg.py').write_text("""
def main(values):
    return sum(values) / len(values)
main(values)
""")
print('written')
''');

  await _exec(monty, 'P6 call run_script with inputs',
      "print(run_script('/tmp/llama-test/scripts/avg.py', inputs={'values': [10, 20, 30]}))");

  await monty.dispose();
}
