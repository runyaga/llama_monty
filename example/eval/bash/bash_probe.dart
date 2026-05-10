// Direct probe of the dart_wasm_sandbox WasmHostBackend without an LLM in
// the loop. Pins the runtime against drift before we wire it into the
// agent. Mirrors example/eval/e2e/inputs_probe.dart.
//
// Allow-listed commands tested: pwd / cd / ls / cat / find / echo.
// Plus cwd persistence across run() calls and resetSession() behaviour.
//
// Run: dart run example/eval/bash/bash_probe.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';
import 'package:dart_wasm_sandbox/ffi.dart' show openFfi;

// Path-deps: wasm_host_dart loads its dylib relative to repoRoot=..,
// which assumes cwd is dart_wasm_sandbox/dart. We're running from
// llama_monty/. Override with the absolute build path.
const _spikeRoot = '/Users/runyaga/dev/dart_wasm_sandbox';
const _dylibPath = '$_spikeRoot/host/target/release/libwasm_host.dylib';
const _wasmPath =
    '$_spikeRoot/guest/target/wasm32-wasip1/release/wasm_guest.wasm';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

final Map<String, Uint8List> _fixtureVfs = {
  '/tmp/llama-test/fixtures/notes.txt': _b('todo:\n  - finish the demo\n  - profit\n'),
  '/tmp/llama-test/fixtures/numbers.txt': _b('1\n2\n3\n42\n'),
  '/tmp/llama-test/fixtures/greeting.txt': _b('hello, world!\n'),
  '/tmp/llama-test/state/app.log': _b('[INFO] booted\n[ERROR] oh no\n'),
};

Future<String> _exec(LoadedGuest guest, String cmd) async {
  final result = await guest.exec(cmd);
  return result.stdout();
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
  final host = await openFfi(libraryPath: _dylibPath);
  final guest = host.loadGuest(wasmBytes);
  await guest.warmup();

  try {
    await host.loadTree(_fixtureVfs);

    // P1 — echo literal
    _expect('P1 echo hello',
        await _exec(guest, 'echo hello'),
        'hello\n');

    // P2 — pwd from root
    _expect('P2 pwd from /',
        await _exec(guest, 'pwd'),
        '/\n');

    // P3 — cd then pwd in same call (cwd persists within && chain)
    _expect('P3 cd /tmp/llama-test/fixtures && pwd',
        await _exec(guest, 'cd /tmp/llama-test/fixtures && pwd'),
        '/tmp/llama-test/fixtures\n');

    // P4 — cwd persists across SEPARATE exec() calls
    _expect('P4 cwd persists across exec()',
        await _exec(guest, 'pwd'),
        '/tmp/llama-test/fixtures\n');

    // P5 — cat with relative path (resolves under cwd=/tmp/llama-test/fixtures)
    _expect('P5 cat greeting.txt (relative)',
        await _exec(guest, 'cat greeting.txt'),
        'hello, world!\n');

    // P6 — cat with absolute path
    _expect('P6 cat /tmp/llama-test/fixtures/notes.txt (absolute)',
        await _exec(guest, 'cat /tmp/llama-test/fixtures/notes.txt'),
        'todo:\n  - finish the demo\n  - profit\n');

    // P7 — ls (cwd is /tmp/llama-test/fixtures from P3)
    final ls = await _exec(guest, 'ls');
    final lsLines = ls.split('\n').where((l) => l.isNotEmpty).toList()..sort();
    _expect('P7 ls (sorted)', lsLines.join(','),
        'greeting.txt,notes.txt,numbers.txt');

    // P8 — find from root walks the tree
    final findOut = await _exec(guest, 'find /');
    final hasNotes = findOut.contains('/tmp/llama-test/fixtures/notes.txt');
    final hasNumbers = findOut.contains('/tmp/llama-test/fixtures/numbers.txt');
    final hasLog = findOut.contains('/tmp/llama-test/state/app.log');
    _expect(
        'P8 find / lists tree',
        '$hasNotes,$hasNumbers,$hasLog',
        'true,true,true');

    // P9 — resetSession() returns cwd to /
    await host.resetSession();
    _expect('P9 resetSession then pwd',
        await _exec(guest, 'pwd'),
        '/\n');

    // P10 — disallowed command (awk) yields typed allowListReject.
    // (Pre-M3 we sniffed for `<host error -3>` text; M3 surfaces the
    // typed enum, so this assertion got tighter.)
    final disallowed = await guest.exec('awk 1 /tmp/llama-test/fixtures/notes.txt');
    _expect('P10 disallowed cmd typed-error',
        '${disallowed.error?.name}', 'allowListReject');
  } finally {
    await host.dispose();
  }

  stdout.writeln('\nProbe complete.');
}
