// Shared spec battery + verify DSL + VFS for the bash bench AND the
// A/B prompt comparison. Single source of truth — if you add a spec
// here, both `run_bash_bench.dart` and `bash_prompt_ab.dart` pick it
// up automatically.

import 'dart:typed_data';

typedef BashVerify = ({bool ok, String reason}) Function({
  required String finalProse,
  required List<String> fences,
  required List<String> stdouts,
});

class BashSpec {
  BashSpec({
    required this.id,
    required this.prompt,
    required this.verify,
    this.maxTurns = 4,
    this.knownFail = false,
  });
  final String id;
  final String prompt;
  final BashVerify verify;
  final int maxTurns;
  final bool knownFail;
}

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

final Map<String, Uint8List> bashVfs = {
  '/tmp/llama-test/fixtures/notes.txt':
      _b('todo:\n  - finish the demo\n  - profit\n'),
  '/tmp/llama-test/fixtures/greeting.txt': _b('hello, world!\n'),
  '/tmp/llama-test/fixtures/numbers.txt': _b('1\n2\n3\n42\n'),
  '/tmp/llama-test/state/app.log': _b('[INFO] booted\n[ERROR] oh no\n'),
};

BashVerify _v({
  Iterable<String>? stdoutContainsAll,
  Iterable<String>? stdoutContainsAny,
  Iterable<String>? proseContainsAll,
  Iterable<String>? proseContainsAny,
  String? fenceContains,
  Iterable<String>? proseDoesNotContain,
}) {
  return ({
    required finalProse,
    required fences,
    required stdouts,
  }) {
    bool inAnyStdout(String s) => stdouts.any((o) => o.contains(s));
    bool inProseOrStdout(String s) =>
        finalProse.contains(s) || inAnyStdout(s);

    if (fenceContains != null &&
        !fences.any((f) => f.contains(fenceContains))) {
      return (ok: false, reason: 'no fence contains "$fenceContains"');
    }
    if (stdoutContainsAll != null) {
      for (final s in stdoutContainsAll) {
        if (!inAnyStdout(s)) {
          return (ok: false, reason: 'no stdout contains "$s"');
        }
      }
    }
    if (stdoutContainsAny != null && !stdoutContainsAny.any(inAnyStdout)) {
      return (ok: false, reason: 'no stdout contains any of $stdoutContainsAny');
    }
    if (proseContainsAll != null) {
      for (final s in proseContainsAll) {
        if (!inProseOrStdout(s)) {
          return (ok: false, reason: 'value "$s" not in prose or stdout');
        }
      }
    }
    if (proseContainsAny != null && !proseContainsAny.any(inProseOrStdout)) {
      return (ok: false, reason: 'no value of $proseContainsAny in prose/stdout');
    }
    if (proseDoesNotContain != null) {
      for (final s in proseDoesNotContain) {
        if (finalProse.contains(s)) {
          return (ok: false, reason: 'prose contains forbidden "$s"');
        }
      }
    }
    return (ok: true, reason: 'ok');
  };
}

