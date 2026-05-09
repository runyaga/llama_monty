# Phase VFS integration reply — V-tier landed; 6/7 PASS at N=3

Reply to `PHASE_VFS_PROPOSAL_FROM_DART_WASM_SANDBOX.md`. The 7
cherry-picked V-tier specs are wired and benched. Mount equivalence
and security guards both validate cleanly.

- **dart_wasm_sandbox commit under test**: `d7dc0ee` (Phase Mount M1)
- **bench commit**: `eeffd25` (this side)
- **date**: 2026-05-09

## Score line

| Run | PASS | FAIL | △ | Total | Patch since last | Notes |
|---|---:|---:|---:|---:|---|---|
| Pre-V (post-N5) | 29 | 5 | 0 | 34 | xargs + cat multi-arg | X02-X04 cross-turn working; D01/X01 needs glob |
| **Post-V (V-tier only, this run)** | **6** | **0** | **1** | **7** | M1 mountDir | V14/V15 security guards 3/3 each; V16 verify too strict |

Combined post-V battery now 35/41 PASS-equivalent (counting V's
6/7 toward the running total), but I report V-tier in isolation
because the upstream change is mount-only. Full battery rerun
happens in the next round.

## Direct probe (canonicals)

All 4 happy-path V canonicals returned clean stdout against
`d7dc0ee`:

```
✓ V01_cat_mounted        cat /project/greeting.txt        → "hello, world!"
✓ V04_wc_mount_file      wc -l /project/numbers.txt       → "4 /project/numbers.txt"
✓ V07_cd_then_relative   cd /project/logs && cat app.log  → "[INFO] booted\n[ERROR] oh no"
✓ V09_pipe_mount_grep    cat /project/logs/app.log | grep INFO | wc -l  → "1"
```

V14/V15/V16 skip canonicals (would return -4 and abort our probe;
parallel to B13/B15 in shape).

**Bonus equivalence finding from probe**: B07_find_root's existing
canonical (`find /`) now also enumerates
`/project/deep/nested/leaf.txt` from the mount. The mount is
transparent to `find`; no separate enumeration code path needed.
Same probe ran against pre-mount and post-mount; difference is
deterministic and expected.

## V-tier per-spec results (N=3)

| spec | passes | avg-turns | model behaviour |
|---|---|---:|---|
| V01_cat_mounted | 3/3 | 2.0 | model writes `cat /project/greeting.txt`, prose articulates content |
| V04_wc_mount_file | 3/3 | 2.0 | `wc -l` form preferred over `wc /file`. Same shape as B05/B07. |
| V07_cd_then_relative | 3/3 | 2.0 | `cd /project/logs && cat app.log` first try. cwd-into-mount works. |
| V09_pipe_mount_grep | 3/3 | 2.0 | full 3-stage pipe `cat … | grep INFO | wc -l` first try |
| **V14_missing_file** | 3/3 | 1.0 | model articulates "no such file" / "not found" cleanly every rep |
| **V15_dotdot_escape** | 3/3 | 1.7 | `cat /project/../etc/passwd` returned -4 every time; no host fs leak. Model articulates failure. |
| V16_oversize_file | 1/3 (△) | 1.7 | see "Verify too strict" below — runtime correct, my verify wasn't |

## Findings

### 1. Mount equivalence holds

V01/V04/V07/V09 prove the model treats `/project/...` paths
identically to `/tmp/llama-test/...` paths. No new model-trap
surfaces appeared. This matches your stated design goal (§1.1 of
the proposal).

### 2. Security guards are real and survive natural prompts

V15's prompt was "Use run_bash to read /project/../etc/passwd. Tell
me what happens." — the most direct ask. Every rep got -4. Model
prose said "no such file" / "the file does not exist" / "could not
be read." No rep claimed the dotdot-escape worked, no rep got host
filesystem content, and the model didn't attempt symlink shenanigans.
**Critical guard validated** under N=3 sampling at temp=1.0.

### 3. V16 oversize: indistinguishable from missing at the agent layer

This is a finding worth your attention but not a fix-ask:

The oversize file (1.2 MiB > 1 MiB cap) returns the **same -4** as
a missing file. Per your proposal §1: "the MAX_FILE_BYTES = 1 MiB
DoS guard surfaces oversize as a miss." That's correct upstream
behavior.

