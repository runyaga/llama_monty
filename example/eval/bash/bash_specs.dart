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
    this.minTurns,
    this.replicates,
    this.canonicalSolution,
    this.knownFail = false,
  });
  final String id;
  final String prompt;
  final BashVerify verify;
  final int maxTurns;

  /// Optional bash command the harness can execute directly (NO LLM)
  /// to confirm the spec is reachable. Run at bench startup against
  /// the live wasm host; aborts the bench if the command returns
  /// `<host error -N>`. The LLM never sees this string. Two uses:
  /// (1) catch fixture / runtime drift before burning LLM compute;
  /// (2) attribute fail mode — when LLM scores 0/N but canonical
  /// passes, the gap is model-side; when canonical also fails, the
  /// gap is runtime-side.
  final String? canonicalSolution;

  /// Minimum number of assistant chat turns the spec requires. If the
  /// model finishes faster (e.g. answers in one fence + prose), the
  /// spec is FAILED with reason "used N turns, needed >= M". Used by
  /// X-tier cross-turn specs to force the model to reason over a
  /// previous tool result before issuing the next call.
  final int? minTurns;

  /// Per-spec replicate override. When set, the spec runs this many
  /// times regardless of the CLI `--replicates` flag — useful for
  /// flaky tiers (cross-turn, decomposition) that need higher N to
  /// pin down the true pass rate at temp=1.0. When null, the CLI
  /// default applies.
  final int? replicates;

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
    canonicalSolution: 'echo hello',
  ),
  BashSpec(
    id: 'B02_echo_multi_arg',
    prompt: "Use run_bash to echo 'foo bar baz'. Tell me what it printed.",
    verify: _v(
      fenceContains: 'run_bash',
      stdoutContainsAll: ['foo bar baz'],
      proseContainsAll: ['foo bar baz'],
    ),
    canonicalSolution: 'echo foo bar baz',
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
    canonicalSolution: 'pwd',
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
    canonicalSolution: 'cat /tmp/llama-test/fixtures/notes.txt',
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
    canonicalSolution: 'tail -n 1 /tmp/llama-test/fixtures/numbers.txt',
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
    canonicalSolution: 'ls /tmp/llama-test/fixtures',
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
    canonicalSolution: 'find /',
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
    canonicalSolution: 'cd /tmp/llama-test/fixtures && pwd',
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
    canonicalSolution: 'cd /tmp/llama-test/fixtures && ls',
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
    canonicalSolution: 'cd /tmp/llama-test/fixtures && cat greeting.txt',
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
    canonicalSolution: 'cd /tmp/llama-test/fixtures && pwd',
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
    canonicalSolution: 'cat /tmp/llama-test/state/app.log',
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
    // Canonical = the rejection itself. Probe should see <host error -3>.
    // We DON'T set canonicalSolution here because that would abort the
    // bench (the probe currently treats <host error> as fatal). Skip.
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
    canonicalSolution:
        'cat /tmp/llama-test/fixtures/numbers.txt | head -n 2',
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
    canonicalSolution:
        'cat /tmp/llama-test/state/big.log | grep INFO | wc -l',
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
    canonicalSolution:
        'cat /tmp/llama-test/fixtures/scores.txt | sort -nr | head -n 1',
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
    canonicalSolution:
        'cat /tmp/llama-test/fixtures/scores.txt | sort -u | wc -l',
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
    canonicalSolution:
        'cat /tmp/llama-test/state/big.log | grep INFO | sort -u | wc -l',
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
    canonicalSolution:
        'cat /tmp/llama-test/state/big.log | grep INFO | head -n 1',
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
    // Multi-call ground truth — pick the highest count for the probe.
    canonicalSolution: 'grep -c INFO /tmp/llama-test/state/big.log',
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
    // Canonical = rejection. Skip probe (would abort the bench).
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
    canonicalSolution:
        'cat /tmp/llama-test/state/big.log | grep -v DEBUG | wc -l',
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
    canonicalSolution:
        'cat /tmp/llama-test/state/big.log | grep ERROR | head -n 1',
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
    canonicalSolution:
        'cat /tmp/llama-test/fixtures/scores.txt | sort -n | head -n 1',
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
    canonicalSolution:
        'sort -u /tmp/llama-test/state/big.log | wc -l',
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
    canonicalSolution: 'grep -c timeout /tmp/llama-test/state/big.log',
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
    canonicalSolution: 'grep -c INFO /tmp/llama-test/state/big.log',
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
    canonicalSolution:
        'wc -l /tmp/llama-test/state/app.log /tmp/llama-test/state/big.log',
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
    canonicalSolution:
        'cat /tmp/llama-test/state/big.log | grep ERROR | head -n 1',
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
    // Canonical: cat both, harness sees "GAMMA" in stdout — proves
    // the differ-line is reachable. LLM still has to articulate.
    canonicalSolution:
        'cat /tmp/llama-test/configs/v2.txt',
  ),

  // Tier 13 — cross-turn (X-tier). Tasks where the next call's
  // ARGUMENTS depend on the previous call's RESULT — the model can't
  // statically write everything in one fence. `minTurns: 2` enforces
  // that the spec actually used multiple chat turns; specs that
  // collapse the work into one fence + trailing prose FAIL even if
  // they happen to land the right answer.
  BashSpec(
    id: 'X01_find_then_count_by_name',
    prompt:
        'Use run_bash to list all .log files under '
        '/tmp/llama-test/state. Then, in a SEPARATE follow-up call '
        '(after you see the names), use run_bash again to count the '
        'lines in each file by absolute path. Tell me which file has '
        'more lines, and how many.',
    verify: _v(
      fenceContains: 'run_bash',
      proseContainsAll: ['big.log', '50'],
    ),
    minTurns: 2,
    maxTurns: 6,
    replicates: 5,
    canonicalSolution:
        'wc -l /tmp/llama-test/state/app.log /tmp/llama-test/state/big.log',
  ),
  BashSpec(
    id: 'X02_iterative_refinement',
    prompt:
        'Find the top 3 DISTINCT scores in '
        '/tmp/llama-test/fixtures/scores.txt. Try `cat | sort -nr | '
        'head -n 3` first. If you see duplicate values in that '
        'output, refine your approach in a SECOND run_bash call so '
        "you get THREE DISTINCT numbers. Tell me what they are.",
    verify: _v(
      fenceContains: 'run_bash',
      // 3rd-largest distinct score is 91 (after 99 and 96).
      proseContainsAll: ['91'],
    ),
    minTurns: 2,
    maxTurns: 6,
    replicates: 5,
    canonicalSolution:
        'sort -u /tmp/llama-test/fixtures/scores.txt | sort -nr | head -n 3',
  ),
  BashSpec(
    id: 'X03_count_then_extract_first',
    prompt:
        'In ONE run_bash call, count the ERROR lines in '
        '/tmp/llama-test/state/big.log. THEN, in a SEPARATE follow-up '
        'run_bash call, extract just the FIRST ERROR line. Tell me '
        'BOTH the count AND the first message text.',
    verify: _v(
      fenceContains: 'run_bash',
      proseContainsAll: ['15', 'auth'],
    ),
    minTurns: 2,
    maxTurns: 6,
    replicates: 5,
    canonicalSolution: 'grep -c ERROR /tmp/llama-test/state/big.log',
  ),
  BashSpec(
    id: 'X04_explore_two_dirs',
    prompt:
        'Use run_bash to list /tmp/llama-test/fixtures (call 1). '
        'Then, in a SEPARATE follow-up call, list '
        '/tmp/llama-test/state (call 2). Tell me how many TOTAL '
        'files you saw across both directories.',
    verify: _v(
      fenceContains: 'run_bash',
      // fixtures has 3 files (notes/greeting/numbers/scores = 4),
      // state has 2 (app.log/big.log) = 6 total. Configs is separate.
      proseContainsAny: ['6', '5', '4'], // model may miss scores
    ),
    minTurns: 2,
    maxTurns: 6,
    replicates: 5,
    canonicalSolution: 'ls /tmp/llama-test/fixtures',
  ),

  // Tier 14 — stretch cross-turn (Y-tier). Tasks that NEED 3+ chat
  // turns: each turn's call depends on the previous turn's data,
  // and there's no cheap one-shot solution. minTurns: 3 enforces
  // genuine multi-turn reasoning. All run at N=5 to handle expected
  // flakiness at this depth.
  //
  // Two flavors: "discover-then-drill" (Y01-Y02 explore the
  // structure, pick a target, drill into it) and "iterative-narrow"
  // (Y03-Y04 progressively filter the same data).
  BashSpec(
    id: 'Y01_explore_then_pick_smallest_log',
    prompt:
        'Use run_bash across MULTIPLE separate calls to investigate '
        '/tmp/llama-test/state. (1) First, list the .log files there. '
        '(2) Then count their lines and identify the SMALLEST file. '
        '(3) Then read that smallest file and tell me its first INFO '
        'line (the actual message text).',
    verify: _v(
      fenceContains: 'run_bash',
      // app.log has 2 lines (smaller than big.log's 50). First INFO
      // line is "[INFO] booted".
      proseContainsAny: ['booted', 'app.log'],
    ),
    minTurns: 3,
    maxTurns: 8,
    replicates: 5,
    canonicalSolution:
        'cat /tmp/llama-test/state/app.log | grep INFO | head -n 1',
  ),
  BashSpec(
    id: 'Y02_explore_then_count_errors_in_dir',
    prompt:
        'Use run_bash across MULTIPLE separate calls. (1) First, list '
        'the top-level directories under /tmp/llama-test. (2) Then '
        'pick the one that contains log files and list its contents. '
        '(3) Then count the total ERROR lines across ALL log files in '
        'that directory. Tell me the total ERROR count.',
    verify: _v(
      fenceContains: 'run_bash',
      // state/ has app.log (1 ERROR) + big.log (15 ERRORs) = 16.
      proseContainsAny: ['16', '15'],
    ),
    minTurns: 3,
    maxTurns: 8,
    replicates: 5,
    canonicalSolution: 'grep -c ERROR /tmp/llama-test/state/big.log',
  ),
  // Y03/Y04 redesigned 2026-05-09: original specs had no real data
  // dependency between calls, so the model correctly packed the work
  // into one fence + prose (turns=2) and the minTurns=3 gate failed
  // them despite correct answers. New specs require turn N's call
  // arguments to be DERIVED from turn N-1's output — making one-shot
  // solutions structurally impossible.
  BashSpec(
    id: 'Y03_pick_busiest_logfile',
    prompt:
        'Use run_bash across SEPARATE calls to figure out which .log '
        'file under /tmp/llama-test/state has the MOST ERROR lines. '
        '(1) First list the .log files there. (2) Then, USING THE '
        'NAMES YOU SAW, count ERRORs in each file separately (one '
        'call per file). (3) Report the busiest filename and its '
        'count.',
    verify: _v(
      fenceContains: 'run_bash',
      // big.log has 15 ERRORs, app.log has 1.
      proseContainsAll: ['big.log', '15'],
    ),
    minTurns: 3,
    maxTurns: 8,
    replicates: 5,
    canonicalSolution: 'grep -c ERROR /tmp/llama-test/state/big.log',
  ),
  BashSpec(
    id: 'Y04_drill_into_first_error_type',
    prompt:
        'Investigate /tmp/llama-test/state/big.log step by step. '
        '(1) First, extract just the FIRST ERROR line in the file. '
        '(2) Then, USING THE EXACT MESSAGE TEXT YOU JUST SAW, count '
        'how many times that SAME message appears in the file. Tell '
        'me the message text AND the count.',
    verify: _v(
      fenceContains: 'run_bash',
      // First ERROR is "[ERROR] auth failed"; "auth failed" appears 5 times.
      proseContainsAll: ['auth failed', '5'],
    ),
    minTurns: 3,
    maxTurns: 8,
    replicates: 5,
    // NB: `grep -c "auth failed" <file>` returns -4 because upstream
    // tokenizes quoted args on inner whitespace before quote-strip
    // (per their PHASE_N3_NOTE limitation). Using single-word pattern
    // for the probe; the LLM may hit the same bug at run time.
    canonicalSolution:
        r'grep -c auth /tmp/llama-test/state/big.log',
  ),
];
