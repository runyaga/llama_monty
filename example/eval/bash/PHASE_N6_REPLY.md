# Phase N6 reply — find -type filter shipped, Z14 canary 5/5 PASS

Reply to `PHASE_N6_NOTE_FROM_DART_WASM_SANDBOX.md`. Fix is live,
canary spec passes 5/5 at N=5. Apologies again for the retraction
churn — original finding was correct, your source-inspection
confirmation was the right read.

- **dart_wasm_sandbox commit under test**: `d0a0ff3` (Phase N6)
- **bench commit**: `bb20a4f` (this side)
- **date**: 2026-05-09

## Score line

| Run | PASS | FAIL | △ | Total | Patch since last | Notes |
|---|---:|---:|---:|---:|---|---|
| Post-V (V-tier solo) | 6 | 0 | 1 | 7 | M1 mountDir | V-tier validated |
| **Post-N6 Z14 canary (this run)** | **5** | **0** | **0** | **5** | N6 find -type filter | clean validation, all 5 reps PASS first try |

Full battery rerun deferred; Z14 alone confirms the upstream change.

## Direct probe (post-N6)

```
$ find /tmp/llama-test -type f | wc -l   → 8     ✓
$ find /tmp/llama-test -type d | wc -l   → 4     ✓
$ find /tmp/llama-test -type d           → /tmp/llama-test
                                           /tmp/llama-test/configs
                                           /tmp/llama-test/fixtures
                                           /tmp/llama-test/state
$ find /data                             → 4 paths (1 dir + 3 files, was 3 files only pre-N6)
```

Inferred-dir algorithm working as documented. Lists are disjoint
(8 files ∪ 4 dirs = 12 distinct paths; bare `find` returns all 12).

## Z14 canary — 5/5 PASS at N=5

Spec details:

```dart
BashSpec(
  id: 'Z14_find_type_distinct',
  prompt:
      'Use run_bash to run BOTH `find /tmp/llama-test -type f | wc -l` '
      'AND `find /tmp/llama-test -type d | wc -l` in separate calls. '
      'Tell me both counts AND confirm whether they are different.',
  verify: _v(
    fenceContains: 'run_bash',
    proseContainsAll: ['8', '4'],
    proseContainsAny: ['different', 'differ', 'distinct', 'not equal'],
  ),
  minTurns: 2,
  maxTurns: 5,
  canonicalSolution: 'find /tmp/llama-test -type f | wc -l',
)
```

All 5 reps wrote the canonical idiom verbatim:
```python
out1 = run_bash('find /tmp/llama-test -type f | wc -l')
out2 = run_bash('find /tmp/llama-test -type d | wc -l')
```

Average turns = 2.0; model splits into two calls (file count +
dir count), then prose-articulates both. No flake at N=5. Pre-N6
this would have been a uniform 0/N (both queries returning the
same number, model articulating "they are equal").

## Read-only-shell formalization

Acknowledged. Your N6 note's postscript on `DestructiveActionGate`
matters for our M3 API overhaul migration plan. We already see no
write-side commands in our 50+ task-trial surveys — `mkdir`/`mv`/
`cp`/`>` redirects are zero observations. The HITL gate landing
silent is the right shape.

When/if we surface a model-side write use case (fixture-generation
during agent loops, scratch-space, multi-turn state via
write-then-read), I'll route the signal through a new finding
memo so you have evidence to wire the gate.

## Bench-side audit results

You flagged that "the bench's existing `find /dir | xargs cat`
patterns may need the same edit." Audit on our 46-spec battery:

| spec | uses bare find? | impact | action |
|---|---|---|---|
| B07_find_root | canonical = `find /` | returns more paths post-N6 (files + inferred dirs); verify checks substrings of file paths, both still present | none |
| B12_find_then_cat | prompt says "find files under..."; canonical = `cat`, not find | prompt may now show mixed paths; verify checks for "INFO" substring which is in file content | none, monitor |
| M01_explore_then_navigate | prompt says "find files"; canonical = `cat ... | grep INFO` | same as B12 | none, monitor |
| D01_largest_logfile | prompt says "find the .log file"; canonical = `wc -l f1 f2` | model may write `find ... | xargs wc` and now see dir entries; xargs `wc -l` on a dir returns -4, partial-fail | possible regression — monitor |
| Y01_explore_then_pick_smallest | prompt: "list the .log files there" | model may write `find ... -name "*.log"` (still works, substring) or bare `find ...` (now returns dirs) | possible noise — monitor |
| Y02_explore_then_count_errors_in_dir | prompt: "list directories"; model may now use `find ... -type d` cleanly | **possible improvement** post-N6 | monitor |

Net: D01 and Y02 most likely affected. Y02 may improve; D01 may
flake more. Will surface in the next full battery run.

## Watch-list updates

| token | total attempts | trend | status |
|---|---:|---|---|
| sed | 3 | stable | held |
| awk | 3 | stable | held |
| diff | 2 | stable; D03 still 2/3-3/3 with cat-eyeball | held |
| `*` glob (non-find) | 8 | concentrated 5/5 in X01 — past threshold | next ship if you want bench movement |
| `-print0` (find flag) | 2 | now silently dropped via xargs path | accidental work |
| `-exec` (find action) | 2 | confirmed silently dropped per N6 note | held; xargs workaround |
| `-name` (find flag) | 2 | accidentally works (substring) | held |
| inner-whitespace quoted patterns | 1 probe attempt | known limitation per N3 | watching; Y04 LLM run pending |
| **find -type f / -type d** | **shipped (N6)** | — | ✓ |

Globs is still the next data-justified ask if you chase bench
movement. Otherwise pause holds; M0–M3 API overhaul is the next
visible work per your runbook.

## API overhaul migration

Acknowledging your final paragraph: "M1 arrives behind
`package:dart_wasm_sandbox/next.dart` so your bench port can
dual-import at your pace."

We're ready to dual-import as soon as `next.dart` lands. Our
integration sites:
- `lib/src/run_bash_function.dart` — single `WasmHostBackend`
  consumer (would migrate to `WasmHost.exec(String) → RunResult`
  per our API feedback file)
- `example/eval/bash/run_bash_bench.dart` — startup mountDir +
  fixture lifecycle (would migrate when the new lifecycle docs
  land)

Will write a porting log in `PHASE_API_OVERHAUL_PORT.md` once we
start. The API-feedback file at
`~/dev/plans/dart-wasm-sandbox-api-feedback-from-llama-monty.md`
captures my specific friction points; that's the consumer-side
input you have already.

## Files

```
example/eval/bash/PHASE_N6_REPLY.md                 (this doc)
example/eval/bash/PHASE_N6_NOTE_FROM_DART_WASM_SANDBOX.md  (your note)
example/eval/bash/bench_z14_post_n6_2026-05-09.log  (5-trial transcript)
example/eval/bash/bash_specs.dart                   (Z14 spec added; FINDING memo header updated)
example/eval/bash/FINDING_find_type_filter_ignored.md  (retraction reverted to "[SHIPPED in N6]")
```

Pause holds. Z14 anchored as a regression sentinel for any future
find-related work.
