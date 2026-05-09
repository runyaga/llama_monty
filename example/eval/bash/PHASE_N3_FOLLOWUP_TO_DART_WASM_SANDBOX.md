# Phase N3 follow-up — N=3 sweep against current main, two findings

Sent unsolicited because the eval expansion surfaced two real
patterns that look like upstream-side decisions, plus one
recommendation.

- **what we did**: dropped C01-C03 (Python+bash composition; you
  noted python won't ship), added 9 new specs (S01-S06
  sophisticated pipes, D01-D03 decomposition incl. diff-detect),
  ran at N=3 replicates against current main (`1b27039`).
- **score**: 27/30 PASS at N=3. **D03 (diff-detect, no `diff`
  command) passes 3/3** — our concrete evidence diff stays off.
- **two new patterns** (one likely upstream, one model-side).

---

## Findings

### Finding 1 — `wc -l file1 file2 …` only reads the first file

D01 asked the model "find the .log file with the MOST lines" with
the hint `wc -l file1 file2 …`. The model wrote `wc -l file1 file2`
or `wc -l /dir/*` — both produce truncated output.

Direct probe:

```
$ wc -l /log /log
  → 2 /log               (only first counted; should be 2 / 2 / 4 total)
$ wc -l /log
  → 2 /log               (single arg fine)
```

POSIX `wc` accepts multiple file args and emits per-file counts plus
a `total` line. Our implementation only reads `argv[1]` after flags.

Impact: D01 fails 0/3 across replicates. Model has no obvious
fallback — the prompt's hint matches the canonical idiom. Workaround
would be N separate `wc -l` calls, but the model doesn't pivot.

Suggested: support multi-file args in `wc`. Same for `head`/`tail`/
`cat` which historically all accept multiple files; we haven't hit
those in evals yet but the same issue likely lurks.

### Finding 2 — `wc -l <dir>/*` glob expansion not done

The model also tries `wc -l /tmp/llama-test/state/*` to count all
files in a directory. The `*` is passed through as a literal arg,
no expansion happens, returns empty.

Probe (same dylib):

```
$ wc -l /dir/*       → empty (* not expanded)
$ ls *.txt           → already known: returns "*.txt: no such file"
                       (one ls *.txt observation pre-A1)
```

Pre-A1 we saw `ls *.txt` once. Post-N3 we see `wc -l /dir/*`. Two
data points across surveys. Still rare; calling it out so the
upstream watch-list catches it as it accumulates.

Ship-threshold (per your N1.5 note: ≥3 attempts): not yet. Two
observations.

### Recommendation — diff stays off

D03_diff_files_no_diff: model gets two near-identical 5-line files
(`v1.txt`, `v2.txt`, differ on one line: `gamma` vs `GAMMA`). Asked
to find the differing line, told no `diff` command available.

**3/3 PASS at N=3.** The model wrote:

```python
out1 = run_bash('cat /tmp/llama-test/configs/v1.txt')
out2 = run_bash('cat /tmp/llama-test/configs/v2.txt')
print(out1['stdout'])
print(out2['stdout'])
# (then prose-articulates "the differing line is gamma vs GAMMA")
```

Pure cat-both-and-eyeball. Works at small file sizes for Gemma 4
E2B. So:

- diff is one survey observation in 50+ task-trials.
- The natural workaround works at the bench's file sizes.

We don't think you should ship diff. If we ever bump fixture sizes
to where eyeballing fails (50+ lines per file), we'd revisit, but
the test surface that mattered just passed cleanly.

---

## Score table

| Tier | Specs | Result @ N=3 |
|---|---|---|
| B (basics, navigation, multi-call, sentinel) | 14 | 14/14 ✓ |
| A (advanced single-fence pipes) | 4 | 4/4 ✓ |
| M (multi-turn agentic) | 2 | 1/2 ✓ (M02 2/3, B12 0/3) |
| S (sophisticated pipes, larger fixtures) | 6 | 6/6 ✓ |
| D (decomposition, multi-call reasoning) | 3 | 1/3 ✓ (D03 ✓; D01 wc-multi-arg blocked; D02 model regex-escape) |
| **Total** | **30** | **27/30 (90%)** |

The three failures across N=3:

- **B12_find_then_cat 0/3** — pre-existing model reasoning limit
  (extracting absolute path from `find` output). Same as before;
  systematic at this model size.
- **D01_largest_logfile 0/3** — blocked on Finding 1 (`wc` multi-arg).
- **D02_first_error_message_text 0/3** — model writes `grep
  "\[ERROR\]"` (regex escapes for brackets). Fixed-string grep with
  literal `\[…\]` doesn't match. Model-side issue with how regex
  intuitions interact with our fixed-string grep — see below.

### Watch-list update (model behaviours)

| Pattern | First seen | Total | Status |
|---|---|---:|---|
| `\[…\]` regex-escaped grep | post-N3 (this run) | 1 | new — see below |
| `*` glob in non-find | pre-A1 (`ls *.txt`), post-N3 (`wc -l /dir/*`) | 2 | accumulating |
| `cat \| python -c …` | post-N3 (C01 last run) | 1 | dropped tier |
| `xargs` | post-N1 | 1 | stable |
| `2>/dev/null` | post-N1 | 1 | now stripped (N2) |

### Optional: docs nudge

The model's regex-thinking on grep (`grep "\[ERROR\]"`) suggests the
help could be more emphatic about "fixed-string substring, no regex,
brackets are literal." Currently the help says "fixed-string line
search" but doesn't call out that regex syntax is treated literally.
A line like `# Note: grep is fixed-string — \[, ^, $, etc. are
literal characters, not regex` might save the model from this trap.
Same idea for sed/awk if they ever ship.

Not blocking. Just a docs idea.

---

## Files

```
example/eval/bash/PHASE_N3_FOLLOWUP_TO_DART_WASM_SANDBOX.md  (this doc)
example/eval/bash/bench_n3_replicates_2026-05-09.log         (90-trial transcript)
example/eval/bash/bash_specs.dart                            (S/D tier added; C dropped)
```

No upstream-side action required from your end unless `wc` multi-arg
fix appeals. Pause holds otherwise; we'll keep the watch-list moving
on our side.
