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

final Map<String, Uint8List> bashVfs = _buildVfs();

Map<String, Uint8List> _buildVfs() => {
      // Original small fixtures (B-tier — basics, navigation, multi-call).
      '/tmp/llama-test/fixtures/notes.txt':
          _b('todo:\n  - finish the demo\n  - profit\n'),
      '/tmp/llama-test/fixtures/greeting.txt': _b('hello, world!\n'),
      '/tmp/llama-test/fixtures/numbers.txt': _b('1\n2\n3\n42\n'),
      '/tmp/llama-test/state/app.log': _b('[INFO] booted\n[ERROR] oh no\n'),
      // Larger fixtures (A-tier advanced pipes, S-tier sophistication,
      // D-tier decomposition, M-tier multi-turn).
      //
      //   scores.txt (30 nums, 15 distinct):
      //     distinct = {12, 17, 23, 28, 34, 41, 49, 56, 63, 71, 78, 84, 91, 96, 99}
      //     each repeated twice
      //     min = 12, max = 99, sum = 1684, distinct count = 15
      //
      //   big.log (50 lines, 5 cycles × 10):
      //     INFO=20 (4 distinct), ERROR=15 (3 distinct),
      //     WARN=10 (2 distinct), DEBUG=5 (1 distinct)
      //     non-DEBUG = 45, total distinct = 10
      //     first ERROR = "[ERROR] auth failed"
      //
      //   configs/v1.txt vs configs/v2.txt (5 lines each):
      //     differ on exactly one line ("gamma" vs "GAMMA")
      '/tmp/llama-test/fixtures/scores.txt': _b(_buildScores()),
      '/tmp/llama-test/state/big.log': _b(_buildBigLog()),
      '/tmp/llama-test/configs/v1.txt':
          _b('alpha\nbeta\ngamma\ndelta\nepsilon\n'),
      '/tmp/llama-test/configs/v2.txt':
          _b('alpha\nbeta\nGAMMA\ndelta\nepsilon\n'),
    };

const List<int> _scoreDistinct = [
  12, 17, 23, 28, 34, 41, 49, 56, 63, 71, 78, 84, 91, 96, 99,
];

String _buildScores() {
  final buf = StringBuffer();
  for (final n in _scoreDistinct) {
    buf
      ..writeln(n)
      ..writeln(n);
  }
  return buf.toString();
}

const List<String> _logCycle = [
  '[INFO] boot',
  '[ERROR] auth failed',
  '[INFO] cache miss',
  '[WARN] memory',
  '[INFO] request received',
  '[ERROR] timeout',
  '[INFO] response sent',
  '[DEBUG] heartbeat',
  '[ERROR] db error',
  '[WARN] disk',
];

