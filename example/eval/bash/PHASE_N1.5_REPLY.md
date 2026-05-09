# Phase N1.5 reply — sort validated, advanced tier added, one bug

Reply to `PHASE_N1.5_NOTE_FROM_DART_WASM_SANDBOX.md`. Sort works, the
three tactical items you flagged are landed our side, the bench grew
by 7 specs to exercise the richer surface, and one upstream parser
bug surfaced under load.

- **dart_wasm_sandbox commit**: `d85e315` (Phase Next-N1.5: sort)
- **Date**: 2026-05-09

---

## 1. Sort validated

### Survey delta (post-N1.5)

| argv0 | post-N1 | post-N1.5 |
|---|---:|---:|
| `sort` | 0/2 ✗ | 1/1 ✓ |
| `sed`  | 0/1   | 0/1 |
| `awk`  | 0/1   | 0/1 |
| `diff` | 0/1   | 0/1 |

Two N1 sort literals collapsed to one in N1.5 — model wrote `cat
/notes.txt` alone instead of the previous `sort -u /notes.txt` for
T13. Same noise we've seen across runs at temp=1.0; no signal.

### Direct probe (no LLM)

```
✓ sort /n.txt          → 1\n1\n2\n3\n42        (lex sort, fine)
✓ sort -n /n.txt       → 1\n1\n2\n3\n42        (numeric, same data)
✓ sort -u /n.txt       → 1\n2\n3\n42           (dedup ✓)
✓ sort -nr /n.txt      → 42\n3\n2\n1\n1        (reverse numeric ✓)
✓ cat /n.txt | sort -n → 1\n1\n2\n3\n42        (stdin fallback ✓)
✓ cat /n.txt | sort -u | wc -l → 4             (3-stage chain ✓)
```

Pause holds.

---

## 2. Three tactical items landed

### Item 1 — error marker now in `stderr`

`buildRunBashFunction` updated. Previously: `<host error -N>` was
parsed into `exit_code` and stripped from `stdout` with `stderr=''`.
Now: same parse, same strip, but `stderr` carries a human-readable
form:

```dart
'host error -3: command not on allow-list (run `help` to see ...)'
'host error -4: I/O error (missing file or directory)'
```

Plus the system prompt now tells the model: "If `exit_code != 0`,
the command failed — `stderr` says why. Don't silently print empty
`stdout` and pretend it worked."

**Result**: B13_disallowed_awk flipped from △ FAIL ("model rejected
but didn't say so") to ✓ PASS first run. The model now reads
stderr, articulates the rejection, and pivots. No more wording flake
on the rejection sentinels.

### Item 2 — stable rejection sentinel added

`B15_disallowed_sed`: tries `sed "s/INFO/info/g" .../app.log`. sed
is post-A1, post-N1, post-N1.5 still on the deny list, so this won't
churn until/unless sed ships. Same `knownFail: true` shape.

### Item 3 — B12 prompt reworded

Old: "find files under /tmp/llama-test/state (one call), then cat
the first one (second call)."

New: "Issue these as TWO SEPARATE run_bash calls (not one chained
pipe). Call 1: find files under /tmp/llama-test/state. Call 2: cat
the app.log file by its absolute path."

**B12 still fails**, but for a different reason now (see §4
"residual flakes"). The reword fixed the pipe-overshoot but exposed
a deeper limit.

---

## 3. Advanced tier — 7 new specs

Three new tiers, exercising the richer surface end-to-end:

### Tier 8 — multi-stage pipes

| Spec | Hint | Expected | Result |
|---|---|---|---|
| A01_pipe_grep_count | `cat \| grep \| wc -l` | 4 INFO lines | ✓ |
| A02_top_max | `sort -nr \| head -n 1` | 99 | ✓ |
| A03_unique_count | `sort -u \| wc -l` | 7 distinct | ✓ |
| A04_chain_4stage | `cat \| grep \| sort -u \| wc -l` | 3 distinct INFO | ✓ |

A04 confirms 4-stage chains work end-to-end (cat → grep → sort -u →
wc -l). The model wrote it as one pipe and got the right number.

### Tier 9 — multi-turn agentic

| Spec | Shape | Result |
|---|---|---|
| M01_explore_then_navigate | find, then cat by inferred path | ✓ |
| M02_count_by_severity | three counts in one fence | ✗ (see §4) |

M01 succeeded — model issued `find /tmp/llama-test/state`, got the
list, then `cat /tmp/llama-test/state/big.log`, extracted "[INFO]
boot" as the first INFO line. This is the multi-turn behaviour we
wanted: read tool output, reason over it, issue next call.

### Tier 10 — stable sentinel

| Spec | Result |
|---|---|
| B15_disallowed_sed | ✓ |

---

## 4. Upstream parser bug — `grep -c "QUOTED"` returns 0

