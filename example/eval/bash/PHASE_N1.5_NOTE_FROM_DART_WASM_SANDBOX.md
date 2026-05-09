# Phase N1.5 note — `sort` shipped (post-N1 report)

A short note from the dart_wasm_sandbox side, in response to
`PHASE_N1_DELTA.md`. Pause recommendation accepted; one tactical
update.

- **dart_wasm_sandbox commit**: `d85e315` (Phase Next-N1.5: sort)
- **Date**: 2026-05-09
- **Trigger**: shipped post your N1 report; you may want to re-run
  the survey at your convenience.

---

## TL;DR

`sort` (`-n` / `-u` / `-r`, file arg or stdin) shipped after your
N1 report came in. It collapses the survey gap from 4 commands × 1
attempt → 2 commands × 1 attempt. **Otherwise pause holds — your
recommendation accepted in full.**

---

## What unblocks on a re-run

Two of your N1 survey literals were rejected because `sort` was on
the deny list. Both should now work:

```python
# T09 — the post-pipes case that finished as "pipe ok, sort denied"
run_bash('cat /tmp/llama-test/fixtures/numbers.txt | sort')
# → "1\n2\n3\n42\n"

# T13 — also reaches for sort directly
run_bash('sort -u /notes.txt')
# → "  - finish the demo\n  - profit\ntodo:\n"
```

Expected post-N1.5 survey delta:

| argv0 | post-N1 status | post-N1.5 status |
|---|---|---|
| `sort` | 0/2 ✗ | 2/2 ✓ |
| `sed` | 0/1 | 0/1 (unchanged) |
| `awk` | 0/1 | 0/1 (unchanged) |
| `diff` | 0/1 | 0/1 (unchanged) |

Re-run the bench too — `B14_pipe_works` should keep passing; nothing
else should regress. If `B12` re-runs and the model now writes
`find /... | sort` instead of `find /... | xargs cat | grep ...`,
that's the model finding the new tool.

---

## Pause holds

Your recommendation matrix in PHASE_N1_DELTA:

> Sit on the current allow-list and gather usage from the live chat
> UI / longer survey runs. Watch for `||`, `;`, `<`, `>`, `$(…)`,
> backticks, or `*`-globbing (none observed in our 15-task survey so
> far). Re-run at a higher N before committing to sed.

Accepted. The dart_wasm_sandbox side is at the natural pause point.
sed / awk / diff are each one observation in 15. Ship-threshold:

- ≥3 of 50 tasks block on the same command in a higher-N survey, OR
- new signal source (live chat UI, second consumer, different
  domain) shows different patterns.

Until then we sit.

---

## Your tactical items captured

Three things you flagged that are llama_monty-side, not
dart_wasm_sandbox-side. Worth doing on your schedule, not tied to
us shipping anything:

1. **Surface `exit_code` from `run_bash`**, instead of stripping the
   `<host error -N>` marker in `buildRunBashFunction`. The runtime
   produces it; the LLM never sees it. With `{stdout, stderr,
   exit_code}` visibility, the model would learn "command rejected"
   from B12-style misuses and pivot. This is also where our future
   structured-envelope ABI bump will eventually land
   (`dart-wasm-sandbox-vfs-design.md` §D6) — but you don't need to
   wait for that; the data is already in the dict.

2. **Stable `B15_disallowed_X` sentinel** so the bench always has a
   rejection-message check that doesn't churn each phase. Good
   housekeeping; agreed.

3. **B12 prompt tweak**: model is collapsing two prescribed `run_bash`
   calls into one pipe chain. Not a runtime issue. Slight rewording
   ("issue these as TWO separate `run_bash` calls") would catch it.

None of these are blocking us; flagging in case you want to bundle
with a re-run pass.

---

## Two interesting new vectors from B12

The model wrote `find ... | head | xargs cat 2>/dev/null | grep ... | head`.
Two new things appeared *because* pipes exist:

- `xargs` (1 attempt)
- `2>/dev/null` stderr redirect (1 attempt)

Pattern: feature-stretching. Once one composition primitive worked
(pipes), the model reached for adjacent ones it knew from training
data. **Not actionable now** — single observations each — but worth
the watch-list for your higher-N survey:

```
xargs        ?  watch
> / >>       ?  watch  (model has tried 2>/dev/null once but never >)
||           ?  watch
;            ?  watch
$(...)       ?  watch
backticks    ?  watch
* (globs)    ?  watch  (one ls *.txt pre-A1, none since)
```

If any of these clusters in a higher-N run, that's the next signal.

---

## Files

```
example/eval/bash/PHASE_N1.5_NOTE_FROM_DART_WASM_SANDBOX.md   (this doc)
```

Replies / new survey runs welcome whenever; no rush.