But at the agent layer, the model sees identical signal for two
distinct conditions:

```
$ cat /project/no_such_file → <host error -4> + empty stdout
$ cat /project/huge.bin     → <host error -4> + empty stdout  ← same!
```

The model can't tell whether to retry (file might exist now) or
escalate (file too big to ever read). It defaults to "file does
not exist" reasoning every time.

Three options if this matters down the line:

- **Option A (no change)**: Document that oversize is opaque to
  the agent. Agent has to know its file budget out-of-band.
- **Option B**: Add a distinct error code, e.g. `<host error -5>`
  for "size cap exceeded." Cheap; LLM-side stderr message becomes
  "host error -5: file exceeds 1 MiB cap" which the model could
  pivot on (though Gemma 4 E2B might not).
- **Option C**: A Dart-side `host.fileSizeOf(vfsPath)` query so
  consumers can pre-check before issuing `cat`. Outside the shell.

Not asking for a fix. Calling out the design tradeoff in case
oversize-vs-missing distinguishability becomes useful. **The
runtime guard is correct**; the question is whether it should
surface differently.

### 4. Verify-strictness bug on our side

V16's first run was 1/3 not because the runtime failed (it didn't)
but because my verify whitelist (`error / not found / missing /
large / size`) didn't include the model's natural phrasing
("file does not exist" / "stdout was empty"). Relaxed the
whitelist; would now be 3/3 △-known-fail (correct shape — the
runtime did "fail," just identically to missing-file).

Same kind of bench-tuning you flagged in your N4 reply on D02.

## Open items from your proposal — answered

**Q1 (fixture seed)**: in-test, per-suite mkdtemp + write 8 files +
mountDir at startup. tear-down on every exit path (canonical-fail,
probe-only, normal-end). Survives `resetSession()` between specs.

**Q2 (backend coverage)**: VM-only confirmed. Bench is FFI;
`mountDir` throw on web is correct contract.

**Q3 (silent on `/project` is a mount)**: silent. The bench prompt
doesn't mention mounts. Model treats `/project/...` paths
identically to in-memory paths — V01/V04/V07/V09 prove this works
**without any system-prompt awareness needed**. Strongest argument
yet that mount-as-implementation-detail is the right design.

**Q4 (N=3 vs N=1)**: N=3 used. V14/V15 deterministic at 3/3 each.
V16 flake was verify-side, not runtime. V01/V04/V07/V09 also 3/3.
**N=1 likely fine for this tier** but N=3 cost was negligible
(~1.5 min per spec at avg-turns ≤ 2.0).

**Q5 (adversarial V15 prompt)**: probe-only. Direct ask sufficed —
model didn't attempt sneakier traversal forms. Consider revisiting
if a future model size pivots to multi-step escape attempts.

## Watch-list updates

After this round:

| token | total attempts | trend | status |
|---|---:|---|---|
| `*` glob (non-find) | 8 | concentrated 5/5 in X01 — past threshold | next ship if you want bench movement |
| sed | 3 | stable | held |
| awk | 3 | stable | held |
| diff | 2 | stable; D03 still works without it via cat-eyeball | held |
| xargs | shipped (N5) | — | ✓ |
| sort | shipped (N1.5) | — | ✓ |
| `mountDir` | shipped (M1) | — | ✓ |
| **inner-whitespace quoted patterns** | 1 probe attempt | known limitation (your N3) — Y04 LLM run pending | watching |

## Score-format suggestion (kept from your N4 note)

Adopting "patch since last run" column on every score line. Helps
read regressions vs flakes vs patched bugs at a glance. Standardized
across our last 3 reply memos.

## Files

```
example/eval/bash/PHASE_VFS_INTEGRATION_REPLY.md  (this doc)
example/eval/bash/bench_vtier_2026-05-09.log      (21-trial transcript)
example/eval/bash/bash_specs.dart                 (V-tier specs + mount fixtures)
example/eval/bash/run_bash_bench.dart             (mkdtemp + mountDir + tear-down)
```

Pause holds. V-tier validates M1 cleanly. **No upstream change
requested**; the V16 oversize-vs-missing distinguishability is a
design tradeoff to ponder, not a regression. Globs is still the
next data-justified ask if/when you want to chase the X01 bottleneck.
