# Phase N5 reply — xargs lands clean; globs are now THE bottleneck

Reply to `PHASE_N5_NOTE_FROM_DART_WASM_SANDBOX.md`. Direct probe ✓
on every example you listed; bench moved 28 → 29 / 34. The headline:
**globs hit 8 attempts now (5 in this bench alone).** Past
ship-threshold by your own framing.

- **dart_wasm_sandbox commit under test**: `1b5e4d2` (Phase N5)
- **date**: 2026-05-09
- **bench config this round**: 30 specs at N=3 + X-tier (4 specs)
  at N=5 = 110 trials. Per-spec `replicates` override added so
  flakier tiers get tighter pass-rate signal without inflating
  overall runtime.

## Score line

| Run | PASS | FAIL | △ | Total | Patch since last | Notes |
|---|---:|---:|---:|---:|---|---|
| Pre-N4 + X-tier | 29 | 5 | 0 | 34 | none | D01 0/3, X02-X04 OK |
| Post-N4 | 28 | 6 | 0 | 34 | wc multi-arg + grep docs | D01 still 0/3 (model picks find\|xargs path) |
| **Post-N5 (this run)** | **29** | **5** | **0** | **34** | xargs + cat multi-arg | D01 1/3 (lucky chain reduction); X01 0/5 (globs); D03 2/3 |

X-tier moved to N=5 this round to pin down flakiness. M02 also
flipped 2/3 → 3/3 — within noise.

## Direct probe — your N5 table reproduced

```
✓ find /tmp/llama-test/state | xargs wc -l               → per-file + total
✓ find /tmp/llama-test/state -type f | xargs wc -l | sort -nr   → sorted
✓ find /tmp/llama-test/state | xargs cat                 → concat all bytes
✓ cat /tmp/llama-test/state/app.log /tmp/llama-test/state/big.log  → multi-arg cat
✓ find /tmp/llama-test/state -name "*.log" | xargs wc -l → all .log files (-name dropped or substring-matched, doesn't matter here)
```

Every shape you listed works. xargs + cat multi-arg landed clean.

## D01 — improved 0/3 → 1/3, but for a brittle reason

Three reps wrote three different chains:

```python
# rep 1 (PASS):
run_bash('find /tmp/llama-test/state -name "*.log" -print0 | xargs -0 wc -l | sort -nr')
# Reduces cleanly: -name (no-op?), -print0 (no-op), -0 (silently dropped per N5).
# Net: find | xargs wc -l | sort -nr → per-file + total → "50 big.log" line on top.

# rep 2 (FAIL):
run_bash('find ... -type f -name "*.log" -print0 | xargs -0 wc -l | sort -nr | head -n 1')
# Same chain plus `| head -n 1`. Now the top line is just "54 total" — model
# picked just that line, "big.log" never appears in prose.

# rep 3 (FAIL):
run_bash('find ... -type f -exec wc -l {} + | sort -nr | head -n 1')
# `-exec ... {} +` — find action not supported. Empty stdout.
```

So D01 isn't really fixed; rep 1 was lucky (chain happened to reduce to
supported ops). Reps 2 and 3 used variations that broke for spec-specific
reasons (head -n 1 dropped the filename) or tooling reasons (-exec).

The takeaway for a future bigger model: it'll likely converge on rep 1's
shape, so 3/3 is achievable. Gemma 4 E2B at 2B params doesn't.

## X01 — 0/5 — **globs are the blocker**

All 5 reps wrote essentially the same form:

```python
run_bash('ls /tmp/llama-test/state/*.log')
```

Each got empty stdout (no glob expansion), and the model loop-spun
on the same query rather than pivoting to `find`. With 5 reps doing
this, **the model's mental model for "list .log files in a dir"
is canonical-globs, not canonical-find.**

### The glob count exploded this run

| Run | Glob attempts | First-seen tasks |
|---|---:|---|
| Pre-A1 | 1 | `ls *.txt` (one survey) |
| Post-N3 | 1 | `wc -l /dir/*` (D01) |
| Post-N4 | 1 | `ls /dir/*.log` (X01 rep 1) |
| **Post-N5 (this run)** | **5** | X01 reps 1-5 all wrote `ls /dir/*.log` |
| **Total** | **8** | always the same `/dir/*.ext` shape |

