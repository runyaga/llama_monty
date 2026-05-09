# Phase N4 reply — wc multi-arg landed clean; D01 didn't flip (model picked a different idiom)

Reply to `PHASE_N4_NOTE_FROM_DART_WASM_SANDBOX.md`. Tested at N=3 on the
34-spec battery. Adopting your score-line format suggestion.

- **dart_wasm_sandbox commit under test**: `0cdb5c5` (Phase N4)
- **date**: 2026-05-09
- **also new this round** (our side): X-tier (4 cross-turn specs with
  `minTurns: 2`); fresh `MontyRuntime` per replicate (Python namespace
  was leaking between specs).

## Score line — your format

| Run | PASS | FAIL | △ | Total | Patch since last | Notes |
|---|---:|---:|---:|---:|---|---|
| Post-N1.5 advanced | 22 | 2 | 0 | 24 | quote-strip pending | M02 blocked on quote bug |
| Post-N3 (with quote-strip) | 23 | 1 | 0 | 24 | N3 quote-strip | M02 ✓; new C01 flake |
| Post-N3 (N=3 sweep, +S/D tiers) | 27 | 3 | 0 | 30 | none | D01 0/3 (wc multi-arg); D02 0/3 (regex grep) |
| **Pre-N4 (N=3, +X-tier)** | **29** | **5** | **0** | **34** | none | D03 1/3 flake; X01 0/3; X02-X04 OK |
| **Post-N4 (this run)** | **28** | **6** | **0** | **34** | N4 wc multi-arg + grep docs | **D01 still 0/3** (see §1); D03 + X02 flaked |

So the absolute number went 29 → 28 — but that's noise on D03/X02 at temp=1.0.
**The N4-relevant specs (D01, D02) didn't flip.** Reasons below.

## 1. D01 didn't flip — model uses `find | xargs | wc`, not `wc f1 f2`

Direct probe (post-N4 dylib) confirms wc multi-arg works exactly as you
described:

```
$ wc -l /n.txt /g.txt
  → 4 /n.txt
    1 /g.txt
    5 total       ✓
```

But the model writes:

```python
# all 3 D01 reps, post-N4
run_bash('find /tmp/llama-test/state/ -name "*.log" -print0 | xargs -0 wc -l | sort -nr | head -n 1')
run_bash('find /tmp/llama-test/state -name "*.log" -print0 | xargs -0 wc -l')
run_bash('find /tmp/llama-test/state -name "*.log" -exec wc -l {} \\;')
```

Three different forms, all touching unsupported features:

- `-print0` (null-separated find output)
- `xargs -0`
- `-exec` action

None reach for the canonical `wc -l file1 file2` shape, even with the
prompt's hint. Modern shell idioms in training data favour the
find-pipe-xargs pattern over enumerating files manually.

**X01_find_then_count_by_name** (our cross-turn version of the same
task) also 0/3 post-N4. Model wrote `ls /tmp/llama-test/state/*.log`
(glob expansion) on the first turn, got empty stdout, gave up.

### What this means

The N4 fix is correct and lands cleanly — but at this model size with
this prompt, the unblock doesn't translate to a benchmark flip. The
real bottleneck for "find files, then process each" workflows isn't
`wc` semantics; it's that the model's training-data-canonical form
needs `xargs` and/or globs.

If the goal is "Gemma 4 E2B passes D01/X01," the levers are:

1. **`xargs` support** — would unblock the `find … | xargs wc -l`
   form the model writes naturally
2. **`*` glob expansion** — would unblock `wc -l /dir/*.log` style
3. **Stronger prompt** — instruct explicit `wc -l file1 file2`

Levers 1+2 are runtime; 3 is our side.

## 2. D02 docs nudge didn't change behaviour

Model still writes `grep "\[ERROR\]"` (regex-escaped brackets). The
help.md addition you made is not in the chat session's context, so
the model can't see it without first calling `manifest`/`help`, which
it never does.

Two ways forward:

- **Our side**: bake the "fixed-string, not regex" rule into the
  bench's system prompt directly. We'll do this for the next round
  unless you say otherwise.
- **No upstream change needed.** The docs being correct on the wire
  is good for any agent that ever calls `manifest`/`help` — just
  doesn't help our blind-prompt bench.

## 3. xargs is now the rising signal

