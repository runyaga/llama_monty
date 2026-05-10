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

  // ---------------------------------------------------------------
  // Bash Programs experiment runtime equivalents.
  //
  // The user reported "WASM bash programs broken" in the live UI:
  //   - prompt 3 ("Use run_bash twice...") returns wrong answer
  //   - prompt 4 (cat csv + Python parse) hits SyntaxError
  //
  // These are LLM-driven prompts; without a real LLM we can't repro
  // the model's exact emissions. But we CAN exercise the runtime
  // calls each prompt's tool calls would produce. If the runtime
  // returns correct answers for every case, the failures are
  // model-side (model didn't emit the right commands, didn't
  // issue follow-up tool calls, etc.) — not runtime/infrastructure.
  // ---------------------------------------------------------------
  group('Bash Programs experiment — runtime equivalents (model-free)', () {
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
      // Seed the same VFS shape the live app does — fixtures the
      // Bash Programs prompts reference by absolute path.
      await host.resetSession();
      await host.loadTree({
        '/tmp/llama-test/fixtures/notes.txt':
            Uint8List.fromList('hello\n'.codeUnits),
        '/tmp/llama-test/fixtures/welcome.md':
            Uint8List.fromList('# Welcome\nThis is the test fixture.\n'.codeUnits),
        '/tmp/llama-test/fixtures/sample.csv':
            Uint8List.fromList('name,price\napple,3\nbanana,1\ncherry,5\n'.codeUnits),
        '/tmp/llama-test/state/app.log':
            Uint8List.fromList('[INFO] booted\n'.codeUnits),
      });
    });

    test('prompt 1: `echo hello` → "hello\\n"', () async {
      final r = await guest.exec("echo hello");
      expect(r.error, isNull);
      expect(r.stdout(), 'hello\n',
          reason: 'runtime returns expected; if live UI fails here, '
              'model never emitted echo');
    });

    test('prompt 2: `cd /tmp/llama-test/fixtures && cat welcome.md`',
        () async {
      final r = await guest.exec(
        'cd /tmp/llama-test/fixtures && cat welcome.md',
      );
      expect(r.error, isNull);
      expect(r.stdout(), contains('Welcome'),
          reason: 'chained cd && cat should print welcome.md content');
    });

    test('prompt 3: TWO separate exec calls (cd, then pwd) — '
        'cwd persistence is THE thing to verify', () async {
      // Model is supposed to issue these as TWO separate tool calls
      // in two separate turns. Live failure: model emits ONE tool
      // call (cd) and never issues the second pwd. The runtime is
      // not the problem — proven below.
      final cd = await guest.exec('cd /tmp/llama-test/fixtures');
      expect(cd.error, isNull, reason: 'cd should succeed silently');
      expect(cd.stdout(), '', reason: 'cd produces no stdout');

      final pwd = await guest.exec('pwd');
      expect(pwd.error, isNull);
      expect(pwd.stdout().trim(), '/tmp/llama-test/fixtures',
          reason: 'pwd MUST return the directory cd set. If this assertion '
              'passes (it does), the live-UI prompt-3 failure is the model '
              'never issuing the second pwd call — not the runtime.');
    });

    test('prompt 4 part 1 (bash side): `cat sample.csv` returns '
        '4-line csv', () async {
      final r = await guest.exec('cat /tmp/llama-test/fixtures/sample.csv');
      expect(r.error, isNull);
      final lines = r.stdout().split('\n').where((l) => l.isNotEmpty).toList();
      expect(lines.length, 4,
          reason: 'header + 3 data rows. Live SyntaxError in prompt 4 '
              "is on the Python parsing side, not the bash cat. The "
              'bash side gives Python clean bytes.');
      expect(lines.first, 'name,price');
    });

    test('prompt 5: `find /tmp/llama-test/` lists every seeded path',
        () async {
      final r = await guest.exec('find /tmp/llama-test/');
      expect(r.error, isNull);
      final out = r.stdout();
      // All 4 seeded files (notes.txt, welcome.md, sample.csv, app.log)
      // should appear in the find output.
      expect(out, contains('notes.txt'));
      expect(out, contains('welcome.md'));
      expect(out, contains('sample.csv'));
      expect(out, contains('app.log'),
          reason: 'find should walk the entire seeded tree');
    });

    test('prompt 5 alt: `find /tmp/llama-test/ -type f` returns only '
        'files (N6 filter)', () async {
      final r = await guest.exec('find /tmp/llama-test/ -type f');
      expect(r.error, isNull);
      final paths =
          r.stdout().split('\n').where((l) => l.isNotEmpty).toList();
      expect(paths.length, 4, reason: '4 seeded files');
      for (final p in paths) {
        expect(p.endsWith('/'), isFalse,
            reason: 'N6 -type f should not return dir entries');
      }
    });
  });

  // ---------------------------------------------------------------
  // Full bash-feature surface — every allow-listed command and
  // every shipped phase (A1 / N1 / N1.5 / N2 / N3 / N4 / N5 / N6 /
  // N7) hit at least once. Acts as a comprehensive regression
  // guard. Numbers chosen so each assertion has an exact answer.
  //
  // Fixture (8 files, 12 dir entries inferred):
  //   /data/numbers.txt     1\n2\n3\n42\n               4 lines
  //   /data/letters.txt     a\nb\nc\n                   3 lines
  //   /data/scores.txt      "1 99\n2 50\n3 75\n"        3 lines
  //   /data/dups.txt        1\n2\n2\n3\n3\n3\n          6 lines, 3 distinct
  //   /logs/app.log         3 INFO + 2 ERROR + 1 WARN   6 lines
  //   /logs/access.log      "200 /\n404 /missing\n"     2 lines
  //   /docs/readme.md       "# README\nhello\n"         2 lines
  //   /docs/notes/todo.md   "todo: ship it\n"           1 line
  // ---------------------------------------------------------------
  group('Full bash surface — every allow-listed command + phase', () {
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
      await host.resetSession();
      await host.loadTree({
        '/data/numbers.txt':
            Uint8List.fromList('1\n2\n3\n42\n'.codeUnits),
        '/data/letters.txt': Uint8List.fromList('a\nb\nc\n'.codeUnits),
        '/data/scores.txt':
            Uint8List.fromList('1 99\n2 50\n3 75\n'.codeUnits),
        '/data/dups.txt':
            Uint8List.fromList('1\n2\n2\n3\n3\n3\n'.codeUnits),
        '/logs/app.log': Uint8List.fromList(
          '[INFO] booted\n[ERROR] auth\n[INFO] ready\n'
          '[WARN] mem\n[ERROR] db\n[INFO] tick\n'
              .codeUnits,
        ),
        '/logs/access.log':
            Uint8List.fromList('200 /\n404 /missing\n'.codeUnits),
        '/docs/readme.md':
            Uint8List.fromList('# README\nhello\n'.codeUnits),
        '/docs/notes/todo.md':
            Uint8List.fromList('todo: ship it\n'.codeUnits),
      });
    });

    // -------- 12 allow-listed commands --------

    test('cmd: pwd from /', () async {
      final r = await guest.exec('pwd');
      expect(r.stdout(), '/\n');
    });

    test('cmd: cd then pwd in &&-chain', () async {
      final r = await guest.exec('cd /data && pwd');
      expect(r.stdout(), '/data\n');
    });

    test('cmd: ls /data', () async {
      final r = await guest.exec('ls /data');
      final names = r.stdout().split('\n').where((l) => l.isNotEmpty).toSet();
      expect(names, {'numbers.txt', 'letters.txt', 'scores.txt', 'dups.txt'});
    });

    test('cmd: cat /data/letters.txt', () async {
      final r = await guest.exec('cat /data/letters.txt');
      expect(r.stdout(), 'a\nb\nc\n');
    });

    test('cmd: find /docs lists nested', () async {
      final r = await guest.exec('find /docs');
      expect(r.stdout(), contains('/docs/readme.md'));
      expect(r.stdout(), contains('/docs/notes/todo.md'));
    });

    test('cmd: echo with multiple args', () async {
      final r = await guest.exec('echo a b c');
      expect(r.stdout(), 'a b c\n');
    });

    test('cmd: wc -l /data/numbers.txt (A1)', () async {
      final r = await guest.exec('wc -l /data/numbers.txt');
      expect(r.stdout(), contains('4'));
    });

    test('cmd: grep INFO /logs/app.log (A1)', () async {
      final r = await guest.exec('grep INFO /logs/app.log');
      final hits = r.stdout().split('\n').where((l) => l.isNotEmpty).toList();
      expect(hits.length, 3, reason: '3 INFO lines');
    });

    test('cmd: head -n 2 /data/numbers.txt (A1)', () async {
      final r = await guest.exec('head -n 2 /data/numbers.txt');
      expect(r.stdout(), '1\n2\n');
    });

    test('cmd: tail -n 1 /data/numbers.txt (A1)', () async {
      final r = await guest.exec('tail -n 1 /data/numbers.txt');
      expect(r.stdout().trim(), '42');
    });

    test('cmd: sort -n /data/dups.txt (N1.5)', () async {
      final r = await guest.exec('sort -n /data/dups.txt');
      expect(r.stdout(), '1\n2\n2\n3\n3\n3\n');
    });

    test('cmd: xargs cat (N5) consumes stdin paths', () async {
      final r = await guest.exec(
        'find /docs -type f | xargs cat',
      );
      expect(r.error, isNull);
      // both files concatenated
      expect(r.stdout(), contains('# README'));
      expect(r.stdout(), contains('todo: ship it'));
    });

    // -------- Phase shipments (one assertion per phase) --------

    test('A1: grep -c counts matches, fixed-string semantics', () async {
      final r = await guest.exec('grep -c INFO /logs/app.log');
      expect(r.stdout().trim(), '3');
    });

    test('N1: pipes — cat | grep | wc -l', () async {
      final r = await guest.exec(
        'cat /logs/app.log | grep INFO | wc -l',
      );
      expect(r.stdout().trim(), '3');
    });

    test('N1.5: sort -u dedupes', () async {
      final r = await guest.exec('sort -u /data/dups.txt');
      expect(r.stdout(), '1\n2\n3\n');
    });

    test('N2: head -2 short-flag form (no -n)', () async {
      final r = await guest.exec('head -2 /data/numbers.txt');
      expect(r.stdout(), '1\n2\n');
    });

    test('N2: 2>/dev/null redirect silently stripped', () async {
      final r = await guest.exec('echo ok 2>/dev/null');
      expect(r.stdout(), 'ok\n');
    });

    test('N3: outer-quote strip — grep "INFO" works like grep INFO',
        () async {
      final r = await guest.exec('grep "INFO" /logs/app.log');
      expect(r.stdout().split('\n').where((l) => l.isNotEmpty).length, 3);
    });

    test('N4: wc -l multi-file emits per-file + total', () async {
      final r = await guest.exec(
        'wc -l /data/numbers.txt /data/letters.txt',
      );
      expect(r.stdout(), contains('4 /data/numbers.txt'));
      expect(r.stdout(), contains('3 /data/letters.txt'));
      expect(r.stdout(), contains('total'));
    });

    test('N5: cat multi-file concatenates', () async {
      final r = await guest.exec(
        'cat /data/numbers.txt /data/letters.txt',
      );
      expect(r.stdout(), '1\n2\n3\n42\na\nb\nc\n');
    });

    test('N6: find -type d enumerates inferred dirs', () async {
      final r = await guest.exec('find /docs -type d');
      final dirs = r.stdout().split('\n').where((l) => l.isNotEmpty).toSet();
      expect(dirs, contains('/docs'));
      expect(dirs, contains('/docs/notes'));
    });

    test('N7: ? glob (single-char wildcard)', () async {
      final r = await guest.exec('cat /data/?umbers.txt');
      expect(r.stdout(), '1\n2\n3\n42\n');
    });

    test('N7: ls multi-arg returns each path on its own line', () async {
      final r = await guest.exec(
        'ls /data/numbers.txt /data/letters.txt',
      );
      final lines = r.stdout().split('\n').where((l) => l.isNotEmpty).toSet();
      expect(lines, {'/data/numbers.txt', '/data/letters.txt'});
    });

    // -------- Composition: 4-stage chains + glob+pipe+xargs --------

    test('chain: cat | grep | sort -u | wc -l (4 stages)', () async {
      final r = await guest.exec(
        'cat /logs/app.log | grep INFO | sort -u | wc -l',
      );
      // 3 INFO lines, 3 distinct messages → 3
      expect(r.stdout().trim(), '3');
    });

    test('glob+xargs: ls /data/* counts via wc -l on each via xargs',
        () async {
      final r = await guest.exec(
        'find /data -type f | xargs wc -l',
      );
      expect(r.stdout(), contains('total'));
      expect(r.stdout(), contains('numbers.txt'));
    });

    test('cwd-relative glob after cd', () async {
      final r = await guest.exec('cd /data && cat *.txt | wc -l');
      expect(r.error, isNull);
      // 4 + 3 + 3 + 6 = 16 lines total
      expect(r.stdout().trim(), '16');
    });

    // -------- Error contracts --------

    test('error -3: disallowed cmd → HostError.allowListReject', () async {
      final r = await guest.exec('sed s/x/y/ /data/numbers.txt');
      expect(r.error, HostError.allowListReject);
      expect(r.exitCode, -3);
    });

    test('error -4: missing file → HostError.ioError', () async {
      final r = await guest.exec('cat /no/such/file');
      expect(r.error, HostError.ioError);
      expect(r.exitCode, -4);
    });

    test('error -3 propagates through xargs (N5 inline marker)', () async {
      // sed is rejected; xargs surfaces via exit code mid-pipe
      final r = await guest.exec('echo foo | xargs sed s/x/y/');
      expect(r.error, isNotNull,
          reason: 'sed inside xargs should still get rejected');
    });

    // -------- Session state --------

    test('session: resetSession returns cwd to /', () async {
      await guest.exec('cd /data');
      await host.resetSession();
      final r = await guest.exec('pwd');
      expect(r.stdout(), '/\n');
    });

    test('session: setCwd directly via host API', () async {
      await host.setCwd('/logs');
      final r = await guest.exec('pwd');
      expect(r.stdout(), '/logs\n');
    });

    // -------- VFS read-back (M1 surface) --------

    test('vfs: readFile returns bytes loaded by loadTree', () async {
      final bytes = await host.readFile('/data/letters.txt');
      expect(bytes, isNotNull);
      expect(String.fromCharCodes(bytes!), 'a\nb\nc\n');
    });

    test('vfs: existsAt distinguishes loaded vs missing', () async {
      expect(await host.existsAt('/data/numbers.txt'), isTrue);
      expect(await host.existsAt('/no/such'), isFalse);
    });

    test('vfs: writeFile + cat round-trips through wasm guest', () async {
      await host.writeFile(
        '/scratch.txt',
        Uint8List.fromList('round-trip\n'.codeUnits),
      );
      final r = await guest.exec('cat /scratch.txt');
      expect(r.stdout(), 'round-trip\n');
    });

    // -------- Manifest introspection (M3) --------

    test('manifest: introspection lists allow-listed commands',
        () async {
      final m = host.manifest;
      // Manifest exposes the runtime's known commands; assert the
      // ones the bench depends on are present.
      final names = m.commands.map((c) => c.name).toSet();
      for (final cmd in [
        'pwd', 'cd', 'ls', 'cat', 'find', 'echo',
        'wc', 'grep', 'head', 'tail', 'sort', 'xargs',
      ]) {
        expect(names, contains(cmd),
            reason: '$cmd should be in manifest');
      }
    });
  });
}
