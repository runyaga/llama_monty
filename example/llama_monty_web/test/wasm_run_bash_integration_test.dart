// Isolated chrome-side WASM run_bash integration tests.
//
// Goal: exercise the dart_wasm_sandbox WasmHost.open() path + our
// buildRunBashFunction without spinning up the full Flutter app.
// Tighter feedback loop for iterating on:
//   - the WASM tool-call regex fallback in main.dart
//   - the bash tool dispatcher
//   - VFS snapshot semantics
//   - multi-call behaviour
//
// Run:
//   dart test -p chrome --tags wasm \
//     example/llama_monty_web/test/wasm_run_bash_integration_test.dart
//
// Browser-only: WasmHost.open() web backend uses native
// `WebAssembly.instantiate`; FFI path is skipped via @TestOn.
@TestOn('browser')
@Tags(['wasm'])
library;

import 'dart:typed_data';

import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';
import 'package:test/test.dart';

import 'support/wasm_guest_bytes.g.dart';

void main() {
  group('WASM run_bash isolated integration', () {
    late WasmHost host;
    late LoadedGuest guest;

    setUpAll(() async {
      host = await WasmHost.open();
      guest = host.loadGuest(wasmGuestBytes);
      await guest.warmup();
    });

    tearDownAll(() async {
      await host.dispose();
    });

    setUp(() async {
      // Seed a tiny VFS that mirrors what the live app's snapshot
      // would have. Bench tests on the macOS side use a much bigger
      // tree; this is the minimum to validate parse + dispatch
      // correctness, not coverage breadth.
      await host.resetSession();
      await host.loadTree({
        '/tmp/llama-test/fixtures/notes.txt':
            Uint8List.fromList('hello\n'.codeUnits),
        '/tmp/llama-test/fixtures/numbers.txt':
            Uint8List.fromList('1\n2\n3\n42\n'.codeUnits),
        '/tmp/llama-test/state/app.log':
            Uint8List.fromList('[INFO] booted\n'.codeUnits),
      });
    });

    test('echo hello → "hello\\n"', () async {
      final r = await guest.exec("echo hello");
      expect(r.error, isNull);
      expect(r.stdout(), 'hello\n');
    });

    test('cd /tmp/llama-test/fixtures persists across exec()', () async {
      final cd = await guest.exec('cd /tmp/llama-test/fixtures');
      expect(cd.error, isNull, reason: 'cd should succeed silently');
      final pwd = await guest.exec('pwd');
      expect(pwd.error, isNull);
      expect(pwd.stdout().trim(), '/tmp/llama-test/fixtures',
          reason: 'cwd must persist across separate exec() calls');
    });

    test('find /tmp/llama-test enumerates seeded files', () async {
      final r = await guest.exec('find /tmp/llama-test');
      expect(r.error, isNull);
      final out = r.stdout();
      expect(out, contains('/tmp/llama-test/fixtures/notes.txt'));
      expect(out, contains('/tmp/llama-test/fixtures/numbers.txt'));
      expect(out, contains('/tmp/llama-test/state/app.log'));
    });

    test('find /tmp -type f vs -type d return disjoint sets (N6)',
        () async {
      final files = await guest.exec('find /tmp/llama-test -type f');
      final dirs = await guest.exec('find /tmp/llama-test -type d');
      expect(files.error, isNull);
      expect(dirs.error, isNull);
      // -type f returns the 3 seeded files; -type d the inferred
      // directory entries (/tmp/llama-test, fixtures, state).
      final fileSet =
          files.stdout().split('\n').where((l) => l.isNotEmpty).toSet();
      final dirSet =
          dirs.stdout().split('\n').where((l) => l.isNotEmpty).toSet();
      expect(fileSet.intersection(dirSet), isEmpty,
          reason: '-type f and -type d sets must be disjoint');
      expect(fileSet, contains('/tmp/llama-test/fixtures/notes.txt'));
      expect(dirSet, contains('/tmp/llama-test'));
    });

    test('disallowed cmd surfaces typed HostError.allowListReject',
        () async {
      final r = await guest.exec("awk 1 /tmp/llama-test/fixtures/notes.txt");
      expect(r.error, HostError.allowListReject,
          reason: 'awk is not on the allow-list — should be -3 typed');
      expect(r.exitCode, isNot(0));
    });

    test('xargs + wc -l multi-arg (N5/N4) work end-to-end', () async {
      final r = await guest.exec(
        'find /tmp/llama-test -type f | xargs wc -l',
      );
      expect(r.error, isNull);
      // Should produce per-file line counts plus a "total" line.
      expect(r.stdout(), contains('total'));
    });

    test('* glob expansion (N7) over fixtures', () async {
      final r = await guest.exec('ls /tmp/llama-test/fixtures/*.txt');
      expect(r.error, isNull);
      final out = r.stdout();
      expect(out, contains('notes.txt'));
      expect(out, contains('numbers.txt'));
    });
  });
}
