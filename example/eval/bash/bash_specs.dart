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
  // Original small fixtures — kept for backwards-compat with B-tier specs.
  '/tmp/llama-test/fixtures/notes.txt':
      _b('todo:\n  - finish the demo\n  - profit\n'),
  '/tmp/llama-test/fixtures/greeting.txt': _b('hello, world!\n'),
  '/tmp/llama-test/fixtures/numbers.txt': _b('1\n2\n3\n42\n'),
  '/tmp/llama-test/state/app.log': _b('[INFO] booted\n[ERROR] oh no\n'),
  // Larger fixtures for the A-tier (advanced pipes) and M-tier
  // (multi-turn). Hand-picked so every assertion has an exact answer:
  //
  //   scores.txt (9 nums):  max = 99, distinct count = 7, sum = 193
  //   big.log (8 lines):    INFO=4, ERROR=3, WARN=1, INFO-distinct=3
  '/tmp/llama-test/fixtures/scores.txt': _b('5\n12\n3\n99\n42\n7\n5\n12\n8\n'),
  '/tmp/llama-test/state/big.log': _b(
    '[INFO] boot\n'
    '[ERROR] auth\n'
    '[INFO] ready\n'
    '[ERROR] timeout\n'
    '[WARN] mem\n'
    '[INFO] tick\n'
    '[ERROR] db\n'
    '[INFO] tick\n',
  ),
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
        'Issue these as TWO SEPARATE run_bash calls (not one chained pipe). '
        'Call 1: find files under /tmp/llama-test/state. Call 2: cat the '
        'app.log file by its absolute path. Tell me the first non-blank '
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
  // Phase Next-N1 added pipes. Was a knownFail rejection check; now
  // tests the happy path — the model should chain commands with `|`
  // and the harness should return the piped stdout.
  BashSpec(
    id: 'B14_pipe_works',
    prompt:
        'Use run_bash with `cat /tmp/llama-test/fixtures/numbers.txt | '
        'head -n 2`. Tell me what bash printed.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['1', '2'],
      proseContainsAll: ['1', '2'],
    ),
  ),

  // Tier 8 — advanced multi-stage pipes (newly possible post-A1+N1+N1.5).
  // big.log: INFO=4, ERROR=3, WARN=1, INFO-distinct=3
  // scores.txt: max=99, distinct=7, sum=193
  BashSpec(
    id: 'A01_pipe_grep_count',
    prompt:
        'Use run_bash to count how many INFO lines are in '
        '/tmp/llama-test/state/big.log. Hint: cat | grep | wc -l.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['4'],
      proseContainsAll: ['4'],
    ),
    maxTurns: 4,
  ),
  BashSpec(
    id: 'A02_top_max',
    prompt:
        'Use run_bash to print the LARGEST number in '
        '/tmp/llama-test/fixtures/scores.txt. Hint: sort -nr | head -n 1.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['99'],
      proseContainsAll: ['99'],
    ),
    maxTurns: 4,
  ),
  BashSpec(
    id: 'A03_unique_count',
    prompt:
        'Use run_bash to count how many DISTINCT numbers are in '
        '/tmp/llama-test/fixtures/scores.txt. Hint: sort -u | wc -l.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['7'],
      proseContainsAll: ['7'],
    ),
    maxTurns: 4,
  ),
  BashSpec(
    id: 'A04_chain_4stage',
    prompt:
        'Use run_bash with a 4-stage pipe to count the DISTINCT INFO '
        'lines in /tmp/llama-test/state/big.log. '
        'Hint: cat | grep INFO | sort -u | wc -l.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['3'],
      proseContainsAll: ['3'],
    ),
    maxTurns: 4,
  ),

  // Tier 9 — multi-turn agentic tasks. Model should take its first
  // run_bash output, reason over it, and issue follow-up calls.
  BashSpec(
    id: 'M01_explore_then_navigate',
    prompt:
        'Use run_bash to find files under /tmp/llama-test/state. Then, '
        'using a SEPARATE run_bash call, cat the file named "big.log". '
        'Tell me the first INFO line you saw.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['boot'],
      proseContainsAny: ['boot', 'INFO'],
    ),
    maxTurns: 6,
  ),
  BashSpec(
    id: 'M02_count_by_severity',
    prompt:
        'Use run_bash to count INFO, ERROR, and WARN lines in '
        '/tmp/llama-test/state/big.log. You may use one fence with '
        'multiple run_bash calls or pipes. Tell me the three counts.',
    verify: _v(
      fenceContains: 'run_bash',
      proseContainsAll: ['4', '3', '1'],
    ),
    maxTurns: 5,
  ),

  // Tier 10 — stable rejection sentinel. Per upstream's recommendation:
  // a knownFail spec that doesn't churn each phase. sed has been on
  // the deny list since A1 and stays there past N1+N1.5.
  BashSpec(
    id: 'B15_disallowed_sed',
    prompt:
        'Try to use run_bash with `sed "s/INFO/info/g" '
        '/tmp/llama-test/state/app.log`. Tell me what happens and '
        '(if it failed) explain why.',
    knownFail: true,
    verify: _v(
      proseContainsAny: ['error', 'not allow', 'allow-list', 'rejected'],
    ),
  ),
];
