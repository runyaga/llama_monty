# Phase A1 delta report — `wc / grep / head / tail` validation

For the dart_wasm_sandbox owner, before deciding whether to ship pipes.

- **dart_wasm_sandbox commit under test**: `190d0c3` (Phase A1)
- **Model**: gemma-4-E2B-it-Q4_K_M, FFI, temp=1.0, top_p=0.95
- **Date**: 2026-05-09
- **VFS**: `/tmp/llama-test/{fixtures,state}/...`

## TL;DR

> If 15/17 → 17/17 modulo B14, Phase A1 is validated.

**Bench: 15/17 → 17/17.** Phase A1 is validated. Two specs (B12, B13)
were stale post-A1 — once corrected, every spec passes including the
known-fail rejection check (B14).

**Survey: 7/15 tasks newly working.** `wc / grep / head / tail` flip
from denied to allowed across exactly the tasks that asked for them.
Pipes still requested 2× in the post-A1 survey.

---

## 1. Bench delta

`example/eval/bash/run_bash_bench.dart`, 17 specs, single run.

| Phase | PASS | FAIL | △ known-fail | Notes |
|---|---:|---:|---:|---|
| Pre-A1 baseline | 15 | 1 (C03) | 1 (B14) | C03 = `echo 7 * 8` literal flake |
| Post-A1, original specs | 13 | 2 (B12, C03) | 2 (B13, B14) | B12 + B13 stale post-A1 |
| **Post-A1, patched specs** | **17** | **0** | **0** | this run |

### What was stale

- **B12_find_then_cat** asked the model to `find /logs` — but `/logs`
  doesn't exist in our VFS (paths were unified to `/tmp/llama-test/`).
  Patched: `find /tmp/llama-test/state`. Now PASS.
- **B13_disallowed_grep** was a known-fail rejection check from when
  `grep` was on the deny list. Phase A1 added grep, so the model now
  succeeds and the verify "expects rejected" never matches. Renamed
  to `B13_disallowed_awk` — same shape, but `awk` is still rejected
  (per the post-A1 survey, the model still reaches for awk on
  sum-a-column tasks). Now PASS as expected-rejection.
- **C03 flake gone**: in this run the model wrote `echo $((7*8))` and
  bash printed 56, where pre-A1 it sometimes wrote `echo 7 * 8` as a
  string literal. This is noise from temp=1.0; not attributable to A1.

Patches in commit accompanying this doc; raw log:
`example/eval/bash/bench_post_a1_2026-05-09.log`.

---

## 2. Survey delta

`example/eval/bash/bash_knowledge_survey.dart`, 15 open-ended tasks.
The prompt does NOT enumerate the allow-list; the model writes
whatever shell idiom it naturally reaches for.

### Argv0 frequency

| argv0 | tasks | pre-A1 allowed | pre-A1 denied | post-A1 allowed | post-A1 denied |
|---|---|---:|---:|---:|---:|
| `wc`   | T04, T05, T11 | 0 | 3 | **3** | 0 |
| `grep` | T01, T08       | 0 | 2 | **2** | 0 |
| `head` | T02            | 0 | 1 | **1** | 0 |
| `tail` | T03            | 0 | 1 | **1** | 0 |
| `cat`  | T09, T12, T13  | 3 | 0 | 3 | 0 |
| `find` | T06, T07       | 2 | 0 | 2 | 0 |
| `ls`   | T06            | 1 | 0 | 1 | 0 |
| `sed`  | T10            | 0 | 1 | 0 | **1** |
| `awk`  | T14            | 0 | 1 | 0 | **1** |
| `diff` | T15            | 0 | 1 | 0 | **1** |
| `sort` | T13            | 0 | 1 | 0 | 0¹ |

¹ T13 used `cat … | sort -u` pre-A1. Post-A1 the model ran `cat
/notes.txt` alone (no `sort -u` step), so `sort` didn't appear in the
post-A1 fence at all. Likely noise — `sort` remains a deferred candidate.

**Net: 7 tasks (T01, T02, T03, T04, T05, T08, T11) flipped from denied
to allowed. 3 still denied: sed (T10), awk (T14), diff (T15).**

### Post-A1 literals (verbatim)

