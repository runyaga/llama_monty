// Probe what `run_python` actually surfaces to the LLM for various
// program shapes. We need ground truth on print vs. last-expression vs.
// function-return-value before designing the test battery, because the
// model's behaviour depends on exactly what comes back through the
// tool result.
//
// Mirrors the production handler logic in
// example/llama_monty_web/lib/main.dart::_runPythonTool — concatenates
// printOutput + result.value (when not MontyNone). Logs both fields
// individually plus the concatenated string so we can see whether
// each path leaks data.
//
// Run: dart run example/eval/e2e/return_vs_print_probe.dart

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

class _Case {
  _Case(this.label, this.code);
  final String label;
  final String code;
}

Future<void> main() async {
  final monty = MontyRuntime(os: defaultOsHandler());

  final cases = <_Case>[
    _Case('P1 print(int)', 'print(42)'),
    _Case('P2 bare top-level int', '42'),
    _Case('P3 assignment only', 'x = 42'),
    _Case('P4 function call as last expr',
        'def f():\n    return 42\nf()'),
    _Case('P5 print(function call)',
        'def f():\n    return 42\nprint(f())'),
    _Case('P6 mixed print + bare',
        "print('a')\nprint('b')\n3"),
    _Case('P7 list literal', '[1, 2, 3]'),
    _Case('P8 side-effect-only function',
        "def f():\n    print('side effect')\nf()"),
    _Case('P9 dict literal', "{'a': 1, 'b': 2}"),
    _Case('P10 multi-line print', "print('line1')\nprint('line2')\nprint('line3')"),
  ];

  for (final c in cases) {
    stdout.writeln('\n=== ${c.label} ===');
    stdout.writeln('code:');
    for (final line in c.code.split('\n')) {
      stdout.writeln('    $line');
    }
    final r = await monty.execute(c.code).result;
    if (r.error != null) {
      stdout.writeln('  ERROR: ${r.error!.message}');
      continue;
    }
    final printOutput = r.printOutput;
    stdout.writeln('  printOutput: '
        '${printOutput == null ? 'null' : '${printOutput.runtimeType} ${jsonish(printOutput)}'}');
    final v = r.value;
    stdout.writeln('  value: '
        '${v == null ? 'null' : '${v.runtimeType} ${jsonish(v.toString())}'}');
    final isNone = v is MontyNone;
    stdout.writeln('  isMontyNone: $isNone');

    // Mirror the production concat to see what the LLM ACTUALLY sees.
    final parts = <String>[];
    if (printOutput != null && printOutput.isNotEmpty) {
      parts.add(printOutput.trim());
    }
    if (v != null && v is! MontyNone) {
      parts.add(v.toString());
    }
    final llmSees = parts.join('\n').trim();
    stdout.writeln('  → LLM sees: ${jsonish(llmSees)}');
  }

  await monty.dispose();
}

String jsonish(String s) {
  return '"${s.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
}
