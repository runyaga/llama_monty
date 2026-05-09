# Phase N4 — wc multi-file + grep fixed-string docs nudge

Reply to `PHASE_N3_FOLLOWUP_TO_DART_WASM_SANDBOX.md`. Finding 1
shipped; Findings 2 + 3 held; recommendation §3 (don't ship diff)
accepted.

- **commit**: `0cdb5c5` (Phase Next N4: wc multi-file + grep fixed-string docs nudge)
- **date**: 2026-05-09

## What changed

### `wc` accepts multiple files (Finding 1)

Previously: `wc -l f1 f2` ran `.find(..)` on positional args, kept
only the first. Now: collect all positional args, emit one
POSIX-shaped line per file, append `total` when 2+ files.

Direct probe (mirrors your N3 table):

```
wc -l /numbers.txt /greeting.txt   →  4 /numbers.txt          (was: ✗)
                                      1 /greeting.txt
                                      5 total
wc -c /numbers.txt /greeting.txt   →  9 /numbers.txt          (was: ✗)
                                      14 /greeting.txt
                                      23 total
wc /a /b /c (no flag)              →  per-file 3 cols + total (was: ✗)
wc -l /numbers.txt                 →  4 /numbers.txt          (unchanged)
wc -l /a /missing                  →  <host error -4>         (short-circuit)
cat /a | wc -l                     →  4                       (stdin, no label, no total — unchanged)
```

D01_largest_logfile should now pass: model writes
`wc -l /tmp/llama-test/state/*.log`, gets per-file counts plus a
`total`, picks the line with the highest count.

### `grep` docs nudge (your §"Optional: docs nudge")

Help + manifest now state explicitly:

> Note: pattern is a literal substring, NOT a regex. `[`, `]`, `^`,
> `$`, `\`, `.`, `*` are matched as literal characters. Outer
> quotes are stripped.

Same wording in `host/src/help.md`, `host/src/manifest.json`, and
the embedded `helpMarkdown` / `manifestJson` constants on the Dart
side (manifest_test asserts byte-equality between the Dart
constants and the Rust files).

D02 may flip if the model reads the manifest before issuing greps.
If it doesn't change behaviour after this, the next move is
prompt-side rather than runtime — happy to discuss if it persists.

## What did NOT change

- **`cat` / `head` / `tail` multi-arg** — your note flagged these
  as likely lurking, and POSIX behaviour is the same shape, but
  they're not at the ship-threshold (≥3 attempts) yet on actual
  surveys. Held until evidence shows up. The fix path is identical
  to what we just did for `wc`, so the second one will be cheap.
- **`*` glob expansion** — still 2 observations across all
  surveys (`ls *.txt` pre-A1, `wc -l /dir/*` post-N3). Below
  threshold. Watching.
- **`diff`** — recommendation accepted. D03 passes 3/3 with
  cat-both-and-eyeball at the bench's file sizes; the design doc
  at `~/dev/plans/dart-wasm-sandbox-diff-design.md` (893 lines)
  recommends defer; ship-trigger is ≥3/45 tasks or ≥1/10 in any
  single workflow. If you bump fixture sizes past ~50 lines and
  D03 starts failing, ping us.

## Tests

Five new cross-backend tests in `dart/test/text_tools_test.dart`,
tag `commands`:

- `wc -l f1 f2` per-file + total
- `wc -c f1 f2` per-file + total
- `wc f1 f2 f3` (no flag) per-file + total (3-file)
- `wc -l f1 missing` short-circuits with `<host error -4>`
- `wc -l <single>` regression guard — does NOT print a `total` line

Both backends green (VM 85, chrome 85). Manifest tests still pass
(byte-equality between Dart constants and Rust artefacts preserved
through the rawstring conversion).

## What to re-run

- **D01_largest_logfile** — should flip 0/3 → 3/3. The hint matches
  the new behaviour exactly.
- **D02_first_error_message_text** — uncertain. Depends on whether
  the model consults `manifest` / `help` before issuing the grep,
  or whether the system prompt brings the docs into context. If
  flat retry doesn't fix it, suggest moving the "fixed-string, not
  regex" line into the system prompt directly — cheaper than
  shipping a regex grep.
- **B12_find_then_cat** — unchanged. Pre-existing model reasoning
  limit. Not a runtime issue.

Expected new score line if D01 + D02 both flip: **30/30**. If only
D01 flips: **28/30**.

## Score-line format suggestion (optional)

If you want to keep the per-phase deltas comparable across reports,
consider a small column for "patch landed since last run." Easier
to spot regressions vs. flakes vs. patched bugs at a glance. No
obligation — just an idea while we're trading these notes.

## Files

```
host/src/lib.rs                          (exec_wc rewritten; wc_counts/wc_format helpers)
host/src/help.md                         (wc + grep docs)
host/src/manifest.json                   (wc + grep summaries)
dart/lib/src/host_emulation.dart         (mirror; manifestJson + helpMarkdown raw'd)
dart/test/text_tools_test.dart           (+5 wc tests)
```

Pause holds otherwise.
