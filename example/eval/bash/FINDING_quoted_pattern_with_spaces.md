# Finding — quoted patterns with inner whitespace

For the dart_wasm_sandbox owner. Standalone bug-finding memo,
separate from `PHASE_VFS_REPLY.md`. Already-known limitation per
your N3 note; this just adds data and predicts when it crosses
the ship-threshold.

- **dart_wasm_sandbox commit reference**: `1b27039` (Phase N3) — the
  outer-quote-strip ship that made single-word quoted grep work
- **scope**: still-broken multi-word quoted patterns in any allow-listed cmd
- **data**: 1 probe attempt today (canonical), 0 LLM attempts pre-Y04
- **status**: not asking for a fix yet; flagging the prediction

## What's broken

```
$ grep -c "auth failed" /tmp/llama-test/state/big.log
  → <host error -4>          (file not found — but the file exists)
```

Why: the parser splits on inner whitespace BEFORE outer-quote-strip
(per your N3 note). Tokens become `['"auth', 'failed"']` — neither
has matched outer quotes, so quote-strip skips both. `grep` reads
`"auth` as the pattern and `failed"` as the file.

```
$ grep -c "auth"  file        → works (single token, quote-stripped)
$ grep -c auth    file        → works (no quotes, no strip needed)
$ grep -c "auth failed" file  → BROKEN (this finding)
```

## Why it predictably matters

Surveying our 50+ task-trials of grep usage, the model's grep-
pattern habits are:

| pattern shape | observed | example |
|---|---:|---|
| single word, quoted | ~6 | `grep "ERROR" file`, `grep -v "INFO" file` |
| single word, bare | ~3 | `grep ERROR file` |
| multi-word, quoted | **0 so far** | hypothetically: `grep "auth failed" file` |
| multi-word, bare (impossible) | 0 | shell would split |
| regex-escaped | 1 | `grep "\[ERROR\]" file` (D02) |

Multi-word quoted is **0 attempts so far**, but that's because the
specs we've run only ask about single-token patterns. The new
Y04_drill_into_first_error_type spec specifically asks the model to:

1. Extract the first ERROR line → "[ERROR] auth failed"
2. Use that **exact message text** as the count filter

The model's canonical form for "count occurrences of `auth failed`
in a file" is `grep -c "auth failed" file`. With Y04 at N=5, we'll
generate up to 5 attempts in a single spec.

If Y04 produces 3+ attempts on the same shape, that crosses your
stated threshold. We'd then escalate to a formal ask.

## Why I'm flagging it now

Two reasons:

1. **Our canonical probe already auto-detects this.** With
   `canonicalSolution` shipped (commit `174482e`), the bench
   refuses to start when a canonical hits `<host error -N>`. This
   finding came out of the probe within seconds of running it —
   no LLM compute needed. Future invocations of this bug
   surface in <1s instead of buried in a bench transcript.

2. **The scope is wider than `grep`.** Same tokenization
   limitation likely applies to:
   - `head -n 1 "/path with space.log"` — quoted file path with space
   - `grep -c PATTERN "/some path/file"` — quoted file with space
   - `cat "/dir with spaces/foo"` — quoted dir path
   None observed yet, but our paths happen to have no spaces.
   If anyone mounts a real disk via M1 with paths-with-spaces,
   this surfaces.

## Workarounds

Bench-side, today:

- Canonicals: use single-word patterns (Y04 canonical now uses
  `auth` instead of `auth failed`).
- LLM-side: when Y04 hits this and the model loops, the bench
  retries with stderr feedback. Some models will pivot to
  bare-grep; Gemma 4 E2B at this size probably won't.

Upstream-side, when justified:

- A minimal shell tokeniser that respects matched-quote pairs
  across whitespace. Same scope as your N3 quote-strip, just
  pre-tokenization instead of post.
- Or: extend the existing post-tokenization quote-strip to
  rejoin adjacent tokens whose quotes match across the
  whitespace boundary. Cheaper but more brittle.

## What I'm not asking for

- A fix today. Below ship-threshold.
- Any rework of the existing N3 quote-strip. That ship is good.
- Documentation changes. Your N3 note already documents this
  limitation; the bench's job is to surface evidence when it
  matters.

## When to revisit

After Y04 runs against the LLM. If 3+ of 5 reps hit
`grep -c "auth failed" file` → `<host error -4>` and the model
fails to recover, this becomes the next ship signal — same data
shape that got `xargs` shipped in N5 and `globs` queued for the
next round.

---

**Files**:
```
example/eval/bash/FINDING_quoted_pattern_with_spaces.md  (this doc)
example/eval/bash/bash_specs.dart                        (Y04 canonical works around)
```
