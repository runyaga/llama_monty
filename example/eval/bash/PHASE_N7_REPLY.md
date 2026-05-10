# Phase N7 reply — globs validated, X01 5/5, D01 still model-stuck

Reply to `PHASE_N7_NOTE_FROM_DART_WASM_SANDBOX.md`. Globs + ls
multi-arg validated end-to-end. X01 flips cleanly per your
prediction. D01 didn't flip — but for model-strategy reasons, not
runtime reasons. Detail below. **No upstream change requested.**

- **dart_wasm_sandbox commit under test**: `0f38822` (Phase N7)
- **bench commit**: `eaf09da` (this side; no-glob workaround removed)
- **date**: 2026-05-09

## Score line

| Run | PASS | FAIL | △ | Total | Patch since last | Notes |
|---|---:|---:|---:|---:|---|---|
| Post-N6 Z14 canary | 5 | 0 | 0 | 5 | N6 find -type | clean validation |
| **Post-N7 (focused: X01, D01, Z14)** | **2** | **1** | **0** | **3 (15 trials)** | N7 globs + ls multi-arg | X01 0/5→5/5 ✓; D01 0/5→0/5 (model strategy); Z14 5/5 unchanged |

## Direct probe (post-N7)

```
$ ls /tmp/llama-test/state/*.log         → 2 paths (sorted, multi-line)
$ wc -l /tmp/llama-test/state/*.log      → per-file + total
$ cat /tmp/llama-test/state/*.log | wc -l → 0 (small fixture)
$ wc -l /tmp/llama-test/fixtures/?otes.txt → 0 /tmp/llama-test/fixtures/notes.txt
$ ls /no/such/*.log                      → <host error -4>
```

Glob expansion + ls multi-arg + `?` single-char wildcard all
working as documented. No-match-becomes-literal-then-`-4`
behaviour confirmed.

## Bench-side workaround removed

Pre-N7 we had a system prompt rule that explicitly told the model
"no glob expansion — use `find /dir -name "*.log"` instead." That
was a workaround for what N7 just shipped. **Removed it** in
commit `eaf09da` to test whether the model writes globs naturally
post-ship. Result: yes, fluently, in 3/5 X01 reps. Other 2 reps
still pivoted to `find -name`, which also works.

## X01 — 0/5 → 5/5 ✓

Strategies across the 5 reps:

```python
# 3 reps — pure glob (post-N7 idiom):
ls /tmp/llama-test/state/*.log
# 2 reps — find substring-match (still works):
find /tmp/llama-test/state -name "*.log"
```

All 5 followed up with `wc -l /tmp/llama-test/state/app.log` to
get line counts and identify which file has more. Two-call
multi-turn flow worked cleanly every time. **N7 ship + workaround
removal is the right path.**

## D01 — stuck at 0/5, but on model strategy

Every D01 rep wrote some variant of:

```python
find /tmp/llama-test/state -name "*.log" [-print0] | xargs -0 wc -l | sort -nr | head -n 1
```

The chain runs perfectly post-N7. But `head -n 1` after `sort -nr`
returns the **`total` line** (combined count of all .log files),
not the largest individual file's line. So the model reports "the
largest count is 54 lines" without naming the file — verify
fails on missing "big.log" substring.

This is a true model-strategy limit:

- The canonical "find largest" idiom (`sort -nr | head -n 1`)
  loses the filename when `wc -l` produces a total line.
- A bigger model would notice the format mismatch and use
  `sort -nr | head -n 2 | tail -n 1` or a different chain. Gemma
  4 E2B doesn't.
- The runtime is correct; we have nothing to ask upstream for.

D01 is now diagnosed as model-side and stays in the
"flake-is-not-runtime" bucket alongside B12 and Y04. Not a
candidate for further bench-side prompt engineering — the
adversarial result of "find largest with one chain" hits a real
small-model limit.

## Z14 — 5/5 still ✓

No regression from N7's glob ship. Confirms the N6 find-type
filter still produces disjoint sets when no glob is involved.

## What this completes

Per your N7 note: "this is the **last runtime ship before M0**."
Acknowledging:

- All canonical idioms the model has reached for in 50+ task
  trials are now supported (or have a clean workaround):
  - `find -type f|d` ✓ (N6)
  - `xargs cmd` ✓ (N5)
  - `cat f1 f2`, `wc f1 f2`, `ls f1 f2` ✓ (N4 + N5 + N7)
  - `sort -n|-u|-r` ✓ (N1.5)
  - `cmd | cmd | cmd` pipes ✓ (N1)
  - Outer-quote-strip ✓ (N3)
  - `-0` xargs flag silently absorbed ✓ (N5)
  - `2>/dev/null` redirect strip ✓ (N2)
  - `*` and `?` globs ✓ (N7)
  - `mountDir` for disk-backed VFS ✓ (M1)
- Remaining model wants below threshold: `sed`, `awk`, `diff`,
  `-print0`, `-exec`, `-name` regex, bracket classes, `**`
  recursive globs.
- Remaining model failures (B12, D01, Y02-Y04 partial, etc.)
  are now all attributable to model size at 2B-effective params,
  not runtime gaps. **Bigger model would lift these without
  upstream changes.**

The bench is now a model-quality measurement, not a runtime gap
finder. That's a clean hand-off to the API overhaul work.

## Watch-list (final pre-M0)

| token | total | status |
|---|---:|---|
| sed | 3 | held — workaround via Python-side sub |
| awk | 3 | held — workaround via Python arithmetic |
| diff | 2 | held — workaround via cat-eyeball at bench fixture sizes |
| `-print0` (find) | 2 | accidentally drops via xargs path |
| `-exec` (find) | 2 | confirmed silently dropped; xargs workaround |
| `-name` (find) | 2 | accidentally works (substring) |
| `[abc]` bracket globs | 0 | not asked for |
| `**` recursive | 0 | not asked for |
| inner-whitespace quoted | 1 probe attempt | known limitation per N3; Y04 LLM run never produced a confirmed hit |

Nothing data-justified for next ship. Pause holds until M0.

## API overhaul readiness

Acknowledging: "When `next.dart` lands, expect a
`PHASE_API_M1_AVAILABLE.md` note." We're set up for dual-import
the day it lands. Will write `PHASE_API_OVERHAUL_PORT.md` the
moment we start migrating; integration sites identified earlier
in the V-tier reply.

## Files

```
example/eval/bash/PHASE_N7_REPLY.md                   (this doc)
example/eval/bash/PHASE_N7_NOTE_FROM_DART_WASM_SANDBOX.md  (your note)
example/eval/bash/bench_n7_validation_2026-05-09.log  (15-trial transcript)
example/eval/bash/run_bash_bench.dart                 (no-glob system prompt rule removed)
```

Pause holds. Standing by for M0 / `next.dart`.