String _buildBigLog() {
  final buf = StringBuffer();
  for (var i = 0; i < 5; i++) {
    for (final line in _logCycle) {
      buf.writeln(line);
    }
  }
  return buf.toString();
}

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

  // Tier 6 — Python + bash composition. Dropped 2026-05-09 — these
  // diluted the signal (model overshot into `cat | python -c ...`
  // chains), and dart_wasm_sandbox doesn't / won't support python
  // inside the shell. The fence is still Python; it just shouldn't
  // be the bench's measurement target. C01-C03 archived in git.

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
      stdoutContainsAll: ['20'],
      proseContainsAll: ['20'],
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
      stdoutContainsAll: ['15'],
      proseContainsAll: ['15'],
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
      stdoutContainsAll: ['4'],
      proseContainsAll: ['4'],
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
      proseContainsAll: ['20', '15', '10'],
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

  // Tier 11 — sophisticated single-fence pipes (S-tier, post-N3).
  //
  // Exercises the richer surface (pipes + sort + grep + wc + head)
  // against the larger 50-line big.log and 30-num scores.txt. Every
  // verify has a hand-checked unique-substring answer.
  BashSpec(
    id: 'S01_non_debug_count',
    prompt:
        'Use run_bash with a pipe to count how many lines in '
        '/tmp/llama-test/state/big.log are NOT DEBUG lines. '
        'Hint: cat | grep -v DEBUG | wc -l.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['45'],
      proseContainsAll: ['45'],
    ),
    maxTurns: 4,
  ),
  BashSpec(
    id: 'S02_first_error',
    prompt:
        'Use run_bash to print just the FIRST ERROR line in '
        '/tmp/llama-test/state/big.log. '
        'Hint: cat | grep ERROR | head -n 1.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['auth failed'],
      proseContainsAny: ['auth failed', 'auth'],
    ),
    maxTurns: 4,
  ),
  BashSpec(
    id: 'S03_smallest_score',
    prompt:
        'Use run_bash to print the SMALLEST number in '
        '/tmp/llama-test/fixtures/scores.txt. '
        'Hint: cat | sort -n | head -n 1.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['12'],
      proseContainsAll: ['12'],
    ),
    maxTurns: 4,
  ),
  BashSpec(
    id: 'S04_total_distinct_lines',
    prompt:
        'Use run_bash with a pipe to count how many DISTINCT lines '
        '(any severity) are in /tmp/llama-test/state/big.log. '
        'Hint: sort -u | wc -l.',
    verify: _v(
      fenceContains: '|',
      stdoutContainsAll: ['10'],
      proseContainsAll: ['10'],
    ),
    maxTurns: 4,
  ),
  BashSpec(
    id: 'S05_count_specific_message',
    prompt:
        'Use run_bash to count how many "timeout" lines are in '
        '/tmp/llama-test/state/big.log. '
        'Hint: cat | grep timeout | wc -l, or grep -c.',
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['5'],
      proseContainsAll: ['5'],
    ),
    maxTurns: 4,
  ),
  BashSpec(
    id: 'S06_distinct_severities_via_grep',
    prompt:
        'Use run_bash to confirm that /tmp/llama-test/state/big.log '
        'contains four severity tags: INFO, ERROR, WARN, DEBUG. '
        'For each tag, tell me whether at least one line has it. '
        'Hint: four `grep -c` calls (one per tag).',
    verify: _v(
      fenceContains: 'run_bash',
      proseContainsAll: ['INFO', 'ERROR', 'WARN', 'DEBUG'],
    ),
    maxTurns: 5,
  ),

  // Tier 12 — decomposition (D-tier). Tasks that need 2-3 dependent
  // run_bash calls + LLM reasoning over previous output. Tests the
  // multi-turn agent loop, not just shell composition.
  BashSpec(
    id: 'D01_largest_logfile',
    prompt:
        'Use run_bash to find the .log file under '
        '/tmp/llama-test/state with the MOST lines. Tell me the '
        'filename and the line count. Hint: `wc -l file1 file2 ...`'
        ' returns counts plus a total.',
    verify: _v(
      fenceContains: 'run_bash',
      proseContainsAll: ['big.log', '50'],
    ),
    maxTurns: 6,
  ),
  BashSpec(
    id: 'D02_first_error_message_text',
    prompt:
        'Read /tmp/llama-test/state/big.log and tell me the message '
        'text (without the [ERROR] tag) of the FIRST ERROR line. '
        'You may use any combination of run_bash calls.',
    verify: _v(
      fenceContains: 'run_bash',
      proseContainsAny: ['auth failed', 'auth'],
    ),
    maxTurns: 6,
  ),
  // Diff-detect: model has to compare two near-identical files
  // WITHOUT a `diff` command. Strategy is open — cat both, eyeball
  // in prose; or sort -u and reason; or grep one against the other.
  // Verifies the model can compose under a tool gap.
  BashSpec(
    id: 'D03_diff_files_no_diff',
    prompt:
        '/tmp/llama-test/configs/v1.txt and v2.txt are nearly '
        "identical except for ONE line. Find which line differs. "
        "You don't have a `diff` command — figure it out using only "
        'run_bash and reasoning. Tell me the differing line(s).',
    verify: _v(
      fenceContains: 'run_bash',
      proseContainsAny: ['gamma', 'GAMMA', 'line 3'],
    ),
    maxTurns: 6,
  ),
];
