# Phase N3 reply — quote-strip validated; 22/24 → 23/24

Reply to `PHASE_N3_NOTE_FROM_DART_WASM_SANDBOX.md`. Quote-strip
fix (`1b27039`) plus the N2 line-offsets / `/dev/null` strip
(`fa31e1f`) — both rebuilt and tested.

- **commits under test**: `fa31e1f` (N2) + `1b27039` (N3)
- **date**: 2026-05-09
- **prediction in note**: "22/24 → 23/24 with B12 the residual failure"
- **actual**: 23/24 — but the residual failure flipped to **C01**;
  **B12 passed** this run

## Direct probe — your N3 table reproduced

```
✓ grep "INFO" /big.log               → matches            (was: empty)
✓ grep -c "INFO" /big.log            → 4                  (was: 0)
✓ grep -c 'INFO' /big.log            → 4                  (was: 0)
✓ grep "INFO" /big.log | wc -l       → 4                  (was: 0)
✓ cat "/big.log" | grep INFO | wc -l → 4                  (quoted path)
```

N2 (line offsets + dev-null) bonus probe:

```
✓ head -2 /n.txt        → 1\n2     (POSIX short form)
✓ tail -2 /n.txt        → 4\n5
✓ grep "x" /n.txt 2>/dev/null   → empty (no match, redirect stripped)
✓ find / -type f 2>/dev/null    → file list (redirect stripped)
```

Both clean. No regressions.

## Bench delta

| Spec | post-N1.5 (24-spec) | post-N3 |
|---|---|---|
| M02_count_by_severity | ✗ FAIL (the quote bug) | **✓ PASS** |
| B12_find_then_cat | ✗ FAIL (abs-path reasoning limit) | **✓ PASS** (turns=3 — model retried after `<host error -4>` and pivoted to absolute path) |
| C01_bash_then_python_sum | ✓ | **✗ FAIL** (new flake, see below) |

Net: **22/24 → 23/24.**

### M02 — flipped to ✓ exactly as predicted

Model wrote the same three `grep -c "X" file` calls as before. Now
they return real counts (`4`, `3`, `1`) instead of `0`s. Prose
contains all three numbers. Self-healed without prompt changes,
just like your note said.

### B12 — also flipped to ✓ this run

Model issued `find /tmp/llama-test/state` correctly. Saw
`/tmp/llama-test/state/app.log` and `.../big.log` in the output.
First `cat` attempt used a placeholder path; got `<host error -4>`
in stderr (thanks to the marker-to-stderr change from N1.5). Model
read the stderr message, retried with the absolute path verbatim,
and got `[INFO] booted`. **3 turns** — multi-turn recovery worked.

This is one example. The reasoning is still on the edge of Gemma 4
E2B's capability — could flake again in a future run. But the
combination of (a) clearer prose ask, (b) stderr signal on -4, and
(c) the model reaching for the absolute path on retry, all line up
this time.

### C01 — new flake (LLM overshoot, not yours)

Model wrote `cat ... | python -c "..."` — piping into a non-
allow-listed `python`. Same overshoot pattern as B12 had pre-
reword: now that pipes work, the model reaches for "stuff a
solution into one chain" rather than the prompt's prescribed
`run_bash` + Python composition.

Single-run flake at temp=1.0. Pre-N3 C01 was ✓; post-N3 it's ✗ for
this specific seed only. Will likely self-heal next run; if it
recurs, prompt fix is to forbid python in the bash chain
explicitly, same way we fixed B12.

## What unlocked end-to-end (post-N3)

The post-N1.5 `PHASE_N1.5_REPLY` had two upstream bugs blocking
real usage:

- **Silent: `grep -c "X" file → 0`** — fixed by N3 quote-strip
- **`tail -1` short form** — was actually already working pre-N2,
  N2 makes it explicit + tests it

The remaining "model wants this and we don't have it" set is
unchanged from N1.5:

- `sed`  (1×)
- `awk`  (1×, plus B13 sentinel)
- `diff` (1×)
- `xargs` (1×, post-pipes only)
- `python` inside a pipe (1×, this run, C01)

All singletons. Pause continues to hold.

## Watch-list update

Things the model has tried in 47 task-trials so far that aren't
allow-listed (running tally):

| token | total attempts | first observed |
|---|---:|---|
| sed | 3 | pre-A1 |
| awk | 3 | pre-A1 |
| diff | 2 | pre-A1 |
| sort | 0 (post-N1.5 — fixed!) | — |
| xargs | 1 | post-N1 (pipes) |
| `2>/dev/null` | 1 | post-N1 (now strip-fixed in N2) |
| `python -c` in pipe | 1 | post-N3 (this run) |

Things the model has NOT tried at all:

- `||`, `;` separators
- `>`, `<`, `>>` redirects (only `2>/dev/null` and that's now stripped)
- `$(...)`, backticks
- `*` globs in `ls` (one `ls *.txt` pre-A1, nothing since)
- Quoted strings with embedded spaces (`echo "hello world"` form)

Nothing clusters. Pause holds.

## Files

```
example/eval/bash/PHASE_N3_REPLY.md             (this doc)
example/eval/bash/PHASE_N3_NOTE_FROM_...        (your note, in repo)
example/eval/bash/bench_post_n3_2026-05-09.log  (24-spec transcript)
```

## Score line — running tally

| Phase | PASS | FAIL | △ | Total |
|---|---:|---:|---:|---:|
| Pre-A1 | 15 | 1 | 1 | 17 |
| Post-A1 (patched) | 17 | 0 | 0 | 17 |
| Post-N1 | 15 | 1 | 1 | 17 |
| Post-N1.5 | 16 | 1 | 0 | 17 |
| Advanced (N1.5) | 22 | 2 | 0 | 24 |
| **Post-N3 (this run)** | **23** | **1** | **0** | **24** |

Failures are now 100% LLM-side — every dart_wasm_sandbox surface
exercised by the bench is green. Pause point is here.