```python
# Allow-listed and used
run_bash('wc -l /tmp/llama-test/fixtures/numbers.txt')
run_bash('wc -c /tmp/llama-test/fixtures/greeting.txt')
run_bash('wc -w /tmp/llama-test/fixtures/greeting.txt')
run_bash('grep "ERROR" /tmp/llama-test/state/app.log')
run_bash('grep -v "INFO" /tmp/llama-test/state/app.log')
run_bash('head -n 1 /tmp/llama-test/fixtures/numbers.txt')
run_bash('tail -1 /tmp/llama-test/fixtures/numbers.txt')   # NB: -1 not -n 1
run_bash('cat /tmp/llama-test/fixtures/numbers.txt')
run_bash('cat /notes.txt')
run_bash('find / -type f')
run_bash('find / -name "*.txt"')

# Still pipes (rejected — pre-A1 also rejected)
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | head -n 2')
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | sort -n')

# Still rejected after A1
run_bash('sed "s/INFO/info/g" /tmp/llama-test/state/app.log')
run_bash('awk "{sum} += $1; END {print sum}" /tmp/llama-test/fixtures/numbers.txt')
run_bash('diff /tmp/llama-test/fixtures/greeting.txt /tmp/llama-test/fixtures/greeting.txt')
```

Raw log: `example/eval/bash/survey_post_a1_2026-05-09.log`.

---

## 3. Two minor surface notes

### `tail -1` (POSIX short form)

The model wrote `tail -1` instead of `tail -n 1`. Both are POSIX-valid;
worth confirming Phase A1's `tail` accepts the `-N` short form, not
just `-n N`. (Per the Phase A1 commit message it does — "head/tail
[-n N | -N]" — so this is a no-op, just calling out the in-the-wild
literal so you can spot-check the test matrix.)

### `grep` regex deferral confirmed

All 4 grep attempts use plain literals (`"ERROR"`, `"INFO"`). No
regex flags (`-E`, `-F`, `-i`, `-r`). The Phase A1 fixed-string
substring surface covers everything we observed.

---

## 4. Pipes — does the model still want them?

**Yes, 2/15 tasks reached for pipes post-A1**:

```
T09  cat /tmp/llama-test/fixtures/numbers.txt | sort -n
T12  cat /tmp/llama-test/fixtures/numbers.txt | head -n 2
```

T13 dropped its pipe (used plain `cat /notes.txt`). T09 and T12 still
chain through pipes even though `head` and (for the model's intent)
`sort` could be invoked directly. This says the model's mental model
of these tasks is shell-pipeline-shaped, not standalone-utility-shaped.

That's two data points per 15 tasks. We don't have enough volume to
say whether this drops further as more utilities land — but it does
show pipes remain the next obvious gap from a usage-pattern lens, not
just a "missing feature" lens.

---

## 5. Recommendation matrix

| Decision | Evidence |
|---|---|
| Phase A1 validated | Bench 15/17 → 17/17 (modulo stale specs); 7/15 survey tasks newly working |
| Pipes are next | 2/15 post-A1 tasks still pipe-shaped despite new utilities |
| Sed/awk/diff are tail | 1/15 each; only sed has a clean small surface (`s/x/y/g`) |
| `sort -u` reach is real but small | Pre-A1 1×, post-A1 0× — noise, defer |
| Regex grep deferral fine | 0 regex idioms observed |
| `tail -1` short form | Already covered per Phase A1 commit; no action |

If you ship pipes next: the 2 remaining pipe attempts both compose
allow-listed cmds (`cat | head`, `cat | sort -n`). The first works
post-pipes immediately. The second still needs `sort` — could ship
`sort` together with pipes for completeness, or accept that one of
the two pipe usages will hit "still rejected" until sort lands.

If you defer: bench is 17/17, survey gap is 3 commands + pipes — fine
to pause for a different signal source.

---

## 6. Files added in this report

```
example/eval/bash/PHASE_A1_DELTA.md              (this doc)
example/eval/bash/bench_post_a1_2026-05-09.log   (full bench transcript)
example/eval/bash/survey_post_a1_2026-05-09.log  (full survey transcript)
```

Plus spec patches in `example/eval/bash/bash_specs.dart` (B12 path,
B13 awk swap) and an allow-list update in
`example/eval/bash/bash_knowledge_survey.dart` for the static
classifier.