final List<BashSpec> bashSpecs = <BashSpec>[
  // Tier 1 — basics (3)
  BashSpec(
    id: 'B01_echo_literal',
    prompt: "Use run_bash to print 'hello' via echo. Tell me what it printed.",
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['hello'],
      proseContainsAll: ['hello'],
    ),
  ),
  BashSpec(
    id: 'B02_echo_multi_arg',
    prompt: "Use run_bash to echo 'foo bar baz'. Tell me what it printed.",
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['foo bar baz'],
      proseContainsAll: ['foo bar baz'],
    ),
  ),
  BashSpec(
    id: 'B03_pwd_root',
    prompt: 'Use run_bash to print the current working directory. State '
        'what it is.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['/'],
      proseContainsAny: ['/'],
    ),
  ),

  // Tier 2 — file reads (2)
  BashSpec(
    id: 'B04_cat_notes',
    prompt:
        'Use run_bash to cat /tmp/llama-test/fixtures/notes.txt. Quote what '
        'it printed.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['todo'],
      proseContainsAny: ['todo', 'finish'],
    ),
  ),
  BashSpec(
    id: 'B05_cat_numbers',
    prompt:
        'Use run_bash to cat /tmp/llama-test/fixtures/numbers.txt. Then '
        'tell me the LAST number in the file.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['42'],
      proseContainsAll: ['42'],
    ),
  ),

  // Tier 3 — listings (2)
  BashSpec(
    id: 'B06_ls_data',
    prompt:
        'Use run_bash to list /tmp/llama-test/fixtures. Tell me the '
        'filenames you saw.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['greeting.txt', 'numbers.txt'],
      proseContainsAll: ['greeting.txt'],
    ),
  ),
  BashSpec(
    id: 'B07_find_root',
    prompt:
        'Use run_bash to find / (recursive). Tell me which paths exist.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: [
        '/tmp/llama-test/fixtures/notes.txt',
        '/tmp/llama-test/fixtures/greeting.txt',
      ],
      proseContainsAny: ['/tmp/llama-test/fixtures/notes.txt', 'notes.txt'],
    ),
  ),

  // Tier 4 — navigation with cd + chaining (3)
  BashSpec(
    id: 'B08_cd_then_pwd',
    prompt:
        'Use run_bash with `cd /tmp/llama-test/fixtures && pwd` and tell '
        'me the result.',
    verify: _v(
      fenceContains: 'cd /tmp/llama-test/fixtures',
      stdoutContainsAll: ['/tmp/llama-test/fixtures'],
      proseContainsAll: ['/tmp/llama-test/fixtures'],
    ),
    maxTurns: 5,
  ),
  BashSpec(
    id: 'B09_cd_then_ls',
    prompt:
        'Use run_bash with `cd /tmp/llama-test/fixtures && ls` and tell me '
        'what files are there.',
    verify: _v(
      fenceContains: 'cd /tmp/llama-test/fixtures',
      stdoutContainsAll: ['greeting.txt', 'numbers.txt'],
      proseContainsAll: ['greeting.txt'],
    ),
  ),
  BashSpec(
    id: 'B10_cd_then_cat',
    prompt:
        'Use run_bash with `cd /tmp/llama-test/fixtures && cat '
        'greeting.txt` and tell me the greeting.',
    verify: _v(
      fenceContains: 'cd /tmp/llama-test/fixtures',
      stdoutContainsAll: ['hello, world!'],
      proseContainsAny: ['hello, world!', 'hello world'],
    ),
  ),

  // Tier 5 — multi-call (cwd persists across SEPARATE run_bash calls) (2)
  BashSpec(
    id: 'B11_multi_call_cwd_persists',
    prompt:
        'Use run_bash TWICE in one fence: first `cd '
        '/tmp/llama-test/fixtures` and discard the result, then `pwd` to '
        'confirm cwd. Tell me what pwd printed.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['/tmp/llama-test/fixtures'],
      proseContainsAll: ['/tmp/llama-test/fixtures'],
    ),
    maxTurns: 5,
  ),
  BashSpec(
    id: 'B12_find_then_cat',
    prompt:
        'Use run_bash to find files under /tmp/llama-test/state (one call), '
        'then cat the first one (second call). Tell me the first non-blank '
        'line of that file.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['INFO'],
      proseContainsAny: ['INFO', 'booted'],
    ),
    maxTurns: 6,
  ),

  // Tier 6 — combined evals: Python + bash composition (3)
  BashSpec(
    id: 'C01_bash_then_python_sum',
    prompt:
        'Use run_bash to cat /tmp/llama-test/fixtures/numbers.txt, then '
        "in the SAME fence use Python to parse the stdout (split lines, "
        'int() each) and print the sum.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['48'], // 1 + 2 + 3 + 42 = 48
      proseContainsAll: ['48'],
    ),
    maxTurns: 5,
  ),
  BashSpec(
    id: 'C02_bash_find_then_python_count',
    prompt:
        'Use run_bash with `find /` to list every path, then in the SAME '
        'fence use Python to count how many lines stdout had. Tell me '
        'the count.',
    verify: _v(
      fenceContains: 'run_bash',
      proseContainsAny: ['4', '5', '6', '7', '8'],
    ),
    maxTurns: 5,
  ),
  BashSpec(
    id: 'C03_python_value_via_bash_echo',
    prompt:
        'In Python, compute 7 * 8. Then use run_bash to echo the result. '
        'Tell me what bash printed.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['56'],
      proseContainsAll: ['56'],
    ),
    maxTurns: 5,
  ),

  // Tier 7 — known-fail / disallowed (2)
  // Phase A1 added wc/grep/head/tail to the allow-list, so the
  // original B13_disallowed_grep no longer tests rejection. Swapped
  // to awk, which is still rejected (and the model still naturally
  // reaches for it on sum-a-column tasks per the survey).
  BashSpec(
    id: 'B13_disallowed_awk',
    prompt:
        'Try to use run_bash with `awk \'{s+=\$1} END {print s}\' '
        '/tmp/llama-test/fixtures/numbers.txt`. Tell me what happens '
        'and (if it failed) explain why.',
    knownFail: true,
    verify: _v(
      proseContainsAny: ['error', 'not allow', 'allow-list', 'rejected'],
    ),
  ),
  BashSpec(
    id: 'B14_disallowed_pipe',
    prompt:
        'Try to use run_bash with `cat /notes.txt | head -1`. Tell me '
        'what happens.',
    knownFail: true,
    verify: _v(
      proseContainsAny: ['error', 'not allow', 'pipe', 'rejected'],
    ),
  ),
];