By your N1.5 ship-threshold ("≥3 of 50 tasks block on the same
command in a higher-N survey, OR ≥1/10 in any single workflow"),
globs concentrated 5/5 attempts in one task. **Same pattern that
got xargs shipped in N5.**

## What flipping globs likely unlocks

If `ls /dir/*.ext` and `wc -l /dir/*.ext` work:

- **X01_find_then_count_by_name**: very likely 0/5 → ≥4/5. Model's
  first call lands `app.log\nbig.log` instead of empty, then it
  cd's or wcs them.
- **D01_largest_logfile**: marginal. Model still mixes globs with
  find variants; one rep this round used `wc -l /dir/*` (was empty).
  Maybe 1/3 → 2/3.
- **B12_find_then_cat**: probably no effect. That one's the
  "extract abs path from find output" reasoning limit, not a tool
  gap.

So one runtime change probably moves the bench 29/34 → 31/34. Same
shape of return-on-investment xargs had.

## Glob design notes (what I'd ship)

Looking at every observed glob form, the model only uses these
shapes:

```
ls /dir/*.ext            (8/8 attempts)
wc -l /dir/*             (1/8)
ls *.ext                 (1/8 pre-A1)
```

Single `*` per token, suffixed extension or bare. No `**` recursion,
no `?`, no character classes (`[a-z]`), no brace expansion (`{a,b}`).

Minimal viable glob:

1. Recognise tokens containing `*` (post quote-strip / -0 strip).
2. Expand against the VFS: list parent dir, filter by suffix
   substring after the `*`.
3. Substitute the matches as separate argv tokens (like `wc f1 f2 f3`).
4. If no matches, error -4 (matches POSIX "no match" behaviour by
   default, though with `nullglob` it'd be empty — either gives
   the model usable signal).

Same shape as your `xargs` ship — interpret-then-dispatch, not a
real shell.

## Other findings this round

### M02 settled at 3/3

Was 2/3 post-N4. Three replicates passed cleanly this run.
Within-noise variation; nothing changed in the runtime that affects
M02. Just needed N=3 reps to land in the high-prob region.

### D03 (diff-detect) 2/3

Was 1/3 post-N4, 3/3 the run before. Pure flake at file sizes
this small. Model's strategy varies between "cat both eyeball" and
"sort -u and reason" and the latter sometimes loses the line
ordering needed to pinpoint the diff. Not a runtime issue.

### X02_iterative_refinement: 2/5

Was 4/5 in the N=5-only spike before this run, 1/3 in the original
N=3 run. So range: 1/3, 2/5, 4/5 — flaky around a true rate of
~50-60%. Model sometimes refines after seeing dupes, sometimes
doesn't.

### X03 + X04 stay 5/5 / 5/5

Cross-turn machinery isn't the limit; it's the model's reasoning
under specific shapes.

## Watch-list (post-N5)

| token | total | trend | status |
|---|---:|---|---|
| **`*` glob (non-find)** | **8** | **EXPLODED** (was 3) | **next ship** if you want more bench movement |
| sed | 3 | stable | held |
| awk | 3 | stable | held |
| diff | 2 | stable | held (D03 still 2/3 with cat-eyeball) |
| `-print0` (find flag) | 2 | stable (now silently dropped via xargs path) | accidental work |
| `-exec` (find action) | 2 | stable | held |
| `-name` (find flag) | 2 | stable (worked accidentally rep 1) | held |
| xargs | 0 | shipped (N5) | ✓ |
| sort | 0 | shipped (N1.5) | ✓ |
| `-0` (xargs flag) | 0 | absorbed (silently dropped per N5) | ✓ |

`-print0` / `-name` / `-exec` on find are at 2 attempts each.
Below threshold but rising slowly. If you ship globs, these may
become more visible (model's idiomatic alternative to globs is
find filters).

## Recommendation

**Globs next.** Same data shape that got xargs shipped — one task,
five reps, one common form. Probable 29 → 31 from one ship.

If you want to defer:

- **Bench-side workaround** would be: rewrite X01's prompt to
  steer away from `ls *.log`. But that's prompt-engineering around
  a model-canonical idiom, which (per your N5 reasoning) doesn't
  help any future agent that uses this surface.
- **Larger-model-side workaround**: an OPUS-class model would
  pivot to `find` after seeing empty `ls`. We're benching at
  Gemma 4 E2B specifically because it surfaces idiomatic-shape
  bottlenecks; mitigating that with model size isn't an
  upstream-decision.

## Files

```
example/eval/bash/PHASE_N5_REPLY.md                  (this doc)
example/eval/bash/bench_post_n5_2026-05-09.log       (110-trial transcript)
example/eval/bash/bash_specs.dart                    (BashSpec.replicates field; X-tier set to 5)
example/eval/bash/run_bash_bench.dart                (per-spec replicate override + --only flag)
```

Pause holds otherwise. Globs is the next data-justified ask.
