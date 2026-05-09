// Direct probe of the wasmtime-spike WasmHostBackend without an LLM in
// the loop. Pins the runtime against drift before we wire it into the
// agent. Mirrors example/eval/e2e/inputs_probe.dart.
//
// Allow-listed commands tested: pwd / cd / ls / cat / find / echo.
// Plus cwd persistence across run() calls and resetSession() behaviour.
//
// Run: dart run example/eval/bash/bash_probe.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:wasm_host_dart/wasm_host.dart';
import 'package:wasm_host_dart/src/wasm_host_ffi.dart';

// Path-deps: wasm_host_dart loads its dylib relative to repoRoot=..,
// which assumes cwd is wasmtime-spike/dart. We're running from
// llama_monty/. Override with the absolute build path.
const _spikeRoot = '/Users/runyaga/dev/wasmtime-spike';
const _dylibPath = '$_spikeRoot/host/target/release/libwasm_host.dylib';
const _wasmPath =
    '$_spikeRoot/guest/target/wasm32-wasip1/release/wasm_guest.wasm';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

final Map<String, Uint8List> _fixtureVfs = {
  '/notes.txt': _b('todo:\n  - finish the demo\n  - profit\n'),
  '/data/numbers.txt': _b('1\n2\n3\n42\n'),
  '/data/greeting.txt': _b('hello, world!\n'),
  '/logs/app.log': _b('[INFO] booted\n[ERROR] oh no\n'),
};

Future<String> _exec(WasmHostBackend host, Uint8List wasmBytes, String cmd) async {
  final out = await host.run(wasmBytes, stdin: _b(cmd));
  return String.fromCharCodes(out);
}

void _expect(String label, String got, String expected) {
  final ok = got == expected;
  stdout.writeln('${ok ? '✓' : '✗'} $label');
  if (!ok) {
    stdout.writeln('  expected: ${_q(expected)}');
    stdout.writeln('       got: ${_q(got)}');
  }
}

String _q(String s) => '"${s.replaceAll('\n', r'\n')}"';

Future<void> main() async {
  final wasmFile = File(_wasmPath);
  if (!wasmFile.existsSync()) {
    stderr.writeln('guest.wasm not built at $_wasmPath');
    exit(2);
  }
  if (!File(_dylibPath).existsSync()) {
    stderr.writeln('libwasm_host.dylib not built at $_dylibPath');
    exit(2);
  }

  final wasmBytes = wasmFile.readAsBytesSync();
  final host = WasmHostFfi.open(_dylibPath);

  try {
    await host.loadTree(_fixtureVfs);

    // P1 — echo literal
    _expect('P1 echo hello',
        await _exec(host, wasmBytes, 'echo hello'),
        'hello\n');

    // P2 — pwd from root
    _expect('P2 pwd from /',
        await _exec(host, wasmBytes, 'pwd'),
        '/\n');

    // P3 — cd then pwd in same call (cwd persists within && chain)
    _expect('P3 cd /data && pwd',
        await _exec(host, wasmBytes, 'cd /data && pwd'),
        '/data\n');

    // P4 — cwd persists across SEPARATE run() calls
    _expect('P4 cwd persists across run()',
        await _exec(host, wasmBytes, 'pwd'),
        '/data\n');

    // P5 — cat with relative path (resolves under cwd=/data)
    _expect('P5 cat greeting.txt (relative)',
        await _exec(host, wasmBytes, 'cat greeting.txt'),
        'hello, world!\n');

    // P6 — cat with absolute path
    _expect('P6 cat /notes.txt (absolute)',
        await _exec(host, wasmBytes, 'cat /notes.txt'),
        'todo:\n  - finish the demo\n  - profit\n');

    // P7 — ls
    final ls = await _exec(host, wasmBytes, 'ls');
    final lsLines = ls.split('\n').where((l) => l.isNotEmpty).toList()..sort();
    _expect('P7 ls (sorted)', lsLines.join(','), 'greeting.txt,numbers.txt');

    // P8 — find from root walks the tree
    final findOut = await _exec(host, wasmBytes, 'find /');
    final hasNotes = findOut.contains('/notes.txt');
    final hasNumbers = findOut.contains('/data/numbers.txt');
    final hasLog = findOut.contains('/logs/app.log');
    _expect(
        'P8 find / lists tree',
        '$hasNotes,$hasNumbers,$hasLog',
        'true,true,true');

    // P9 — resetSession() returns cwd to /
    await host.resetSession();
    _expect('P9 resetSession then pwd',
        await _exec(host, wasmBytes, 'pwd'),
        '/\n');

    // P10 — disallowed command yields negative-status sentinel
    final disallowed = await _exec(host, wasmBytes, 'grep foo bar');
    final containsErrorMarker = disallowed.contains('-3') ||
        disallowed.toLowerCase().contains('error');
    _expect('P10 disallowed cmd marked',
        containsErrorMarker.toString(), 'true');
  } finally {
    await host.dispose();
  }

  stdout.writeln('\nProbe complete.');
}