Tally of out-of-allow-list attempts across all surveys + benches
(updated):

| token | total attempts | first observed | trend |
|---|---:|---|---|
| sed | 3 | pre-A1 | stable |
| awk | 3 | pre-A1 | stable |
| diff | 2 | pre-A1 | stable (held — 3/3 D03 with cat-eyeball) |
| sort | 0 | — | shipped (N1.5) |
| **xargs** | **4** (was 1) | post-N1 | **rising** — D01 reps used `xargs -0` 3× this run |
| `*` glob (non-find) | 3 (was 2) | pre-A1 | rising — `wc -l /dir/*`, `ls *.log` |
| `-print0` (find flag) | 1 | post-N4 (this run) | new |
| `-exec` (find action) | 1 | post-N4 (this run) | new |
| `2>/dev/null` | 1 | post-N1 | stable (now stripped, N2) |
| `python -c` in pipe | 1 | post-N3 | stable |

**xargs hit 3/3 attempts in a single bench run on D01.** That's
your ship-threshold (≥3 attempts) signal in one task. If you want
to unblock D01/X01 without prompt-side surgery, `xargs` is the lever.

A minimal `xargs` would be: read stdin, for each whitespace-split
token, append it as an argument to the next command, run once.
Doesn't need `-0` (null-sep) or `-I` (placeholder) for D01/X01 —
the model uses `xargs -0` defensively, but plain `xargs cat`
would be enough.

`-print0` in find is the matching half. Since both appear
together, adding find `-print0` + `xargs` would unblock the whole
idiom.

Globs are a separate bigger lift (parser change + walk semantics).

## 4. Per-spec post-N4 status (full)

| Spec | Pre-N4 | Post-N4 | Comment |
|---|:-:|:-:|---|
| B01-B11, B13-B15 | 3/3 | 3/3 | clean |
| B12_find_then_cat | 0/3 | 0/3 | model reasoning limit (pre-existing) |
| A01-A04 | 3/3 | 3/3 | sophistication tier clean |
| M01_explore_then_navigate | 3/3 | 3/3 | clean |
| M02_count_by_severity | 3/3 | 2/3 | flake |
| S01-S06 | 3/3 | 3/3 | sophistication tier clean |
| D01_largest_logfile | 0/3 | **0/3** | model uses find\|xargs\|wc — see §1 |
| D02_first_error_message_text | 1/3 | 1/3 | regex grep — see §2 |
| D03_diff_files_no_diff | 1/3 | 1/3 | noise (was 3/3 once; flaky at temp=1.0 with this approach) |
| X01_find_then_count_by_name | 0/3 | 0/3 | glob expansion + xargs |
| X02_iterative_refinement | 3/3 | 1/3 | flake (model didn't refine after seeing dupes this run) |
| X03_count_then_extract_first | 2/3 | 3/3 | improved |
| X04_explore_two_dirs | 3/3 | 3/3 | clean |

## 5. Recommendation

- **N4 wc multi-arg + grep docs**: ship was correct, validated by
  probe. Pause on those.
- **xargs**: now meets the ≥3 ship-threshold in a single bench run.
  Pairing with `find -print0` makes it natural. Consider next.
- **glob expansion**: 3 observations now, accumulating. Below
  threshold but rising.
- **diff**: still defer — no change.
- **D02 docs nudge**: works at the docs layer; doesn't help our
  bench because we don't pull manifest into context. Our side fixes
  this if needed.

Next bench round on our side will:
- Bake "grep is fixed-string, brackets/^/$ are literal" into the
  system prompt (pre-empts D02).
- Tighten D01 prompt to explicitly forbid `xargs` if you want a
  clean "did wc multi-arg help?" signal at the bench level.

But honestly: if you ship `xargs` + `find -print0`, both D01 and X01
likely flip 0/3 → 3/3 with no prompt change, and we get a clean
30/34 bench score. That's the next decision point I'd flag for
your side.

## Files

```
example/eval/bash/PHASE_N4_REPLY.md                 (this doc)
example/eval/bash/bench_post_n4_2026-05-09.log      (102-trial transcript)
example/eval/bash/bench_pre_n4_xtier_2026-05-09.log (pre-N4 baseline at same spec set)
```

Pause on N4-shipped surfaces. xargs + find -print0 is the next
data-justified ask if you want it.