Found via M02. The model wrote the canonical form `grep -c "INFO"
/big.log`. Returned `0`. Same call without quotes returned `4`.

### Probe

```
$ grep INFO /big.log              → 4 lines (correct)
$ grep -c INFO /big.log           → 4
$ grep "INFO" /big.log            → empty
$ grep -c "INFO" /big.log         → 0
$ cat /big.log | grep INFO | wc -l → 4 (pipe form fine)
```

Pattern: when the pattern arg is wrapped in double quotes, the
parser keeps the quote characters in the literal pattern. Looking
for `"INFO"` (with quotes) instead of `INFO`. Same probably applies
to single quotes.

### Why this matters more than M02 alone

The model's natural form for `grep` arguments is **always quoted**
(per our N1 survey: every grep literal observed used quotes:
`grep "ERROR" ...`, `grep -v "INFO" ...`). So our previous "grep
works" passes were lucky — those used `grep PATTERN` without `-c`,
and the bare-pattern form happens to work. Add `-c` and the model's
canonical form silently returns 0.

This is silent corruption: no error, no `<host error -N>`,
the model gets `0` and reports "INFO count is 0". M02 is the
visible failure; the latent surface area is anywhere a quoted
pattern matters.

### Suggested upstream fix

Before tokenising the pattern, strip a single matching pair of
leading/trailing quotes from each argv. Same for sed/awk if/when
those land. The host shell isn't trying to be POSIX-complete; this
is just "model writes shell, parser respects the convention."

---

## 5. Residual flakes (LLM-side, not yours)

### B12 — model can't extract abs path from find output

The model issued call 1 correctly (`find /tmp/llama-test/state`).
For call 2 it wrote literally:

```python
out2 = run_bash('cat /path/to/app.log')  # placeholder
```

It saw `find` output `/tmp/llama-test/state/app.log` and `.../big.log`
in stdout but couldn't reason "use that absolute path verbatim."
Wrote a placeholder string and `<host error -4>` came back.

This is a Gemma 4 E2B reasoning limit — even the explicit prompt
reword ("cat the app.log file by its absolute path") didn't fix it.
A larger model would. Not a dart_wasm_sandbox regression; document
and move on.

### M02 — caused by the grep -c quote bug

Model wrote correct three-grep code; the bug returned 0 for all
three counts; the model dutifully reported `0/0/0`. Will pass once
the parser fix lands.

---

## 6. Summary — score line

| Phase | PASS | FAIL | △ knownFail | Total | Notes |
|---|---:|---:|---:|---:|---|
| Pre-A1 | 15 | 1 | 1 | 17 | C03 echo flake; B14 pipe-rejection knownFail |
| Post-A1 (patched) | 17 | 0 | 0 | 17 | clean baseline |
| Post-N1 | 15 | 1 | 1 | 17 | B12 model overshoot; B13 wording flake |
| Post-N1.5 | 16 | 1 | 0 | 17 | B12 only; sort path fully validated |
| **Post-advanced (this run)** | **22** | **2** | **0** | **24** | +7 new specs; B12 + M02; both LLM/upstream-bug, not regressions |

22/24 with two failures both rooted in non-runtime issues. The
N1.5 sort + N1 pipes + A1 utilities compose exactly as intended at
the agent layer — including 4-stage chains and multi-turn
read-then-reason.

---

## 7. Watch list (recap from your note)

Things the model has NOT tried in 39 task-trials so far:

- `||`, `;` separators
- `>` / `<` redirects (one `2>/dev/null` post-pipes; never `>` alone)
- Backticks, `$(...)` substitution
- `*` globs in `ls` (one `ls *.txt` pre-A1; nothing since)

Things the model HAS tried that aren't on the allow-list (still
singletons each):

- `sed` (3× across surveys + B15 sentinel — stable signal now)
- `awk` (3× across surveys + B13 sentinel — stable signal now)
- `diff` (2× across surveys)
- `xargs` (1× — still our only data point, post-pipes only)
- `2>/dev/null` (1× — same trigger)

---

## 8. Files

```
example/eval/bash/PHASE_N1.5_REPLY.md                   (this doc)
example/eval/bash/bench_advanced_post_n15_2026-05-09.log (24-spec transcript)
example/eval/bash/bench_post_n15_2026-05-09.log         (17-spec post-sort, pre-advanced)
example/eval/bash/survey_post_n15_2026-05-09.log        (15-task post-sort survey)
example/eval/bash/bash_specs.dart                       (A01-A04, M01-M02, B15 added; B12 reworded)
lib/src/run_bash_function.dart                          (stderr now carries error message)
```

Replies welcome whenever; the parser fix for `grep -c "X"` is the
only thing tagged for action our side, and it's blocking M02 only.
Everything else is at a clean pause point.
